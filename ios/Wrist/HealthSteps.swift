import Foundation
import HealthKit

/// Daily step totals from Apple Health (iPhone pedometer + anything else Health holds, merged by Health's own
/// source priority so the same steps are never counted twice). Written to Influx as `steps_phone` daily rows;
/// the NUC combines them with the watches (per day: the highest) for the Steel HR steps screen.
enum HealthSteps {
    private static let store = HKHealthStore()
    private static let lock = NSLock()
    private static var cache: [Int64: Int] = [:]

    /// Rows from the last refresh (one per local day, stamped like the other daily series).
    static func lines() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return cache.sorted { $0.key < $1.key }.map { "steps_phone,domain=sensor,entity_id=health_steps value=\($0.value)i \($0.key)" }
    }

    /// Re-reads the last 9 days in the background; the next Influx push carries the result.
    static func refresh() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let type = HKQuantityType(.stepCount)
        store.requestAuthorization(toShare: [], read: [type]) { ok, _ in
            guard ok else { return }
            let cal = Calendar.current
            let end = Date()
            let anchor = cal.startOfDay(for: end)
            let start = cal.date(byAdding: .day, value: -9, to: anchor)!
            let q = HKStatisticsCollectionQuery(quantityType: type,
                                                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end),
                                                options: .cumulativeSum, anchorDate: anchor,
                                                intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, results, _ in
                var out: [Int64: Int] = [:]
                results?.enumerateStatistics(from: start, to: end) { s, _ in
                    if let v = s.sumQuantity()?.doubleValue(for: .count()), v > 0 {
                        out[InfluxPusher.dayStamp(s.startDate)] = Int(v)
                    }
                }
                lock.lock(); cache = out; lock.unlock()
            }
            store.execute(q)
        }
    }
}
