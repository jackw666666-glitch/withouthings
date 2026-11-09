import Foundation

/// Writes watch data into the same InfluxDB series the old Withings-cloud collectors filled,
/// so the STEPS card, Body tab and HA sensors keep working. Conventions copied from real rows:
///  - time_* series: per minute / per reading, stamped with LOCAL wall-clock time written as if UTC.
///  - daily series: the local date at T00:00:00Z (hr avg/min/max at T00:00:01Z).
///  - ints carry the `i` suffix (Influx rejects a field type change); battery2 is the string band.
/// calories2 is NOT written: the watch's figure is active calories, the cloud's was total calories.
final class InfluxPusher {
    private var busy = false

    /// Both watches are summed, as the Withings cloud did: per minute, per day. Heart rate from either watch.
    func push(_ watches: [(service: WatchService, entity: String)], done: @escaping (String) -> Void) {
        guard !busy, let cfg = RemoteConfig.load() else {
            if RemoteConfig.load() == nil { done("Influx: no config yet") }
            return
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let fromMs = max(Settings.influxWatermarkMs, nowMs - 14 * 86_400_000)
        var lines: [String] = []

        // Per-minute activity (increments per minute), summed across watches.
        let metrics: [(Metric, String, String)] = [
            (.steps, "time_steps", "withings_time_steps"),
            (.distance, "time_distance", "withings_time_distance"),
            (.ascent, "time_elevation", "withings_time_elevation"),
            (.calories, "time_calories", "withings_time_caloires"),
        ]
        for (metric, measurement, id) in metrics {
            var minutes: [Int64: Double] = [:]
            for w in watches {
                let points = (try? w.service.series(metric: metric, fromMs: fromMs, toMs: nowMs, maxPoints: 100_000)) ?? []
                for p in points { minutes[Self.localStamp(p.atMs) / 60 * 60, default: 0] += p.value }
            }
            for (t, v) in minutes where v > 0 || metric == .steps {
                lines.append("\(measurement),domain=sensor,entity_id=\(id) value=\(Int(v))i \(t)")
            }
        }

        // Heart rate per reading.
        for w in watches {
            for p in ((try? w.service.hrSeries(fromMs: fromMs, toMs: nowMs, maxPoints: 100_000)) ?? []) where p.bpm > 0 {
                lines.append("time_hr,domain=sensor,entity_id=withings_time_hr value=\(p.bpm)i \(Self.localStamp(p.atMs))")
            }
        }

        // Daily rows for each local day touched by the window.
        let cal = Calendar.current
        var day = cal.startOfDay(for: Date(timeIntervalSince1970: Double(fromMs) / 1000))
        while day <= Date() {
            let next = cal.date(byAdding: .day, value: 1, to: day)!
            let s = Int64(day.timeIntervalSince1970 * 1000), e = Int64(next.timeIntervalSince1970 * 1000)
            let stamp = Self.dayStamp(day)
            var steps: Int64 = 0, metres = 0.0, ascent = 0.0, kcal = 0.0
            var effort: [Int64] = [0, 0, 0]
            var dayHr: [Int] = []
            for w in watches {
                if let t = try? w.service.activityTotals(fromMs: s, toMs: e) {
                    steps += t.steps; metres += t.distanceMetres; ascent += t.ascentMetres; kcal += t.calories
                }
                // Soft / moderate / intense from the watch's per-minute MET (light 1.5-3, moderate 3-6, vigorous 6+).
                if let i = try? w.service.intensitySeconds(fromMs: s, toMs: e, softMet: 1.5, moderateMet: 3, intenseMet: 6) {
                    for k in 0..<3 { effort[k] += i[k] }
                }
                dayHr += ((try? w.service.hrSeries(fromMs: s, toMs: e, maxPoints: 100_000)) ?? []).map { Int($0.bpm) }.filter { $0 > 0 }
            }
            if steps > 0 {
                lines.append("steps2,domain=sensor,entity_id=withings_steps value=\(steps)i \(stamp)")
                lines.append("distance2,domain=sensor,entity_id=withings_distance value=\(Int(metres))i \(stamp)")
                lines.append("elevation,domain=sensor,entity_id=withings_elevation value=\(Int(ascent))i \(stamp)")
                if let bmr = cfg.bmr_kcal {
                    lines.append("calories2,domain=sensor,entity_id=withings_calories value=\(Int(kcal + bmr))i \(stamp)")
                }
            }
            if effort.reduce(0, +) > 0 {
                lines.append("soft,domain=sensor,entity_id=withings_soft value=\(effort[0])i \(stamp)")
                lines.append("moderate,domain=sensor,entity_id=withings_moderate value=\(effort[1])i \(stamp)")
                lines.append("intense2,domain=sensor,entity_id=withings_intense value=\(effort[2])i \(stamp)")
                lines.append("active2,domain=sensor,entity_id=withings_active value=\(effort[1] + effort[2])i \(stamp)")
            }
            if !dayHr.isEmpty {
                let avg = dayHr.reduce(0, +) / dayHr.count
                lines.append("hr,domain=sensor,entity_id=withings_hr_avg value=\(avg)i \(stamp + 1)")
                lines.append("hr,domain=sensor,entity_id=withings_hr_max value=\(dayHr.max()!)i \(stamp + 1)")
                lines.append("hr,domain=sensor,entity_id=withings_hr_min value=\(dayHr.min()!)i \(stamp + 1)")
            }
            day = next
        }

        // Workouts (manual + auto-detected), one row set per session on the day it began, like the cloud collector.
        for w in watches {
            let model = w.entity == "steelhr" ? "55" : "93"
            for wk in ((try? w.service.workoutsBetween(fromMs: fromMs, toMs: nowMs)) ?? []) {
                guard let end = wk.endedAtMs else { continue }
                let name = wk.activity.lowercased()
                let category = name.contains("walk") ? "walking" : name.contains("run") ? "running"
                    : (name.contains("cycl") || name.contains("bik")) ? "cycling" : "other"
                let stamp = Self.dayStamp(Date(timeIntervalSince1970: Double(wk.startedAtMs) / 1000)) + 1
                let tags = "category=\(category),domain=sensor,entity_id=withings_workout_%@,model=\(model)"
                let t = try? w.service.activityTotals(fromMs: wk.startedAtMs, toMs: end)
                lines.append("workout_steps," + String(format: tags, "steps") + " value=\(t?.steps ?? 0)i \(stamp)")
                lines.append("workout_distance," + String(format: tags, "distance") + " value=\(t?.distanceMetres ?? 0) \(stamp)")
                if let c = wk.calories {
                    lines.append("workout_calories," + String(format: tags, "calories") + " value=\(Int(c))i \(stamp)")
                }
            }
        }

        // Battery per watch: the old 3-level band (HA sensors read it) + the real percentage in a new series.
        for w in watches {
            guard let b = (try? w.service.snapshot())?.battery else { continue }
            let band = b.percent <= 20 ? "low" : (b.percent <= 60 ? "medium" : "high")
            lines.append("battery2,domain=sensor,entity_id=\(w.entity) value=\"\(band)\" \(Self.dayStamp(Date()))")
            lines.append("watch_battery_pct,domain=sensor,entity_id=\(w.entity) value=\(b.percent)i \(b.atMs / 1000)")
        }

        guard !lines.isEmpty else { done("Influx: nothing new"); return }
        var comps = URLComponents(string: cfg.influx_url + "/api/v2/write")!
        comps.queryItems = [.init(name: "org", value: cfg.influx_org), .init(name: "bucket", value: cfg.influx_bucket),
                            .init(name: "precision", value: "s")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("Token \(cfg.influx_token)", forHTTPHeaderField: "Authorization")
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = lines.joined(separator: "\n").data(using: .utf8)
        req.timeoutInterval = 20
        busy = true
        URLSession.shared.dataTask(with: req) { _, resp, err in
            self.busy = false
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 204 {
                // Keep a 2 h overlap: rewriting identical points is harmless and catches late uploads.
                Settings.influxWatermarkMs = nowMs - 2 * 3_600_000
                done("Influx: \(lines.count) points at \(Self.clock.string(from: Date()))")
            } else {
                done("Influx: failed (\(code == 0 ? err?.localizedDescription ?? "offline" : "HTTP \(code)"))")
            }
        }.resume()
    }

    /// Local wall-clock seconds written as if they were UTC (the collectors' convention).
    static func localStamp(_ ms: Int64) -> Int64 {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        return ms / 1000 + Int64(TimeZone.current.secondsFromGMT(for: date))
    }

    /// The local calendar date at 00:00:00 UTC.
    static func dayStamp(_ date: Date) -> Int64 {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return Int64(utc.date(from: c)!.timeIntervalSince1970)
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
}
