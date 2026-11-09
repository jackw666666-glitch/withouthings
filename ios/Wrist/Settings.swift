import Foundation

/// Everything the app remembers. Pairing identity lives in UserDefaults; InfluxDB settings come from
/// Documents/config.json, which the NUC drops in over the house_arrest file service (no typing on the phone).
enum Settings {
    private static let d = UserDefaults.standard

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var dbURL: URL { documents.appendingPathComponent("wpp.sqlite") }

    static var mac: String? {
        get { d.string(forKey: "mac") }
        set { d.set(newValue, forKey: "mac") }
    }
    static var secret: String? {
        get { d.string(forKey: "secret") }
        set { d.set(newValue, forKey: "secret") }
    }
    static var peripheralId: UUID? {
        get { d.string(forKey: "peripheral").flatMap(UUID.init(uuidString:)) }
        set { d.set(newValue?.uuidString, forKey: "peripheral") }
    }
    static var watchName: String {
        get { d.string(forKey: "watchName") ?? "" }
        set { d.set(newValue, forKey: "watchName") }
    }
    static var paired: Bool { mac != nil && secret != nil && peripheralId != nil }

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
        get { d.bool(forKey: "allDayScan") }
        set { d.set(newValue, forKey: "allDayScan") }
    }

    static var influxWatermarkMs: Int64 {
        get { Int64(d.double(forKey: "influxWatermark")) }
        set { d.set(Double(newValue), forKey: "influxWatermark") }
    }

    static func forget() {
        for k in ["mac", "secret", "peripheral", "watchName", "influxWatermark"] { d.removeObject(forKey: k) }
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

    static func load() -> RemoteConfig? {
        let url = Settings.documents.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RemoteConfig.self, from: data)
    }
}
