import Foundation
import SwiftUI

/// Glue between the Bluetooth link and the Rust protocol core (withouthings' wpp-ffi).
/// All core calls happen on the BLE queue so frames, ticks and store writes stay in order.
final class WatchController: NSObject, ObservableObject, WatchLinkDelegate {
    static let shared = WatchController()

    struct Found: Identifiable, Equatable { let id: UUID; let name: String; let rssi: Int }

    @Published var linkState = "Starting"
    @Published var snapshot: Snapshot?
    @Published var paired = Settings.paired
    @Published var pairing = false
    @Published var pairingText = ""
    @Published var found: [Found] = []
    @Published var influxText = ""
    @Published var lastSync: Date?
    @Published var hrToday: [HrPoint] = []

    let link = WatchLink()
    let raw = RawLog()
    private lazy var influx = InfluxPusher()
    private var service: WatchService?
    private var pairer: PairingService?
    private var pairingId: UUID?
    private var lastTick = Date.distantPast
    private var lastResync = Date.distantPast
    private var lastPush = Date.distantPast
    private var lastSnapshotDay = ""
    private var timer: Timer?

    override init() {
        super.init()
        link.delegate = self
        if Settings.paired { link.queue.async { self.makeService() } }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.link.queue.async { self?.housekeeping() }
        }
    }

    // MARK: pairing

    func startPairing() {
        found = []
        pairing = true
        pairingText = "Looking for your watch… Put it close to the phone."
        link.startScan()
    }

    func cancelPairing() {
        link.stopScan()
        pairing = false
        link.queue.async { self.pairer = nil }
    }

    func pair(with watch: Found) {
        link.stopScan()
        pairingText = "Pairing with \(watch.name)… Press the crown if the watch asks."
        link.queue.async {
            do {
                let known: [KnownWatch] = {
                    guard let m = Settings.mac, let s = Settings.secret else { return [] }
                    return [KnownWatch(mac: m, secret: s)]
                }()
                self.pairer = try PairingService(secret: Settings.newSecret(), accountId: Settings.accountId,
                                                 known: known, transport: PairTransport(self))
                self.pairingId = watch.id
                Settings.watchName = watch.name
                self.link.connect(watch.id)
            } catch {
                self.ui { self.pairingText = "Pairing could not start: \(error)" }
            }
        }
    }

    func forget() {
        link.drop(stay: false)
        link.queue.async {
            self.service = nil
            Settings.forget()
            self.ui { self.paired = false; self.snapshot = nil }
        }
    }

    // MARK: service

    private func makeService() {
        guard let mac = Settings.mac, let secret = Settings.secret else { return }
        do {
            service = try WatchService(dbPath: Settings.dbURL.path, mac: mac, secret: secret,
                                       transport: ServiceTransport(self), ancs: NoAncs(), rasterizer: WatchRasterizer())
            if let id = Settings.peripheralId { link.connect(id) }
        } catch {
            ui { self.linkState = "Store error: \(error)" }
        }
    }

    private func pairingProgressed() {
        guard let pairer else { return }
        switch pairer.progress() {
        case .paired(let mac, let secret):
            Settings.mac = mac
            Settings.secret = secret
            Settings.peripheralId = pairingId
            self.pairer = nil
            makeService()
            ui {
                self.paired = true
                self.pairing = false
                self.pairingText = ""
            }
            // Start the real session on a fresh link.
            link.drop()
        case .probing: ui { self.pairingText = "Talking to the watch…" }
        case .associating: ui { self.pairingText = "Exchanging keys…" }
        case .readopting: ui { self.pairingText = "Re-adopting a watch this phone knew…" }
        case .alreadyAssociated:
            ui { self.pairingText = "This watch still belongs to another phone/app. Reset it from the watch (Settings → Reset) and try again." }
        case .unreadableIdentity: ui { self.pairingText = "The watch sent an identity this app can't read." }
        case .idle: break
        }
    }

    /// Runs every 15 s while awake, and on every incoming frame in the background (iOS wakes us for BLE).
    private func housekeeping() {
        let now = Date()
        guard let service else { return }
        if now.timeIntervalSince(lastTick) >= 30 {
            lastTick = now
            try? service.tick()
            declareZone(service)
            if Settings.allDayScan, service.respiratoryScan() == nil { try? service.armRespiratoryScan() }
        }
        if now.timeIntervalSince(lastResync) >= 60 {
            lastResync = now
            try? service.syncNow()
        }
        let day = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate])
        if day != lastSnapshotDay {
            lastSnapshotDay = day
            raw.snapshotDatabase()
        }
        if now.timeIntervalSince(lastPush) >= 300 {
            lastPush = now
            influx.push(service) { text in self.ui { self.influxText = text } }
        }
        refresh()
    }

    private var lastZoneOffset: Int32?
    private func declareZone(_ service: WatchService) {
        let tz = TimeZone.current
        let offset = Int32(tz.secondsFromGMT())
        guard offset != lastZoneOffset else { return }
        var change: DstChange?
        if let next = tz.nextDaylightSavingTimeTransition {
            change = DstChange(atMs: Int64(next.timeIntervalSince1970 * 1000),
                               gmtOffsetSeconds: Int32(tz.secondsFromGMT(for: next.addingTimeInterval(1))))
        }
        if (try? service.setZone(gmtOffset: offset, nextChange: change)) != nil { lastZoneOffset = offset }
    }

    private func refresh() {
        guard let service else { return }
        let snap = try? service.snapshot()
        let start = Calendar.current.startOfDay(for: Date())
        let hr = (try? service.hrSeries(fromMs: Int64(start.timeIntervalSince1970 * 1000),
                                        toMs: Int64(Date().timeIntervalSince1970 * 1000), maxPoints: 300)) ?? []
        let state = link.state
        ui {
            self.snapshot = snap
            self.hrToday = hr
            self.linkState = state
            if case .finished = snap?.progress { self.lastSync = Date() }
        }
    }

    func syncNow() { link.queue.async { try? self.service?.syncNow(); self.refresh() } }

    func setAllDayScan(_ on: Bool) {
        Settings.allDayScan = on
        link.queue.async {
            guard let s = self.service else { return }
            if on { try? s.armRespiratoryScan() } else { try? s.cancelRespiratoryScan() }
        }
    }

    func setNotifications(_ on: Bool) { link.queue.async { try? self.service?.setNotifications(enabled: on) } }

    func healthFeatures() -> [HealthFeature] { service?.healthFeatures() ?? [] }
    func setHealthFeature(_ id: UInt16, _ on: Bool) { link.queue.async { try? self.service?.setHealthFeature(id: id, enabled: on) } }

    // MARK: WatchLinkDelegate (BLE queue)

    func linkReady() {
        if let pairer { pairer.onConnected(); pairingProgressed(); return }
        guard let service else { return }
        do { try service.onConnected() } catch { ui { self.linkState = "\(error)" } }
        lastZoneOffset = nil
        declareZone(service)
        try? service.pollBattery()
        refresh()
    }

    func linkBytes(_ bytes: Data) {
        raw.fromWatch(bytes)
        if let pairer { pairer.onBytes(bytes: bytes); pairingProgressed(); return }
        try? service?.onBytes(bytes: bytes, receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000))
        housekeeping()
    }

    func linkDisconnected() {
        pairer?.onDisconnected()
        service?.onDisconnected()
        let state = link.state
        ui { self.linkState = state }
    }

    func linkDiscovered(_ id: UUID, name: String, rssi: Int) {
        ui {
            self.found.removeAll { $0.id == id }
            self.found.append(Found(id: id, name: name, rssi: rssi))
            self.found.sort { $0.rssi > $1.rssi }
        }
    }

    // MARK: callbacks from the core

    fileprivate func send(_ frames: [Data]) {
        frames.forEach(raw.toWatch)
        link.write(frames)
    }
    fileprivate func coreChanged() { link.queue.async { self.refresh() } }
    fileprivate func coreWantsReconnect() { link.drop() }

    private func ui(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }
}

private final class ServiceTransport: Transport {
    weak var owner: WatchController?
    init(_ owner: WatchController) { self.owner = owner }
    func write(frames: [Data]) { owner?.send(frames) }
    func changed() { owner?.coreChanged() }
    func reconnect() { owner?.coreWantsReconnect() }
}

private final class PairTransport: Transport {
    weak var owner: WatchController?
    init(_ owner: WatchController) { self.owner = owner }
    func write(frames: [Data]) { owner?.send(frames) }
    func changed() {}
    func reconnect() { owner?.coreWantsReconnect() }
}

/// iOS hosts the real ANCS service itself, so the watch reads notifications straight from the phone.
private final class NoAncs: AncsLink {
    func announce(bytes: Data) {}
    func attributes(bytes: Data) {}
}
