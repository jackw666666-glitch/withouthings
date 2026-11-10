import Foundation

/// Live copy of the app log and of the watch's small frames (command replies, live data) in InfluxDB,
/// so the NUC sees an experiment's answer within seconds instead of after a file pull.
///   wrist_live,src=app msg="..."
///   wrist_live,src=<entity>,dir=rx|tx hex="..."
/// Bulk transfers (debug dumps, flash reads, history sync) stay in the raw files only.
enum LiveUplink {
    private static let queue = DispatchQueue(label: "wrist.live")
    private static var lines: [String] = []
    private static var seq: Int64 = 0
    private static var skipping: [String: Bool] = [:]
    private static var lastFlush = Date.distantPast
    private static var busy = false
    private static let bulk: Set<UInt16> = [280, 2386, 2424, 1286, 2344, 327]

    static func log(_ message: String) {
        queue.async { add("wrist_live,src=app msg=\"\(escape(message))\"") }
    }

    private static var remaining: [String: Int] = [:]

    static func frame(_ src: String, _ direction: UInt8, _ bytes: Data) {
        queue.async {
            // Frames: 01 | cmd BE16 | len BE16 | payload; a frame can span several BLE chunks.
            let key = "\(src)-\(direction)"
            if (remaining[key] ?? 0) > 0 {
                remaining[key] = max(0, (remaining[key] ?? 0) - bytes.count)
            } else if bytes.count >= 5, bytes[bytes.startIndex] == 1 {
                let b = bytes.startIndex
                let cmd = (UInt16(bytes[b + 1]) << 8 | UInt16(bytes[b + 2])) & 0x3FFF
                let len = Int(UInt16(bytes[b + 3]) << 8 | UInt16(bytes[b + 4]))
                skipping[key] = bulk.contains(cmd)
                remaining[key] = max(0, 5 + len - bytes.count)
            }
            guard skipping[key] != true else { return }
            let hex = bytes.prefix(512).map { String(format: "%02x", $0) }.joined()
            add("wrist_live,src=\(src),dir=\(direction == 0 ? "rx" : "tx") hex=\"\(hex)\"")
        }
    }

    private static func add(_ line: String) {
        seq += 1
        let ns = Int64(Date().timeIntervalSince1970 * 1000) * 1_000_000 + seq % 1_000_000
        lines.append("\(line) \(ns)")
        if lines.count > 20_000 { lines.removeFirst(lines.count - 20_000) }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Send what's buffered; called every 15 s from housekeeping.
    static func flush() {
        queue.async {
            guard !busy, !lines.isEmpty, Date().timeIntervalSince(lastFlush) >= 10,
                  let cfg = RemoteConfig.loadBase(),
                  var comps = URLComponents(string: cfg.influx_url + "/api/v2/write") else { return }
            comps.queryItems = [.init(name: "org", value: cfg.influx_org), .init(name: "bucket", value: cfg.influx_bucket),
                                .init(name: "precision", value: "ns")]
            guard let url = comps.url else { return }
            let batch = Array(lines.prefix(5000))
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Token \(cfg.influx_token)", forHTTPHeaderField: "Authorization")
            req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = batch.joined(separator: "\n").data(using: .utf8)
            req.timeoutInterval = 20
            busy = true
            lastFlush = Date()
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                queue.async {
                    busy = false
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 204 || code == 400 || code == 422 { lines.removeFirst(min(batch.count, lines.count)) }
                }
            }.resume()
        }
    }
}
