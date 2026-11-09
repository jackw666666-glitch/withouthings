import Foundation

/// Human-readable app events next to the raw byte log: Documents/raw/app-YYYY-MM-DD.log
/// (link states, pairing steps, core errors, Influx results). Pulled to the NUC with the raw files.
enum AppLog {
    private static let queue = DispatchQueue(label: "wrist.applog")
    private static let day: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func log(_ message: String) {
        let now = Date()
        queue.async {
            let dir = Settings.documents.appendingPathComponent("raw", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("app-\(day.string(from: now)).log")
            let line = "\(clock.string(from: now)) \(message)\n"
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
