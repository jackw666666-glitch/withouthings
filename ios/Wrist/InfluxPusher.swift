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

        // Per-minute activity, from the watch's activity minutes, summed across watches.
        // Not series(.steps): that is the watch's running daily counter.
        var perMinute: [Int64: (steps: Int64, metres: Double, ascent: Double, kcal: Double)] = [:]
        for w in watches {
            for m in ((try? w.service.activityWindows(fromMs: fromMs, toMs: nowMs)) ?? []) where m.durationSecs <= 60 {
                let t = Self.localStamp(m.atMs) / 60 * 60
                var row = perMinute[t] ?? (0, 0, 0, 0)
                row.steps += m.steps; row.metres += m.distanceMetres; row.ascent += m.ascentMetres; row.kcal += m.calories
                perMinute[t] = row
            }
        }
        for (t, r) in perMinute {
            if r.steps > 0 { lines.append("time_steps,domain=sensor,entity_id=withings_time_steps value=\(r.steps)i \(t)") }
            if r.metres > 0 { lines.append("time_distance,domain=sensor,entity_id=withings_time_distance value=\(Int(r.metres))i \(t)") }
            if r.ascent > 0 { lines.append("time_elevation,domain=sensor,entity_id=withings_time_elevation value=\(Int(r.ascent))i \(t)") }
            if r.kcal > 0 { lines.append("time_calories,domain=sensor,entity_id=withings_time_caloires value=\(Int(r.kcal))i \(t)") }
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
            var dayHr: [(Int64, Int)] = []
            var tracked: Int64 = 0
            for w in watches {
                if let t = try? w.service.activityTotals(fromMs: s, toMs: e) {
                    steps += t.steps; metres += t.distanceMetres; ascent += t.ascentMetres; kcal += t.calories
                }
                // Rules fitted to five years of the cloud's own numbers (28% off on active minutes, checked on 2022):
                // intense = non-walk workouts; moderate = other minutes of 76+ steps; soft = the rest of the tracked minutes.
                let bursts = UserDefaults.standard.array(forKey: "burstStarts") as? [Double] ?? []
                let hard = ((try? w.service.workoutsBetween(fromMs: s, toMs: e)) ?? []).compactMap { wk -> (Int64, Int64)? in
                    guard let end = wk.endedAtMs, !wk.activity.lowercased().contains("walk"),
                          !bursts.contains(where: { abs($0 * 1000 - Double(wk.startedAtMs)) < 120_000 }) else { return nil }
                    return (wk.startedAtMs, end)
                }
                effort[2] += hard.reduce(0) { $0 + ($1.1 - $1.0) / 1000 }
                for m in ((try? w.service.activityWindows(fromMs: s, toMs: e)) ?? []) where m.durationSecs <= 60 {
                    tracked += m.durationSecs
                    if m.steps >= 76, !hard.contains(where: { m.atMs >= $0.0 && m.atMs < $0.1 }) { effort[1] += m.durationSecs }
                }
                dayHr += ((try? w.service.hrSeries(fromMs: s, toMs: e, maxPoints: 100_000)) ?? []).filter { $0.bpm > 0 }.map { (Int64($0.atMs / 1000), Int($0.bpm)) }
            }
            dayHr.sort { $0.0 < $1.0 }
            effort[0] = max(0, tracked - effort[1] - effort[2])
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
                let shape = Self.heartShape(dayHr)
                let rates = dayHr.map(\.1)
                lines.append("hr,domain=sensor,entity_id=withings_hr_avg value=\(shape.average)i \(stamp + 1)")
                lines.append("hr,domain=sensor,entity_id=withings_hr_max value=\(rates.max()!)i \(stamp + 1)")
                lines.append("hr,domain=sensor,entity_id=withings_hr_min value=\(rates.min()!)i \(stamp + 1)")
                for (zone, seconds) in shape.zones.enumerated() {
                    lines.append("hr_zone_\(zone),domain=sensor,entity_id=withings_hr_zone_\(zone) value=\(seconds)i \(stamp)")
                }
            }
            day = next
        }

        // Workouts (manual + auto-detected), one row set per session on the day it began, like the cloud collector.
        for w in watches {
            let model = w.entity == "steelhr" ? "55" : "93"
            for wk in ((try? w.service.workoutsBetween(fromMs: fromMs, toMs: nowMs)) ?? []) {
                guard let end = wk.endedAtMs else { continue }
                let bursts = UserDefaults.standard.array(forKey: "burstStarts") as? [Double] ?? []
                if bursts.contains(where: { abs($0 * 1000 - Double(wk.startedAtMs)) < 120_000 }) { continue }   // heart-rate bursts aren't workouts
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

        // Health readings the watch takes on its own (real UTC times; new series, nothing reads the old cloud ones).
        for w in watches {
            let e = w.entity
            for (metric, name) in [(Metric.spo2, "watch_spo2"), (.hrvRmssd, "watch_hrv_rmssd"), (.respiratoryRate, "watch_resp_rate")] {
                for p in ((try? w.service.series(metric: metric, fromMs: fromMs, toMs: nowMs, maxPoints: 100_000)) ?? []) {
                    lines.append("\(name),domain=sensor,entity_id=\(e) value=\(p.value) \(p.atMs / 1000)")
                }
            }
            for a in ((try? w.service.afibEpisodes()) ?? []) where a.measuredAtMs >= fromMs {
                let rhythm = a.rhythm.map { "\($0)" } ?? "unknown"
                let isAfib = a.rhythm == .afib ? 1 : 0
                lines.append("watch_afib,domain=sensor,entity_id=\(e),rhythm=\(rhythm) value=\(isAfib)i,alerted=\(a.alerted == true) \(a.measuredAtMs / 1000)")
            }
            for g in ((try? w.service.ecgs()) ?? []) where g.measuredAtMs >= fromMs {
                let rhythm = g.rhythm.map { "\($0)" } ?? "none"
                lines.append("watch_ecg,domain=sensor,entity_id=\(e),rhythm=\(rhythm) heart_rate=\(g.heartRate ?? 0)i \(g.measuredAtMs / 1000)")
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

    /// How the cloud turned readings into a day (fitted on its own history): heart rate is interpolated
    /// second by second between readings up to 31 minutes apart; zones start at 95, 133 and 171 bpm.
    static func heartShape(_ samples: [(Int64, Int)]) -> (zones: [Int64], average: Int) {
        var zones: [Int64] = [0, 0, 0, 0]
        var sum = 0.0, seconds = 0.0
        func add(_ bpm: Double, _ n: Int64) {
            zones[bpm >= 171 ? 3 : bpm >= 133 ? 2 : bpm >= 95 ? 1 : 0] += n
            sum += bpm * Double(n); seconds += Double(n)
        }
        for (i, (t, h)) in samples.enumerated() {
            if i + 1 < samples.count, samples[i + 1].0 - t <= 1860, samples[i + 1].0 > t {
                let gap = samples[i + 1].0 - t, next = samples[i + 1].1
                for u in 0..<gap { add(Double(h) + Double(next - h) * Double(u) / Double(gap), 1) }
            } else {
                add(Double(h), 60)     // an isolated reading stands for about a minute
            }
        }
        return (zones, seconds > 0 ? Int(sum / seconds) : 0)
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
