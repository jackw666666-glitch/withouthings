import CoreBluetooth
import Foundation

protocol WatchLinkDelegate: AnyObject {
    /// Channel found and notifications on: the protocol can start.
    func linkReady()
    func linkBytes(_ bytes: Data)
    func linkDisconnected()
    func linkDiscovered(_ id: UUID, name: String, rssi: Int)
}

/// CoreBluetooth port of withouthings' GattLink.kt.
/// - The protocol channel is a characteristic under a service whose UUID contains 5749-5448 ("WITH");
///   ScanWatch 2 marks it ...494E4753 ("INGS"), the original ScanWatch uses 00000024-5749-5448-005d-...
/// - The ScanWatch 1 refuses the CCCD write until link encryption is up, so subscribing waits 2 s and retries.
/// - Writes are one at a time, chunked to the link's write size.
/// - iOS keeps a pending connect alive forever, including in the background, so after a drop we just connect again.
/// Everything runs on `queue`; callers may call in from any thread.
final class WatchLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let queue = DispatchQueue(label: "wrist.ble")
    weak var delegate: WatchLinkDelegate?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var channel: CBCharacteristic?
    private var notifying = false
    private var ready = false
    private var inFlight = false
    private var pending: [Data] = []
    private var subscribeAttempts = 0
    private var scanning = false
    private var autoReconnect = true
    private var discovered: [UUID: CBPeripheral] = [:]

    private(set) var state = "Starting" { didSet { if state != oldValue { AppLog.log("ble: \(state)") } } }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "wrist.central",
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
    }

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
            self.state = "Scanning"
        }
    }

    func stopScan() {
        queue.async {
            self.scanning = false
            if self.central.state == .poweredOn { self.central.stopScan() }
        }
    }

    /// Connect to a discovered watch (pairing) or the remembered one.
    func connect(_ id: UUID) {
        queue.async {
            self.autoReconnect = true
            let p = self.discovered[id] ?? self.central.retrievePeripherals(withIdentifiers: [id]).first
            guard let p else { self.state = "Watch not found"; return }
            self.open(p)
        }
    }

    func write(_ frames: [Data]) {
        queue.async {
            guard let p = self.peripheral else { return }
            let type: CBCharacteristicWriteType = (self.channel?.properties.contains(.write) ?? true) ? .withResponse : .withoutResponse
            let limit = max(1, p.maximumWriteValueLength(for: type))
            for frame in frames {
                var offset = 0
                while offset < frame.count {
                    let end = min(offset + limit, frame.count)
                    self.pending.append(frame.subdata(in: offset..<end))
                    offset = end
                }
            }
            self.pump()
        }
    }

    /// Drop the link; it reconnects by itself unless `stay` is false.
    func drop(stay: Bool = true) {
        queue.async {
            self.autoReconnect = stay
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
        }
    }

    // MARK: central

    static let knownServices: [CBUUID] = [
        CBUUID(string: "00000020-5749-5448-0037-000000000000"),
        CBUUID(string: "00000050-5749-5448-0037-000000000000"),
        CBUUID(string: "00000020-5749-5448-005D-000000000000"),
    ]

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if scanning { startScan() }
            if peripheral == nil, let id = Settings.peripheralId,
               let p = central.retrievePeripherals(withIdentifiers: [id]).first {
                open(p)
            } else if let p = peripheral, p.state != .connected {
                central.connect(p, options: nil)
            }
        case .poweredOff: state = "Bluetooth off"
        case .unauthorized: state = "Bluetooth not allowed"
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Relaunched in the background by iOS for our watch.
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let p = restored.first(where: { $0.identifier == Settings.peripheralId }) ?? restored.first {
            peripheral = p
            p.delegate = self
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
        return n.hasPrefix("scanwatch") || n.hasPrefix("steel hr") || n.hasPrefix("withings") || n.hasPrefix("hwa")
    }

    private func open(_ p: CBPeripheral) {
        if let old = peripheral, old.identifier != p.identifier { central.cancelPeripheralConnection(old) }
        resetChannel()
        peripheral = p
        p.delegate = self
        state = "Connecting"
        if p.state == .connected {
            p.discoverServices(nil)
        } else {
            central.connect(p, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p == peripheral else { return }
        state = "Connected"
        p.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p == peripheral else { return }
        state = "Retrying"
        queue.asyncAfter(deadline: .now() + 5) { if self.autoReconnect { central.connect(p, options: nil) } }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p == peripheral else { return }
        resetChannel()
        state = autoReconnect ? "Waiting for watch" : "Disconnected"
        delegate?.linkDisconnected()
        if autoReconnect { central.connect(p, options: nil) }
    }

    private func resetChannel() {
        channel = nil
        notifying = false
        ready = false
        inFlight = false
        pending.removeAll()
        subscribeAttempts = 0
    }

    // MARK: peripheral

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { central.cancelPeripheralConnection(p); return }
        let ours = (p.services ?? []).filter { $0.uuid.uuidString.uppercased().contains("5749-5448") }
        if ours.isEmpty { state = "No Withings service"; return }
        ours.forEach { p.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard channel == nil, let found = (service.characteristics ?? []).first(where: Self.isProtocolChannel) else { return }
        channel = found
        subscribeAttempts = 0
        // SW1: wait for encryption to settle before the CCCD write.
        queue.asyncAfter(deadline: .now() + 2) { self.subscribe() }
    }

    static func isProtocolChannel(_ c: CBCharacteristic) -> Bool {
        let id = c.uuid.uuidString.uppercased()
        guard id.count >= 8, Array(id)[7] == "4" else { return false }
        guard id.contains("494E4753") || id.contains("5749-5448-005D") || id.contains("5749-5448-0037") else { return false }
        return c.properties.contains(.notify) || c.properties.contains(.indicate)
    }

    private func subscribe() {
        guard let p = peripheral, let c = channel, p.state == .connected else { return }
        subscribeAttempts += 1
        p.setNotifyValue(true, for: c)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard c == channel else { return }
        if let error {
            // Insufficient authentication/encryption: iOS pairs and we try again.
            if subscribeAttempts < 5 {
                state = "Securing link (\(subscribeAttempts))"
                queue.asyncAfter(deadline: .now() + 1.5) { self.subscribe() }
            } else {
                state = "Subscribe failed: \(error.localizedDescription)"
                central.cancelPeripheralConnection(p)
            }
            return
        }
        notifying = c.isNotifying
        guard notifying, !ready else { return }
        ready = true
        state = "Linked"
        delegate?.linkReady()
        pump()
    }

    func peripheral(_ p: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        // SW1 sends Service Changed right after connecting: handles may have moved.
        resetChannel()
        p.discoverServices(nil)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard c == channel, error == nil, let value = c.value else { return }
        delegate?.linkBytes(value)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        inFlight = false
        pump()
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        inFlight = false
        pump()
    }

    private func pump() {
        guard !inFlight, notifying, let p = peripheral, let c = channel, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        if c.properties.contains(.write) {
            p.writeValue(next, for: c, type: .withResponse)
            inFlight = true
        } else {
            guard p.canSendWriteWithoutResponse else { pending.insert(next, at: 0); inFlight = true; return }
            p.writeValue(next, for: c, type: .withoutResponse)
            queue.async { self.pump() }
        }
    }
}
