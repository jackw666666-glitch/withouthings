import Foundation

/// Everything the app remembers. Pairing identity lives in UserDefaults; InfluxDB settings come from
/// Documents/config.json, which the NUC drops in over the house_arrest file service (no typing on the phone).
enum Settings {
    private static let d = UserDefaults.standard

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// Every paired watch. A watch's database and raw log are named after its `entity`.
    static var watches: [WatchRecord] {
        get {
            if let data = d.data(forKey: "watches"), let list = try? JSONDecoder().decode([WatchRecord].self, from: data) {
                return list
            }
            // v0.1 kept a single watch in loose keys: carry it over.
            if let mac = d.string(forKey: "mac"), let secret = d.string(forKey: "secret"),
               let id = d.string(forKey: "peripheral").flatMap(UUID.init(uuidString:)) {
                let name = d.string(forKey: "watchName") ?? "ScanWatch"
                let migrated = [WatchRecord(id: id, mac: mac, secret: secret, name: name,
                                            entity: WatchRecord.entity(for: name), db: "wpp.sqlite")]
                self.watches = migrated
                return migrated
            }
            return []
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "watches") }
    }

    static func save(_ watch: WatchRecord) {
        var list = watches.filter { $0.id != watch.id && $0.mac != watch.mac }
        list.append(watch)
        watches = list
    }

    static func remove(_ id: UUID) { watches = watches.filter { $0.id != id } }

    /// Withings protocol account id: random, chosen once.
    static var accountId: UInt32 {
        let stored = d.integer(forKey: "accountId")
        if stored != 0 { return UInt32(stored) }
        let fresh = UInt32.random(in: 1...UInt32(Int32.max))
        d.set(Int(fresh), forKey: "accountId")
        return fresh
    }

    static func newSecret() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<32).map { _ in alphabet.randomElement()! })
    }

    static var allDayScan: Bool {
        get { d.object(forKey: "allDayScan") as? Bool ?? true }   // on unless turned off
        set { d.set(newValue, forKey: "allDayScan") }
    }

    static var influxWatermarkMs: Int64 {
        get { Int64(d.double(forKey: "influxWatermark")) }
        set { d.set(Double(newValue), forKey: "influxWatermark") }
    }
}

struct WatchRecord: Codable, Identifiable, Equatable {
    var id: UUID          // CoreBluetooth peripheral identifier
    var mac: String
    var secret: String
    var name: String
    var entity: String    // InfluxDB entity_id for this watch's battery: "scanwatch" / "steelhr"
    var db: String        // database file in Documents

    var dbURL: URL { Settings.documents.appendingPathComponent(db) }

    static func entity(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("steel") || n.contains("activit") { return "steelhr" }
        return "scanwatch"
    }
}

/// Documents/config.json (written by the NUC):
/// {"influx_url": "http://<nuc>:8086", "influx_org": "<org>", "influx_bucket": "home_assistant",
///  "influx_token": "...", "entity": "scanwatch"}
struct RemoteConfig: Decodable {
    var influx_url: String
    var influx_org: String
    var influx_bucket: String
    var influx_token: String
    var entity: String?
    /// Basal kcal/day the Withings cloud added to active calories (total = active + bmr).
    var bmr_kcal: Double?
    /// The watch's user profile (a reset wipes it; calories and distance depend on it).
    var profile: Profile?
    /// One-off raw frames to send a watch (hex, already framed), run once each by id. Replies land in the raw log.
    var experiments: [Experiment]?

    struct Experiment: Decodable {
        var id: String
        var watch: String
        var hex: String?
        /// Instead of bytes: "debug_dump" or "flash_read".
        var action: String?
        /// Feature experiment instead of raw bytes: window_minutes < 0 off, 0 permanent, > 0 from now.
        var feature: UInt16?
        var window_minutes: Int32?
    }
    /// Feature ids the "never in bed" cleanup must leave alone (an experiment is using them).
    var keep_features: [UInt16]?
    /// Short workouts while worn, for a burst of second-by-second heart rate.
    var hr_burst: HrBurst?
    /// The NUC file Wrist polls every minute (commands that should arrive fast).
    var commands_url: String?
    /// The watch's own alerts: heart-rate limits and the move reminder.
    var alerts: Alerts?
    /// Which raw sensors the watch records (debug mask bits); nil = the default set.
    var raw_mask: UInt32?

    struct Alerts: Decodable {
        var hr_low: UInt8?
        var hr_high: UInt8?
        var move_reminder: Bool?
    }
    /// One-off alerts to show on the watches, each id once.
    var notify: [Notify]?

    struct Notify: Decodable {
        var id: String
        var title: String
        var message: String
    }

    struct HrBurst: Decodable {
        var watch: String
        var every_minutes: Int
        var length_minutes: Int
    }

    struct Profile: Decodable {
        var birth_secs: Int64?
        var weight_g: UInt32
        var height_cm: UInt32
        var name: String?
    }

    /// config.json alone (pushed by the NUC over the cable/Wi-Fi file service).
    static func loadBase() -> RemoteConfig? {
        let url = Settings.documents.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RemoteConfig.self, from: data)
    }

    /// config.json with the polled remote.json on top: its experiments and alerts are added,
    /// its keep_features / hr_burst win.
    static func load() -> RemoteConfig? {
        guard var base = loadBase() else { return nil }
        let url = Settings.documents.appendingPathComponent("remote.json")
        guard let data = try? Data(contentsOf: url), let remote = try? JSONDecoder().decode(Remote.self, from: data) else { return base }
        base.experiments = (base.experiments ?? []) + (remote.experiments ?? [])
        base.notify = (base.notify ?? []) + (remote.notify ?? [])
        if let k = remote.keep_features { base.keep_features = k }
        if let h = remote.hr_burst { base.hr_burst = h }
        if let a = remote.alerts { base.alerts = a }
        if let m = remote.raw_mask { base.raw_mask = m }
        return base
    }

    /// What the polled file may carry.
    struct Remote: Decodable {
        var experiments: [Experiment]?
        var notify: [Notify]?
        var keep_features: [UInt16]?
        var hr_burst: HrBurst?
        var alerts: Alerts?
        var raw_mask: UInt32?
    }
}
