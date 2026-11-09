import CoreLocation
import Foundation

/// Keeps Wrist running in the background: iOS doesn't suspend an app that is receiving location
/// updates. Coarse accuracy (cell / Wi-Fi) normally; real GPS only while a workout records a route.
final class KeepAlive: NSObject, CLLocationManagerDelegate {
    static let shared = KeepAlive()
    private let manager = CLLocationManager()
    private var tracking = false
    /// Each fix while a workout is recording a route. Coarse the rest of the time.
    var onFix: ((CLLocation) -> Void)?

    /// Real GPS during a workout, coarse otherwise. Call from any thread.
    func setTracking(_ on: Bool) {
        DispatchQueue.main.async {
            guard on != self.tracking else { return }
            self.tracking = on
            self.manager.desiredAccuracy = on ? kCLLocationAccuracyBest : kCLLocationAccuracyThreeKilometers
            AppLog.log("keep-alive: route tracking \(on ? "on" : "off")")
        }
    }

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization(); manager.startUpdatingLocation()
        case .authorizedAlways: manager.startUpdatingLocation()
        default: AppLog.log("keep-alive: location not allowed")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        AppLog.log("keep-alive: location permission \(manager.authorizationStatus.rawValue)")
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard tracking else { return }
        locations.forEach { onFix?($0) }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        AppLog.log("keep-alive: location error \(error.localizedDescription)")
    }
}

/// Every minute while running, fetch the NUC's command file (commands_url in config.json) and save it as
/// Documents/remote.json, which RemoteConfig merges in. Commands then reach the watch within a minute.
final class CommandPoller {
    static let shared = CommandPoller()
    private var timer: Timer?
    private var last = ""

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func poll() {
        guard let s = RemoteConfig.loadBase()?.commands_url, let url = URL(string: s) else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                  (try? JSONSerialization.jsonObject(with: data)) != nil else { return }
            let text = String(decoding: data, as: UTF8.self)
            guard text != self.last else { return }
            self.last = text
            try? data.write(to: Settings.documents.appendingPathComponent("remote.json"))
            AppLog.log("commands updated from NUC (\(data.count) bytes)")
        }.resume()
    }
}
