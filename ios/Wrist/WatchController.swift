import BackgroundTasks
import CoreLocation
import Foundation
import SwiftUI
import UIKit

/// Glue between the Bluetooth link and the Rust protocol core (withouthings' wpp-ffi), for every paired watch.
/// All core calls happen on the BLE queue so frames, ticks and store writes stay in order.
final class WatchController: NSObject, ObservableObject, WatchLinkDelegate {
    static let shared = WatchController()

    struct Found: Identifiable, Equatable { let id: UUID; let name: String; let rssi: Int }

    /// What the UI shows for one watch.
    struct Card: Identifiable {
        let id: UUID
        let name: String
        var state: String
        var snapshot: Snapshot?
        var hrToday: [HrPoint]
        var lastSync: Date?
    }

    @Published var cards: [Card] = []
    @Published var selected: UUID?
    @Published var pairing = false
    @Published var pairingText = ""
    @Published var found: [Found] = []
    @Published var influxText = ""

    var paired: Bool { !cards.isEmpty || !Settings.watches.isEmpty }
    var current: Card? { cards.first { $0.id == selected } ?? cards.first }

    /// One paired watch's live session.
    fileprivate final class Unit {
        let record: WatchRecord
        let service: WatchService
        let raw: RawLog
        var lastTick = Date.distantPast
        var lastResync = Date.distantPast
        var lastZoneOffset: Int32?
        var lastSnapshotDay = ""
        var lastSync: Date?
        var lastBattery = Date.distantPast
        var lastProfileCheck = Date.distantPast
        var scanModeSet = false
        var burstStartedAt: Date?
        var limitsSent = false
        var lastStepPoll = Date.distantPast
        var lastStepCount: UInt32?
        var movingPolls = 0
        var stillPolls = 0
        var autoWalk = false
        var flashRunning = false
        var lastBurst = Date.distantPast
        var lastHrMs: Int64 = 0
        var stepsSeen: Int64 = -1
        var stepsStillSince = Date()
        var ecgSessionRunning = false
        var rawCaptureOn: Bool?
        init(record: WatchRecord, service: WatchService, raw: RawLog) {
            self.record = record; self.service = service; self.raw = raw
        }
    }

    let link = WatchLink()
    private lazy var host: AncsHost = {
        let h = AncsHost(queue: link.queue)
        h.onControlWrite = { [weak self] bytes, limit in
            guard let self, let u = self.ancsUnit else { return }
            do { try u.service.onAncsWrite(bytes: bytes, maxPayload: UInt32(limit)) }
            catch { AppLog.log("ancs write error: \(error)") }
        }
        return h
    }()
    /// All alerts go through one watch's core, so ids line up whichever watch asks for the text.
    private var ancsUnit: Unit? { units.values.sorted { $0.record.entity < $1.record.entity }.first }
    private lazy var influx = InfluxPusher()
    private var units: [UUID: Unit] = [:]
    private var pairer: PairingService?
    fileprivate var pairingId: UUID?
    private var pairingName = ""
    private let pairingRaw = RawLog(prefix: "pairing", db: nil)
    private var lastPush = Date.distantPast
    private var timer: Timer?

    override init() {
        super.init()
        link.delegate = self
        KeepAlive.shared.onFix = { [weak self] loc in self?.recordFix(loc) }
        link.queue.async {
            _ = self.host
            for record in Settings.watches { self.start(record) }
            self.publish()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.link.queue.async { self?.housekeepingAll() }
        }
    }

    // MARK: scheduled background refresh

    /// Watches only speak up now and then, so also ask iOS to wake the app. iOS decides when; 15 min is the earliest.
    private static let refreshId = "com.jdubz.wrist.refresh"

    /// Must run before the app finishes launching.
    func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshId, using: nil) { [weak self] task in
            self?.backgroundRefresh(task)
        }
        scheduleBackgroundRefresh()
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(request) } catch { AppLog.log("refresh schedule error: \(error)") }
    }

    private func backgroundRefresh(_ task: BGTask) {
        AppLog.log("background refresh")
        scheduleBackgroundRefresh()
        let finish = DispatchWorkItem { task.setTaskCompleted(success: true) }
        task.expirationHandler = { finish.cancel(); task.setTaskCompleted(success: false) }
        link.queue.async {
            for u in self.units.values {
                self.link.connect(u.record.id)
                do { try u.service.syncNow() } catch { AppLog.log("\(u.record.entity) refresh sync error: \(error)") }
            }
        }
        // Give the watches time to answer, then push what arrived.
        link.queue.asyncAfter(deadline: .now() + 12) { self.housekeepingAll() }
        link.queue.asyncAfter(deadline: .now() + 24, execute: finish)
    }

    private func recordFix(_ loc: CLLocation) {
        let fix = LocationFix(atMs: Int64(loc.timestamp.timeIntervalSince1970 * 1000),
                              latE7: Int32(loc.coordinate.latitude * 1e7), lonE7: Int32(loc.coordinate.longitude * 1e7),
                              altitudeCm: loc.verticalAccuracy >= 0 ? Int32(loc.altitude * 100) : nil,
                              accuracyCm: Int32(loc.horizontalAccuracy * 100),
                              speedMmS: loc.speed >= 0 ? Int32(loc.speed * 1000) : nil,
                              bearingCdeg: loc.course >= 0 ? Int32(loc.course * 100) : nil)
        link.queue.async {
            for u in self.units.values where u.burstStartedAt == nil && (try? u.service.snapshot())?.activeWorkout != nil {
                try? u.service.recordFixes(fixes: [fix])
            }
        }
    }

    // MARK: pairing

    func startPairing() {
        found = []
        pairing = true
        pairingText = "Looking for watches… Put the watch close to the phone, showing \"Hello / Setup\"."
        link.startScan()
    }

    func cancelPairing() {
        link.stopScan()
        pairing = false
        link.queue.async {
            if let id = self.pairingId, self.units[id] == nil { self.link.drop(id, stay: false) }
            self.pairer = nil
            self.pairingId = nil
        }
    }

    func pair(with watch: Found) {
        link.stopScan()
        pairingText = "Pairing with \(watch.name)… Tap Pair if iOS asks."
        AppLog.log("pair with \(watch.name) \(watch.id)")
        link.queue.async {
            do {
                let known = Settings.watches.map { KnownWatch(mac: $0.mac, secret: $0.secret) }
                self.pairer = try PairingService(secret: Settings.newSecret(), accountId: Settings.accountId,
                                                 known: known, transport: PairTransport(self))
                self.pairingId = watch.id
                self.pairingName = watch.name
                if self.units[watch.id] != nil { self.units[watch.id] = nil }   // re-pairing a known watch
                self.link.connect(watch.id)
            } catch {
                self.ui { self.pairingText = "Pairing could not start: \(error)" }
            }
        }
    }

    func forget(_ id: UUID) {
        AppLog.log("forget \(id)")
        link.drop(id, stay: false)
        link.queue.async {
            self.units[id] = nil
            Settings.remove(id)
            self.publish()
        }
    }

    private func pairingProgressed() {
        guard let pairer, let id = pairingId else { return }
        let p = pairer.progress()
        if case .paired(let mac, _) = p { AppLog.log("pairing: paired \(mac)") } else { AppLog.log("pairing: \(p)") }   // never log the secret
        switch p {
        case .paired(let mac, let secret):
            let entity = WatchRecord.entity(for: pairingName)
            let record = WatchRecord(id: id, mac: mac, secret: secret, name: pairingName,
                                     entity: entity, db: "wpp-\(entity).sqlite")
            Settings.save(record)
            self.pairer = nil
            self.pairingId = nil
            start(record)
            ui {
                self.pairing = false
                self.pairingText = ""
                self.selected = id
            }
            // Start the real session on a fresh link.
            link.drop(id)
        case .probing: ui { self.pairingText = "Talking to the watch…" }
        case .associating: ui { self.pairingText = "Exchanging keys…" }
        case .readopting: ui { self.pairingText = "Re-adopting a watch this phone knew…" }
        case .alreadyAssociated:
            ui { self.pairingText = "This watch still belongs to the Withings app or another phone. Reset it from the watch's own settings, forget it in iPhone Bluetooth settings, and try again." }
        case .unreadableIdentity: ui { self.pairingText = "The watch sent an identity this app can't read." }
        case .idle: break
        }
        publish()
    }

    // MARK: units

    private func start(_ record: WatchRecord) {
        do {
            let service = try WatchService(dbPath: record.dbURL.path, mac: record.mac, secret: record.secret,
                                           transport: ServiceTransport(self, record.id), ancs: HostedAncs(host),
                                           rasterizer: WatchRasterizer())
            service.preferNotifications(enabled: true)      // a reset leaves them off
            applyLocalAlerts(service, record.entity)
            units[record.id] = Unit(record: record, service: service, raw: RawLog(prefix: record.entity, db: record.dbURL))
            link.connect(record.id)
            AppLog.log("started \(record.name) (\(record.entity))")
        } catch {
            AppLog.log("store error for \(record.name): \(error)")
        }
    }

    private func housekeepingAll() {
        DispatchQueue.main.async { CommandPoller.shared.pollIfDue() }
        LiveUplink.flush()
        sendQueuedAlerts()
        for unit in units.values { housekeeping(unit) }
        let now = Date()
        if now.timeIntervalSince(lastPush) >= 300, !units.isEmpty {
            lastPush = now
            let list = units.values.map { (service: $0.service, entity: $0.record.entity) }
            influx.push(list) { text in AppLog.log(text); self.ui { self.influxText = text } }
        }
        publish()
    }

    /// Runs every 15 s while awake, and on every incoming frame in the background (iOS wakes us for BLE).
    private func housekeeping(_ u: Unit) {
        let now = Date()
        let s = u.service
        if now.timeIntervalSince(u.lastTick) >= 30 {
            u.lastTick = now
            do { try s.tick() } catch { AppLog.log("\(u.record.entity) tick error: \(error)") }
            for line in s.unhandledObjects() { AppLog.log("\(u.record.entity) unhandled: \(line)") }
            declareZone(u)
            if !u.scanModeSet, (try? s.dropSleepFeatures(keep: RemoteConfig.load()?.keep_features ?? [])) != nil { u.scanModeSet = true }   // never worn in bed
            runExperiments(u)
            heartRateBurst(u)
            promptForTests(u)
            walkTracker(u)
            sendHeartRateLimits(u)
            rawCapture(u)
            runPolls(u)
            trackStillness(u)
            ecgSession(u, manual: false)
            if let m = RemoteConfig.load()?.dump_minutes { s.setDumpInterval(minutes: m) }
        }
        if now.timeIntervalSince(u.lastResync) >= 60 {
            u.lastResync = now
            do { try s.syncNow() } catch { AppLog.log("\(u.record.entity) sync error: \(error)") }
            AppLog.log("\(u.record.entity) progress \(s.progress())")
        }
        let day = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate])
        if day != u.lastSnapshotDay {
            u.lastSnapshotDay = day
            u.raw.snapshotDatabase()
        }
        if case .finished = s.progress() {
            u.lastSync = now
            syncProfile(u, now)
            noticeWear(u)
            // The battery ask right after connecting lands before the handshake ends and is dropped: ask again here.
            if now.timeIntervalSince(u.lastBattery) >= 600 || (try? s.snapshot())?.battery == nil && now.timeIntervalSince(u.lastBattery) >= 60 {
                u.lastBattery = now
                do { try s.pollBattery() } catch { AppLog.log("\(u.record.entity) battery error: \(error)") }
            }
        }
    }

    /// Restore the user profile a reset wiped (height, weight, birth date), from the NUC's config.
    private func syncProfile(_ u: Unit, _ now: Date) {
        guard now.timeIntervalSince(u.lastProfileCheck) >= 600, let want = RemoteConfig.load()?.profile else { return }
        u.lastProfileCheck = now
        guard let held = (try? u.service.snapshot())?.user else {
            try? u.service.requestDeviceConfig()     // the watch reports its profile with its config
            u.lastProfileCheck = now.addingTimeInterval(-570)   // look again in 30 s, not 10 min
            return
        }
        let birth = want.birth_secs ?? held.birthSecs
        if held.weightGrams / 500 != want.weight_g / 500 || held.heightCm != want.height_cm || held.birthSecs != birth {
            do {
                try u.service.setUser(birthSecs: birth, weightGrams: want.weight_g, heightCm: want.height_cm, firstName: want.name ?? "")
                AppLog.log("\(u.record.entity) profile set: \(want.height_cm) cm, \(want.weight_g / 1000) kg\(want.birth_secs == nil ? ", birth unchanged" : "")")
            } catch { AppLog.log("\(u.record.entity) profile error: \(error)") }
        }
    }

    /// Put on after a break (no heart rate for 30+ minutes, then a reading): ask for a live reading right away.
    private func noticeWear(_ u: Unit) {
        guard let latest = (try? u.service.snapshot())?.latestHr?.atMs else { return }
        defer { u.lastHrMs = max(u.lastHrMs, latest) }
        guard u.lastHrMs > 0, latest > u.lastHrMs, latest - u.lastHrMs >= 30 * 60_000 else { return }
        AppLog.log("\(u.record.entity) put on after \((latest - u.lastHrMs) / 60_000) min: live heart-rate reading")
        do { try u.service.requestLiveHr() } catch { AppLog.log("\(u.record.entity) live HR error: \(error)") }
        if u.record.entity == "scanwatch" {
            AppLog.log("scanwatch put on: asking for an SpO2 reading")
            do { try u.service.requestMeasure(category: 3) } catch { AppLog.log("scanwatch SpO2 request error: \(error)") }
        }
    }

    /// Raw frames the NUC asked for in config.json, sent once each when the watch is synced and idle.
    private func runExperiments(_ u: Unit) {
        guard case .finished = u.service.progress(), let list = RemoteConfig.load()?.experiments else { return }
        let d = UserDefaults.standard
        var done = Set(d.stringArray(forKey: "experimentsDone") ?? [])
        for e in list where e.watch == u.record.entity && !done.contains(e.id) {
            if let action = e.action {
                AppLog.log("experiment \(e.id) -> \(u.record.entity): \(action)")
                if action == "ecg_session" {
                    ecgSession(u, manual: true)
                } else if action == "debug_dump" {
                    do { try u.service.startDebugDump() } catch { AppLog.log("debug dump error: \(error)") }
                } else if action == "flash_read" {
                    readFlash(u)
                }
            } else if let f = e.feature {
                do {
                    try u.service.setFeature(id: f, windowMinutes: e.window_minutes ?? 0)
                    AppLog.log("experiment \(e.id) -> \(u.record.entity): feature \(f) window \(e.window_minutes ?? 0) min")
                } catch { AppLog.log("experiment \(e.id) error: \(error)") }
            } else if let hex = e.hex, let bytes = Data(hexString: hex) {
                AppLog.log("experiment \(e.id) -> \(u.record.entity): \(hex)")
                send(u.record.id, [bytes])
            } else { AppLog.log("experiment \(e.id): nothing to send"); }
            done.insert(e.id)
        }
        d.set(Array(done), forKey: "experimentsDone")
    }

    /// While the watch is worn, run a short workout every so often for second-by-second heart rate.
    /// Off unless config.json has hr_burst. The sessions are remembered so they never count as workouts.
    private func heartRateBurst(_ u: Unit) {
        let now = Date()
        // A burst outlives the app (an update, a relaunch): pick it back up so it still gets stopped.
        if u.burstStartedAt == nil, !u.autoWalk, let running = (try? u.service.snapshot())?.activeWorkout {
            let bursts = UserDefaults.standard.array(forKey: "burstStarts") as? [Double] ?? []
            if bursts.contains(where: { abs($0 * 1000 - Double(running.startedAtMs)) < 120_000 }) {
                u.burstStartedAt = Date(timeIntervalSince1970: Double(running.startedAtMs) / 1000)
                AppLog.log("\(u.record.entity) picked up a running burst")
            }
        }
        if let started = u.burstStartedAt {
            guard let cfg = RemoteConfig.load()?.hr_burst,
                  now.timeIntervalSince(started) < Double(cfg.length_minutes * 60) else {
                do { try u.service.stopWorkout(); AppLog.log("\(u.record.entity) heart-rate burst stopped") }
                catch { AppLog.log("\(u.record.entity) burst stop error: \(error)") }
                u.burstStartedAt = nil
                return
            }
            return
        }
        guard let cfg = RemoteConfig.load()?.hr_burst, cfg.watch == u.record.entity,
              now.timeIntervalSince(u.lastBurst) >= Double(cfg.every_minutes * 60),
              // The last burst is remembered across restarts, so an update doesn't start a new one.
              now.timeIntervalSince1970 - ((UserDefaults.standard.array(forKey: "burstStarts") as? [Double])?.last ?? 0) >= Double(cfg.every_minutes * 60),
              let snap = try? u.service.snapshot(), snap.activeWorkout == nil,
              let hr = snap.latestHr, Int64(now.timeIntervalSince1970 * 1000) - hr.atMs < 20 * 60_000   // worn
        else { return }
        do {
            try u.service.startWorkout(activity: 36)
            u.burstStartedAt = now
            u.lastBurst = now
            var bursts = UserDefaults.standard.array(forKey: "burstStarts") as? [Double] ?? []
            bursts.append(now.timeIntervalSince1970)
            UserDefaults.standard.set(Array(bursts.suffix(500)), forKey: "burstStarts")
            AppLog.log("\(u.record.entity) heart-rate burst started (\(cfg.length_minutes) min)")
        } catch { AppLog.log("\(u.record.entity) burst start error: \(error)") }
    }

    /// Alerts the NUC queued (notify in config/remote), each id once.
    private func sendQueuedAlerts() {
        guard let list = RemoteConfig.load()?.notify, !list.isEmpty else { return }
        let d = UserDefaults.standard
        var done = Set(d.stringArray(forKey: "alertsDone") ?? [])
        for n in list where !done.contains(n.id) {
            notify(title: n.title, message: n.message, icon: n.icon)
            done.insert(n.id)
        }
        d.set(Array(done.suffix(1000)), forKey: "alertsDone")
    }

    /// On a day the ScanWatch is worn: one ECG and one oxygen reading, one retry each, 3 prompts at most.
    /// Only when it is on the wrist and you have been still, 9 am to 10 pm. The crown is set to the test first.
    private func promptForTests(_ u: Unit) {
        guard u.record.entity == "scanwatch", u.burstStartedAt == nil, case .finished = u.service.progress(),
              self.host.isListening(u.record.id) else { return }
        let now = Date(), cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        guard hour >= 9, hour < 22 else { return }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let dayStart = Int64(cal.startOfDay(for: now).timeIntervalSince1970 * 1000)
        guard let snap = try? u.service.snapshot(), snap.activeWorkout == nil, !snap.measuring,
              let hr = snap.latestHr, nowMs - hr.atMs < 30 * 60_000 else { return }          // on the wrist
        let recent = (try? u.service.activityWindows(fromMs: nowMs - 15 * 60_000, toMs: nowMs)) ?? []
        guard recent.reduce(0, { $0 + $1.steps }) < 20 else { return }                       // sitting still

        let d = UserDefaults.standard
        let day = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate])
        let total = d.integer(forKey: "prompt-\(day)-total")
        guard total < 3, now.timeIntervalSince1970 - d.double(forKey: "prompt-\(day)-last") >= 3600 else { return }

        let ecgDone = ((try? u.service.ecgs()) ?? []).contains { $0.measuredAtMs >= dayStart }
        let oxygenDone = ((try? u.service.latestSpo2CheckMs()) ?? nil).map { $0 >= dayStart } ?? false
        let tests: [(name: String, label: String, shortcut: String, done: Bool)] = [
            ("ecg", "ECG", "010989000509a1000101", ecgDone),
            ("oxygen", "Oxygen", "010989000509a1000102", oxygenDone),
        ]
        for t in tests where !t.done {
            let tries = d.integer(forKey: "prompt-\(day)-\(t.name)")
            let last = d.double(forKey: "prompt-\(day)-\(t.name)-last")
            guard tries < 2, now.timeIntervalSince1970 - last >= 4 * 3600, let frame = Data(hexString: t.shortcut) else { continue }
            send(u.record.id, [frame])
            notify(title: "Wrist", message: "Hold crown: \(t.label)", only: u.record.id)
            // Put the crown back on Jack's chosen long-press action (config crown_home, default 8 = Do Not Disturb,
            // 11/11) once the prompted test has had its chance.
            let home = RemoteConfig.load()?.crown_home ?? 8
            if let back = Data(hexString: String(format: "010989000509a10001%02x", home)) {
                link.queue.asyncAfter(deadline: .now() + 15 * 60) { self.send(u.record.id, [back]) }
            }
            d.set(tries + 1, forKey: "prompt-\(day)-\(t.name)")
            d.set(now.timeIntervalSince1970, forKey: "prompt-\(day)-\(t.name)-last")
            d.set(total + 1, forKey: "prompt-\(day)-total")
            d.set(now.timeIntervalSince1970, forKey: "prompt-\(day)-last")
            AppLog.log("prompt: \(t.label), try \(tries + 1) today")
            return
        }
    }

    /// ScanWatch alert slots: daytime AFib always; heart-rate limits and the move reminder when config has them.
    private func applyLocalAlerts(_ service: WatchService, _ entity: String) {
        guard entity == "scanwatch" else { return }
        let a = RemoteConfig.load()?.alerts
        let limits = a?.hr_low != nil && a?.hr_high != nil
        service.setLocalAlerts(afibDay: true, afibNight: false, inactivity: a?.move_reminder ?? false, hrHigh: limits, hrLow: limits)
    }

    /// Sitting = worn and the step counter hasn't moved for a while.
    private func trackStillness(_ u: Unit) {
        guard let count = (try? u.service.snapshot())?.steps?.count else { return }
        let c = Int64(count)
        if c != u.stepsSeen { u.stepsSeen = c; u.stepsStillSince = Date() }
    }

    private func isSitting(_ u: Unit, stillMinutes: Int) -> Bool {
        guard let snap = try? u.service.snapshot(), snap.activeWorkout == nil, u.burstStartedAt == nil,
              let hr = snap.latestHr, Int64(Date().timeIntervalSince1970 * 1000) - hr.atMs < 30 * 60_000 else { return false }
        return u.stepsSeen >= 0 && Date().timeIntervalSince(u.stepsStillSince) >= Double(stillMinutes) * 60
    }

    /// Hands-free ECG: long buzz ("finger on bezel"), a 5-step countdown with a short buzz each second,
    /// then the watch's factory ECG test streams a live 300 Hz ECG. Only while sitting.
    /// Config "ecg_session": {seconds, countdown, still_minutes, per_day, from_hour, to_hour, gap_hours}.
    private func ecgSession(_ u: Unit, manual: Bool) {
        guard u.record.entity == "scanwatch", !u.ecgSessionRunning, case .finished = u.service.progress() else { return }
        let cfg = RemoteConfig.load()?.ecg_session
        let seconds = cfg?.seconds ?? 15, countdown = cfg?.countdown ?? 5, still = cfg?.still_minutes ?? 10
        let d = UserDefaults.standard
        let now = Date()
        if !manual {
            let perDay = cfg?.per_day ?? 2
            let hour = Calendar.current.component(.hour, from: now)
            let day = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate])
            guard perDay > 0, hour >= (cfg?.from_hour ?? 9), hour < (cfg?.to_hour ?? 22),
                  d.integer(forKey: "ecgSession-\(day)") < perDay,
                  now.timeIntervalSince1970 - d.double(forKey: "ecgSessionLast") >= Double(cfg?.gap_hours ?? 3) * 3600
            else { return }
            guard isSitting(u, stillMinutes: still) else { return }
            d.set(d.integer(forKey: "ecgSession-\(day)") + 1, forKey: "ecgSession-\(day)")
        } else if !isSitting(u, stillMinutes: 0) {
            AppLog.log("ecg session: not worn, skipped"); return
        }
        d.set(now.timeIntervalSince1970, forKey: "ecgSessionLast")
        u.ecgSessionRunning = true
        AppLog.log("ecg session: start (\(manual ? "manual" : "auto"), \(seconds) s)")
        let q = link.queue
        // Alerts go to this watch only (the Steel HR stays quiet).
        let post: (String, String, NotificationCategory) -> UInt32 = { title, message, category in
            _ = self.host
            self.host.announceTo = u.record.id
            let id = u.service.postNotification(appId: "com.jdubz.wrist", title: title, subtitle: "", message: message, category: category)
            self.host.announceTo = nil
            return id
        }
        let alert = post("ECG", "", .other)
        q.asyncAfter(deadline: .now() + 2.5) { u.service.dismissNotification(id: alert) }
        for step in 0..<countdown {
            q.asyncAfter(deadline: .now() + 3.5 + Double(step)) {
                let n = post("\(countdown - step)", "", .other)
                q.asyncAfter(deadline: .now() + 0.8) { u.service.dismissNotification(id: n) }
            }
        }
        q.asyncAfter(deadline: .now() + 3.5 + Double(countdown)) {
            let n = UInt32(seconds * 300)
            var frame = Data([0x01, 0x09, 0x79, 0x00, 0x08, 0x02, 0x06, 0x00, 0x04])
            frame.append(contentsOf: [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
            self.send(u.record.id, [frame])
            AppLog.log("ecg session: recording \(seconds) s")
            q.asyncAfter(deadline: .now() + Double(seconds) + 5) { u.ecgSessionRunning = false }
        }
    }

    /// Recurring raw commands from the NUC (config "polls"): each sent every `every_minutes` while linked.
    private func runPolls(_ u: Unit) {
        guard case .finished = u.service.progress(), let polls = RemoteConfig.load()?.polls else { return }
        let d = UserDefaults.standard
        var last = d.dictionary(forKey: "pollLast") as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        var frames: [Data] = []
        for p in polls where p.watch == u.record.entity {
            guard now - (last[p.id] ?? 0) >= Double(p.every_minutes) * 60, let f = Data(hexString: p.hex) else { continue }
            frames.append(f)
            last[p.id] = now
        }
        guard !frames.isEmpty else { return }
        d.set(last, forKey: "pollLast")
        send(u.record.id, frames)
    }

    /// Raw accelerometer and light-sensor recording only while the watch is on the wrist.
    private func rawCapture(_ u: Unit) {
        guard u.record.entity == "scanwatch", case .finished = u.service.progress(),
              let hr = (try? u.service.snapshot())?.latestHr else { return }
        let worn = Int64(Date().timeIntervalSince1970 * 1000) - hr.atMs < 30 * 60_000
        if u.rawCaptureOn != worn { AppLog.log("scanwatch raw capture \(worn ? "on" : "off")") }
        u.rawCaptureOn = worn
        do { try u.service.setRawCapture(on: worn, mask: RemoteConfig.load()?.raw_mask) } catch { AppLog.log("raw capture error: \(error)") }
    }

    private func sendHeartRateLimits(_ u: Unit) {
        guard u.record.entity == "scanwatch", !u.limitsSent, case .finished = u.service.progress(),
              let a = RemoteConfig.load()?.alerts, let low = a.hr_low, let high = a.hr_high else { return }
        u.limitsSent = true
        do { try u.service.setHrThresholds(low: low, high: high); AppLog.log("heart-rate limits sent: \(low)-\(high)") }
        catch { AppLog.log("heart-rate limits error: \(error)") }
    }

    /// Start a workout when the step counter says you're walking, end it when you stop: second-by-second
    /// heart rate and a GPS route. Watches the live counter every 2 minutes; 60+ steps a minute counts as walking.
    private func walkTracker(_ u: Unit) {
        guard u.record.entity == "scanwatch", case .finished = u.service.progress() else { return }
        let now = Date()
        let snap = try? u.service.snapshot()
        let recording = snap?.activeWorkout != nil && u.burstStartedAt == nil
        KeepAlive.shared.setTracking(recording)
        // A walk outlives the app too.
        if !u.autoWalk, let running = snap?.activeWorkout,
           abs(UserDefaults.standard.double(forKey: "autoWalkStart") * 1000 - Double(running.startedAtMs)) < 120_000 {
            u.autoWalk = true
        }
        guard now.timeIntervalSince(u.lastStepPoll) >= 120 else { return }
        u.lastStepPoll = now
        try? u.service.requestRefresh()
        guard let count = snap?.steps?.count else { return }
        defer { u.lastStepCount = count }
        guard let last = u.lastStepCount, count >= last else { return }
        let delta = count - last
        if delta >= 120 { u.movingPolls += 1; u.stillPolls = 0 }
        else if delta < 30 { u.stillPolls += 1; u.movingPolls = 0 }
        if u.autoWalk {
            guard u.stillPolls >= 2 else { return }
            try? u.service.setFeature(id: 54, windowMinutes: -1); try? u.service.setFeature(id: 55, windowMinutes: -1)
            do { try u.service.stopWorkout(); AppLog.log("walk ended") } catch { AppLog.log("walk stop error: \(error)") }
            u.autoWalk = false
        } else if u.movingPolls >= 2, snap?.activeWorkout == nil, u.burstStartedAt == nil {
            do {
                try u.service.startWorkout(activity: 1); u.autoWalk = true
                // Raw PPG + accelerometer for the whole walk (the firmware only records 1 walk in 8 itself).
                try? u.service.setFeature(id: 54, windowMinutes: 20); try? u.service.setFeature(id: 55, windowMinutes: 20)
                UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "autoWalkStart")
                AppLog.log("walk started")
            }
            catch { AppLog.log("walk start error: \(error)") }
        }
    }

    /// Read the watch's whole 8 MB flash, 16 KB at a time, into Documents/raw. Read-only; resumes if interrupted.
    private func readFlash(_ u: Unit) {
        guard !u.flashRunning else { return }
        u.flashRunning = true
        let block: UInt32 = 0x4000, size: UInt32 = 0x800000
        let url = Settings.documents.appendingPathComponent("raw/flash-\(u.record.entity).bin")
        DispatchQueue.global(qos: .utility).async {
            defer { u.flashRunning = false }
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            guard let out = try? FileHandle(forWritingTo: url) else { AppLog.log("flash: can't open file"); return }
            defer { try? out.close() }
            let have = UInt32((try? out.seekToEnd()) ?? 0)
            var offset = have / block * block
            try? out.seek(toOffset: UInt64(offset))
            AppLog.log("flash: reading from \(offset)")
            var failures = 0
            while offset < size {
                self.link.queue.sync { try? u.service.spiFlashRead(addr: offset, len: block) }
                let started = Date()
                var got: Data?
                while Date().timeIntervalSince(started) < 30 {
                    guard let p = u.service.spiFlashProgress() else { break }
                    if let e = p.error { AppLog.log("flash: watch refused at \(offset) (\(e))"); return }
                    if p.done { got = u.service.spiFlashTake(); break }
                    Thread.sleep(forTimeInterval: 0.04)
                }
                guard let data = got, data.count == Int(block) else {
                    failures += 1
                    if failures > 20 { AppLog.log("flash: gave up at \(offset)"); return }
                    Thread.sleep(forTimeInterval: 5)
                    continue
                }
                failures = 0
                try? out.write(contentsOf: data)
                offset += block
                if offset % 0x100000 == 0 { AppLog.log("flash: \(offset / 0x100000) MB") }
            }
            AppLog.log("flash: done")
        }
    }

    func screens(_ id: UUID) -> [WatchScreen] { link.queue.sync { units[id]?.service.screens() ?? [] } }
    func loadScreens(_ id: UUID) { with(id) { try? $0.service.requestScreens() } }
    func setScreens(_ id: UUID, _ order: [UInt8]) {
        with(id) { u in
            do { try u.service.setScreens(ids: Data(order)); AppLog.log("screens set: \(order)") }
            catch { AppLog.log("screens error: \(error)") }
        }
    }

    private func declareZone(_ u: Unit) {
        let tz = TimeZone.current
        let offset = Int32(tz.secondsFromGMT())
        guard offset != u.lastZoneOffset else { return }
        var change: DstChange?
        if let next = tz.nextDaylightSavingTimeTransition {
            change = DstChange(atMs: Int64(next.timeIntervalSince1970 * 1000),
                               gmtOffsetSeconds: Int32(tz.secondsFromGMT(for: next.addingTimeInterval(1))))
        }
        if (try? u.service.setZone(gmtOffset: offset, nextChange: change)) != nil { u.lastZoneOffset = offset }
    }

    /// Call on the BLE queue.
    private func publish() {
        let start = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var list: [Card] = Settings.watches.compactMap { record in
            guard let u = units[record.id] else { return nil }
            return Card(id: record.id, name: record.name, state: link.state(record.id),
                        snapshot: try? u.service.snapshot(),
                        hrToday: (try? u.service.hrSeries(fromMs: start, toMs: nowMs, maxPoints: 300)) ?? [],
                        lastSync: u.lastSync)
        }
        list.sort { $0.name < $1.name }
        ui { self.cards = list }
    }

    // MARK: actions from the UI

    private func with(_ id: UUID?, _ body: @escaping (Unit) -> Void) {
        let target = id ?? current?.id     // read UI state on the main thread
        link.queue.async {
            guard let id = target, let u = self.units[id] else { return }
            body(u)
            self.publish()
        }
    }

    /// An alert to every watch listening, through Wrist's own Bluetooth alert service.
    func notify(title: String, message: String, icon: String? = nil, only watch: UUID? = nil) {
        link.queue.async {
            _ = self.host
            guard let u = self.ancsUnit else { return }
            // Picture alerts (0.8.10): the watch only shows apps it has enabled, so a new app id was received but never
            // displayed (0.8.9). Keep Wrist's own id and clear the watch's notification-icon cache (CACHE_INVALIDATE 2410,
            // type 1) so it asks for Wrist's icon again; WatchRasterizer answers with this alert's picture.
            let appId = "com.jdubz.wrist"
            var picture: UIImage? = nil
            if let icon, let url = URL(string: icon), let data = try? Data(contentsOf: url) { picture = UIImage(data: data) }
            if picture != nil || WatchRasterizer.pictures[appId] != nil {
                WatchRasterizer.pictures[appId] = picture
                if let frame = Data(hexString: "01096a0005096800010" + "1") { self.send(u.record.id, [frame]) }
            }
            self.host.announceTo = watch
            let id = u.service.postNotification(appId: appId, title: title, subtitle: "", message: message, category: .other)
            self.host.announceTo = nil
            AppLog.log("alert \(id) posted; \(self.host.listeners) watch(es) listening")
        }
    }

    func handsStart(_ id: UUID) { with(id) { try? $0.service.handsCalibrationStart() } }
    func handsMove(_ id: UUID, hand: UInt8, steps: Int16) { with(id) { try? $0.service.handsMove(hand: hand, steps: steps) } }
    func handsStop(_ id: UUID) { with(id) { try? $0.service.handsCalibrationStop() } }

    func syncNow() { with(nil) { try? $0.service.syncNow() } }

    func setAllDayScan(_ on: Bool) {
        Settings.allDayScan = on
        link.queue.async {
            for u in self.units.values where u.record.entity == "scanwatch" {
                _ = on; try? u.service.dropSleepFeatures(keep: RemoteConfig.load()?.keep_features ?? [])
            }
        }
    }

    func setNotifications(_ id: UUID, _ on: Bool) { with(id) { try? $0.service.setNotifications(enabled: on) } }

    func healthFeatures(_ id: UUID) -> [HealthFeature] {
        link.queue.sync { units[id]?.service.healthFeatures() ?? [] }
    }

    func setHealthFeature(_ id: UUID, _ feature: UInt16, _ on: Bool) {
        with(id) { try? $0.service.setHealthFeature(id: feature, enabled: on) }
    }

    // MARK: WatchLinkDelegate (BLE queue)

    func linkReady(_ id: UUID) {
        if let pairer, id == pairingId {
            AppLog.log("link ready (pairing)")
            pairer.onConnected(); pairingProgressed(); return
        }
        guard let u = units[id] else { return }
        AppLog.log("\(u.record.entity) link ready")
        applyLocalAlerts(u.service, u.record.entity)
        do { try u.service.onConnected() } catch { AppLog.log("\(u.record.entity) onConnected error: \(error)") }
        u.lastZoneOffset = nil
        declareZone(u)
        try? u.service.pollBattery()
        publish()
    }

    func linkBytes(_ id: UUID, _ bytes: Data) {
        if let pairer, id == pairingId {
            pairingRaw.fromWatch(bytes)
            pairer.onBytes(bytes: bytes); pairingProgressed(); return
        }
        guard let u = units[id] else { return }
        u.raw.fromWatch(bytes)
        do { try u.service.onBytes(bytes: bytes, receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)) }
        catch { AppLog.log("\(u.record.entity) onBytes error: \(error)") }
        housekeeping(u)
    }

    func linkDisconnected(_ id: UUID) {
        if id == pairingId { pairer?.onDisconnected() }
        if let u = units[id] {
            AppLog.log("\(u.record.entity) link down")
            u.service.onDisconnected()
        }
        publish()
    }

    func linkDiscovered(_ id: UUID, name: String, rssi: Int) {
        AppLog.log("found \(name) rssi \(rssi)")
        ui {
            self.found.removeAll { $0.id == id }
            self.found.append(Found(id: id, name: name, rssi: rssi))
            self.found.sort { $0.rssi > $1.rssi }
        }
    }

    // MARK: callbacks from the core

    fileprivate func send(_ id: UUID, _ frames: [Data]) {
        if id == pairingId { frames.forEach(pairingRaw.toWatch) } else if let u = units[id] { frames.forEach(u.raw.toWatch) }
        link.write(id, frames)
    }
    fileprivate func coreChanged() { link.queue.async { self.publish() } }
    fileprivate func coreWantsReconnect(_ id: UUID) { link.drop(id) }

    private func ui(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }
}

extension Data {
    init?(hexString: String) {
        let clean = hexString.replacingOccurrences(of: " ", with: "")
        guard clean.count % 2 == 0 else { return nil }
        var out = Data(capacity: clean.count / 2)
        var i = clean.startIndex
        while i < clean.endIndex {
            let j = clean.index(i, offsetBy: 2)
            guard let b = UInt8(clean[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        self = out
    }
}

private final class ServiceTransport: Transport {
    weak var owner: WatchController?
    let id: UUID
    init(_ owner: WatchController, _ id: UUID) { self.owner = owner; self.id = id }
    func write(frames: [Data]) { owner?.send(id, frames) }
    func changed() { owner?.coreChanged() }
    func reconnect() { owner?.coreWantsReconnect(id) }
}

private final class PairTransport: Transport {
    weak var owner: WatchController?
    init(_ owner: WatchController) { self.owner = owner }
    // Called by the core from inside a BLE-queue call, so pairingId is safe to read here.
    func write(frames: [Data]) {
        guard let owner, let id = owner.pairingId else { return }
        owner.send(id, frames)
    }
    func changed() {}
    func reconnect() {}
}

private final class HostedAncs: AncsLink {
    let host: AncsHost
    init(_ host: AncsHost) { self.host = host }
    func announce(bytes: Data) { host.announce(bytes) }
    func attributes(bytes: Data) { host.attributes(bytes) }
}
