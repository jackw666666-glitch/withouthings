import CoreBluetooth
import Foundation

protocol WatchLinkDelegate: AnyObject {
    /// Channel found and notifications on: the protocol can start.
    func linkReady(_ id: UUID)
    func linkBytes(_ id: UUID, _ bytes: Data)
    func linkDisconnected(_ id: UUID)
    func linkDiscovered(_ id: UUID, name: String, rssi: Int)
}

/// CoreBluetooth port of withouthings' GattLink.kt, holding any number of watches at once.
/// - The protocol channel is a characteristic under a service whose UUID contains 5749-5448 ("WITH");
///   ScanWatch 2 marks it ...494E4753 ("INGS"), ScanWatch 1 uses ...-5749-5448-005d-..., Steel HR ...-5749-5448-0037-...
/// - The ScanWatch 1 refuses the CCCD write until link encryption is up, so subscribing waits 2 s and retries.
/// - Writes are one at a time per watch, chunked to the link's write size.
/// - iOS keeps a pending connect alive forever, including in the background, so after a drop we just connect again.
/// Everything runs on `queue`; callers may call in from any thread.
final class WatchLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let queue = DispatchQueue(label: "wrist.ble")
    weak var delegate: WatchLinkDelegate?

    private final class Session {
        let peripheral: CBPeripheral
        var channel: CBCharacteristic?
        var notifying = false
        var ready = false
        var inFlight = false
        var pending: [Data] = []
        var subscribeAttempts = 0
        var autoReconnect = true
        var state = "Connecting"
        init(_ p: CBPeripheral) { peripheral = p }
    }

    private var central: CBCentralManager!
    private var sessions: [UUID: Session] = [:]
    private var wanted: Set<UUID> = []
    private var scanning = false
    private var discovered: [UUID: CBPeripheral] = [:]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "wrist.central",
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
    }

    /// Call on `queue`.
    func state(_ id: UUID) -> String { sessions[id]?.state ?? (central.state == .poweredOn ? "Waiting for watch" : "Bluetooth off") }

    // MARK: public (any thread)

    func startScan() {
        queue.async {
            self.scanning = true
            self.discovered.removeAll()
            guard self.central.state == .poweredOn else { return }
            // A watch already connected to iOS (bonded) may not advertise: list those too.
            for p in self.central.retrieveConnectedPeripherals(withServices: Self.knownServices) {
                self.discovered[p.identifier] = p
                self.delegate?.linkDiscovered(p.identifier, name: p.name ?? "Watch", rssi: 0)
            }
            self.central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            AppLog.log("ble: scanning")
        }
    }

    func stopScan() {
        queue.async {
            self.scanning = false
            if self.central.state == .poweredOn { self.central.stopScan() }
        }
    }

    /// Connect to a discovered watch (pairing) or a remembered one, and keep reconnecting.
    func connect(_ id: UUID) {
        queue.async {
            self.wanted.insert(id)
            guard self.central.state == .poweredOn else { return }
            if let s = self.sessions[id], s.ready { return }      // already linked
            let p = self.sessions[id]?.peripheral ?? self.discovered[id] ?? self.central.retrievePeripherals(withIdentifiers: [id]).first
            guard let p else { AppLog.log("ble: \(id) not found"); return }
            self.open(p)
        }
    }

    func write(_ id: UUID, _ frames: [Data]) {
        queue.async {
            guard let s = self.sessions[id] else { return }
            let type: CBCharacteristicWriteType = (s.channel?.properties.contains(.write) ?? true) ? .withResponse : .withoutResponse
            let limit = max(1, s.peripheral.maximumWriteValueLength(for: type))
            for frame in frames {
                var offset = 0
                while offset < frame.count {
                    let end = min(offset + limit, frame.count)
                    s.pending.append(frame.subdata(in: offset..<end))
                    offset = end
                }
            }
            self.pump(s)
        }
    }

    /// Drop a link; it reconnects by itself unless `stay` is false (then the watch is let go).
    func drop(_ id: UUID, stay: Bool = true) {
        queue.async {
            if !stay { self.wanted.remove(id) }
            guard let s = self.sessions[id] else { return }
            s.autoReconnect = stay
            self.central.cancelPeripheralConnection(s.peripheral)
            if !stay { self.sessions[id] = nil }
        }
    }

    // MARK: central

    static let knownServices: [CBUUID] = [
        CBUUID(string: "00000020-5749-5448-0037-000000000000"),
        CBUUID(string: "00000050-5749-5448-0037-000000000000"),
        CBUUID(string: "00000020-5749-5448-005D-000000000000"),
    ]

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        AppLog.log("ble: central state \(central.state.rawValue)")
        guard central.state == .poweredOn else { return }
        if scanning { startScan() }
        for id in wanted {
            if let s = sessions[id] {
                // A session iOS restored may already be connected with no channel yet: rediscover it,
                // otherwise the link sits "connected" and never syncs.
                if s.peripheral.state == .connected {
                    if !s.ready { s.peripheral.delegate = self; s.peripheral.discoverServices(nil) }
                } else {
                    central.connect(s.peripheral, options: nil)
                }
            } else if let p = central.retrievePeripherals(withIdentifiers: [id]).first {
                open(p)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Relaunched in the background by iOS for our watches.
        for p in (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? [] {
            let s = Session(p)
            sessions[p.identifier] = s
            p.delegate = self
            AppLog.log("ble: restored \(p.name ?? p.identifier.uuidString)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard Self.looksLikeWatch(name) else { return }
        discovered[p.identifier] = p
        delegate?.linkDiscovered(p.identifier, name: name, rssi: rssi.intValue)
    }

    static func looksLikeWatch(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix("scanwatch") || n.hasPrefix("steel") || n.hasPrefix("withings") || n.hasPrefix("hwa") || n.hasPrefix("activit")
    }

    private func open(_ p: CBPeripheral) {
        let s = sessions[p.identifier] ?? Session(p)
        reset(s)
        s.autoReconnect = true
        sessions[p.identifier] = s
        p.delegate = self
        set(s, "Connecting")
        if p.state == .connected {
            p.discoverServices(nil)
        } else {
            central.connect(p, options: nil)
        }
    }

    private func set(_ s: Session, _ state: String) {
        if s.state != state { AppLog.log("ble \(s.peripheral.name ?? "?"): \(state)") }
        s.state = state
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard let s = sessions[p.identifier] else { return }
        set(s, "Connected")
        p.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard let s = sessions[p.identifier] else { return }
        set(s, "Retrying")
        queue.asyncAfter(deadline: .now() + 5) { if s.autoReconnect { central.connect(p, options: nil) } }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard let s = sessions[p.identifier] else { return }
        reset(s)
        set(s, s.autoReconnect ? "Waiting for watch" : "Disconnected")
        delegate?.linkDisconnected(p.identifier)
        if s.autoReconnect { central.connect(p, options: nil) }
    }

    private func reset(_ s: Session) {
        s.channel = nil
        s.notifying = false
        s.ready = false
        s.inFlight = false
        s.pending.removeAll()
        s.subscribeAttempts = 0
    }

    // MARK: peripheral

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { central.cancelPeripheralConnection(p); return }
        let ours = (p.services ?? []).filter { $0.uuid.uuidString.uppercased().contains("5749-5448") }
        if ours.isEmpty, let s = sessions[p.identifier] { set(s, "No Withings service"); return }
        ours.forEach { p.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let s = sessions[p.identifier], s.channel == nil,
              let found = (service.characteristics ?? []).first(where: Self.isProtocolChannel) else { return }
        s.channel = found
        s.subscribeAttempts = 0
        // SW1: wait for encryption to settle before the CCCD write.
        queue.asyncAfter(deadline: .now() + 2) { self.subscribe(s) }
    }

    static func isProtocolChannel(_ c: CBCharacteristic) -> Bool {
        let id = c.uuid.uuidString.uppercased()
        guard id.count >= 8, Array(id)[7] == "4" else { return false }
        guard id.contains("494E4753") || id.contains("5749-5448-005D") || id.contains("5749-5448-0037") else { return false }
        return c.properties.contains(.notify) || c.properties.contains(.indicate)
    }

    private func subscribe(_ s: Session) {
        guard let c = s.channel, s.peripheral.state == .connected else { return }
        s.subscribeAttempts += 1
        s.peripheral.setNotifyValue(true, for: c)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard let s = sessions[p.identifier], c == s.channel else { return }
        if let error {
            // Insufficient authentication/encryption: iOS pairs and we try again.
            if s.subscribeAttempts < 5 {
                set(s, "Securing link (\(s.subscribeAttempts))")
                queue.asyncAfter(deadline: .now() + 1.5) { self.subscribe(s) }
            } else {
                set(s, "Subscribe failed: \(error.localizedDescription)")
                central.cancelPeripheralConnection(p)
            }
            return
        }
        s.notifying = c.isNotifying
        guard s.notifying, !s.ready else { return }
        s.ready = true
        set(s, "Linked")
        delegate?.linkReady(p.identifier)
        pump(s)
    }

    func peripheral(_ p: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        // SW1 sends Service Changed right after connecting: handles may have moved.
        guard let s = sessions[p.identifier] else { return }
        reset(s)
        p.discoverServices(nil)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let s = sessions[p.identifier], c == s.channel, error == nil, let value = c.value else { return }
        delegate?.linkBytes(p.identifier, value)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard let s = sessions[p.identifier] else { return }
        s.inFlight = false
        pump(s)
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        guard let s = sessions[p.identifier] else { return }
        s.inFlight = false
        pump(s)
    }

    private func pump(_ s: Session) {
        guard !s.inFlight, s.notifying, let c = s.channel, !s.pending.isEmpty else { return }
        let next = s.pending.removeFirst()
        if c.properties.contains(.write) {
            s.peripheral.writeValue(next, for: c, type: .withResponse)
            s.inFlight = true
        } else {
            guard s.peripheral.canSendWriteWithoutResponse else { s.pending.insert(next, at: 0); s.inFlight = true; return }
            s.peripheral.writeValue(next, for: c, type: .withoutResponse)
            queue.async { self.pump(s) }
        }
    }
}
