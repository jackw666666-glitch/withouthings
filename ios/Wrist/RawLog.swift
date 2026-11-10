import Foundation

/// Every byte to and from the watch, untouched, one file per day:
///   Documents/raw/<entity>-YYYY-MM-DD.wpp   (one file per watch per day; pairing traffic in pairing-…)
/// Record = 8-byte little-endian unix ms, 1 byte direction (0 = from watch, 1 = to watch),
///          2-byte little-endian length, then the bytes exactly as they crossed the GATT characteristic.
/// The NUC pulls these daily (phone_pull.sh) into /mnt/BACKUPS/WITHINGS_RAW/phone/.
final class RawLog {
    private let dir: URL
    private let prefix: String
    private let db: URL?
    private var handle: FileHandle?
    private var day = ""
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(prefix: String, db: URL?) {
        self.prefix = prefix
        self.db = db
        dir = Settings.documents.appendingPathComponent("raw", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func fromWatch(_ bytes: Data) { append(0, bytes) }
    func toWatch(_ bytes: Data) { append(1, bytes) }

    private func append(_ direction: UInt8, _ bytes: Data) {
        LiveUplink.frame(prefix, direction, bytes)
        let now = Date()
        let today = fmt.string(from: now)
        if today != day || handle == nil {
            try? handle?.close()
            let url = dir.appendingPathComponent("\(prefix)-\(today).wpp")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
            day = today
        }
        var record = Data(capacity: 11 + bytes.count)
        var ms = UInt64(now.timeIntervalSince1970 * 1000).littleEndian
        withUnsafeBytes(of: &ms) { record.append(contentsOf: $0) }
        record.append(direction)
        var len = UInt16(min(bytes.count, Int(UInt16.max))).littleEndian
        withUnsafeBytes(of: &len) { record.append(contentsOf: $0) }
        record.append(bytes.prefix(Int(UInt16.max)))
        try? handle?.write(contentsOf: record)
    }

    /// Daily copy of the app's database (db + WAL) so the parsed store is archived too.
    /// Called on the BLE queue, which is the only place the store is written, so the copy is consistent.
    func snapshotDatabase() {
        guard let db else { return }
        let snapDir = dir.appendingPathComponent("db", isDirectory: true)
        try? FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        let stamp = fmt.string(from: Date())
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: db.path + suffix)
            let dst = snapDir.appendingPathComponent("\(prefix)-\(stamp).sqlite\(suffix)")
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
    }
}
