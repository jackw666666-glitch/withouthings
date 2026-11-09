import CoreBluetooth
import Foundation

/// The Withings alert service, hosted from the phone (port of withouthings' AncsServer.kt).
/// The watch subscribes, gets an announcement per alert, and asks for the text over the control point.
final class AncsHost: NSObject, CBPeripheralManagerDelegate {
    private let queue: DispatchQueue
    private var manager: CBPeripheralManager!
    private let service: CBMutableService
    private let source: CBMutableCharacteristic
    private let control: CBMutableCharacteristic
    private let data: CBMutableCharacteristic
    private var added = false
    private var subscribers: [UUID: CBCentral] = [:]
    private var requester: CBCentral?
    private var pending: [(CBMutableCharacteristic, Data, [CBCentral]?)] = []

    var onControlWrite: ((Data, Int) -> Void)?
    var listeners: Int { subscribers.count }

    init(queue: DispatchQueue) {
        self.queue = queue
        let ids = ancsUuids()
        source = CBMutableCharacteristic(type: CBUUID(string: ids.notificationSource), properties: .notify, value: nil, permissions: .readable)
        control = CBMutableCharacteristic(type: CBUUID(string: ids.controlPoint), properties: .write, value: nil, permissions: .writeable)
        data = CBMutableCharacteristic(type: CBUUID(string: ids.dataSource), properties: .notify, value: nil, permissions: .readable)
        service = CBMutableService(type: CBUUID(string: ids.service), primary: true)
        service.characteristics = [source, control, data]
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: queue, options: [CBPeripheralManagerOptionRestoreIdentifierKey: "wrist.ancs"])
    }

    /// Set around a post to reach one watch only; nil, or a watch not listening, reaches every watch listening.
    var announceTo: UUID?
    func isListening(_ id: UUID) -> Bool { subscribers[id] != nil }
    func announce(_ bytes: Data) { send(source, bytes, announceTo.flatMap { subscribers[$0] }.map { [$0] }) }
    func attributes(_ bytes: Data) { send(data, bytes, requester.map { [$0] }) }

    private func send(_ c: CBMutableCharacteristic, _ bytes: Data, _ to: [CBCentral]?) {
        queue.async {
            self.pending.append((c, bytes, to))
            self.drain()
        }
    }

    private func drain() {
        while let (c, bytes, to) = pending.first {
            guard manager.updateValue(bytes, for: c, onSubscribedCentrals: to) else { return }   // resumes when ready
            pending.removeFirst()
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { drain() }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        AppLog.log("alerts: peripheral state \(peripheral.state.rawValue)")
        guard peripheral.state == .poweredOn, !added else { return }
        added = true
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        // iOS kept our service across a relaunch; add() again would duplicate it.
        let restored = (dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService]) ?? []
        if !restored.isEmpty { added = true; peripheral.removeAllServices(); added = false }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        AppLog.log("alerts: service \(error.map { "failed: \($0)" } ?? "ready")")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        if characteristic.uuid == source.uuid { subscribers[central.identifier] = central }
        AppLog.log("alerts: watch \(central.identifier.uuidString.prefix(8)) subscribed to \(characteristic.uuid.uuidString.prefix(8))")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        if characteristic.uuid == source.uuid { subscribers[central.identifier] = nil }
        AppLog.log("alerts: watch \(central.identifier.uuidString.prefix(8)) left")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests where r.characteristic.uuid == control.uuid {
            guard let value = r.value else { continue }
            requester = r.central
            onControlWrite?(value, r.central.maximumUpdateValueLength)
        }
        if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
    }
}
