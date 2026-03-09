import CoreBluetooth
import os

private let logger = Logger(subsystem: "com.gimbal.controller", category: "BLE")

/// Manages BLE scanning, connection, and characteristic I/O for DJI gimbal communication.
@MainActor
final class BLEConnectionManager: NSObject, ObservableObject {
    @Published private(set) var connectionState: BLEConnectionState = .disconnected
    @Published private(set) var discoveredDevices: [DiscoveredGimbal] = []
    @Published private(set) var negotiatedMTU: Int = 20
    @Published private(set) var allCharacteristics: [DiscoveredCharacteristic] = []

    /// Called when data arrives on any notify characteristic.
    var onDataReceived: ((Data) -> Void)?

    /// Called when a BLE event should be logged to the debug panel.
    var onLogMessage: ((String) -> Void)?

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var scanTimer: Timer?
    private var writeType: CBCharacteristicWriteType = .withResponse

    /// All discovered CBCharacteristic objects keyed by UUID string for alternative writes
    private var characteristicMap: [String: CBCharacteristic] = [:]

    /// Number of services pending characteristic discovery
    private var pendingServiceDiscoveries: Int = 0

    /// UserDefaults key for persisting the last-connected peripheral UUID
    private static let lastPeripheralKey = "BLE_LastConnectedPeripheralUUID"

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public API

    func startScan(timeout: TimeInterval = 10) {
        guard centralManager.state == .poweredOn else {
            connectionState = .error("Bluetooth not available")
            return
        }

        discoveredDevices.removeAll()
        connectionState = .scanning

        // 1. Retrieve peripherals already connected to the system (e.g. paired via another app)
        let alreadyConnected = centralManager.retrieveConnectedPeripherals(withServices: [BLEConstants.serviceUUID])
        for peripheral in alreadyConnected {
            addDiscoveredPeripheral(peripheral, rssi: 0)
        }

        // 2. Retrieve the last peripheral we connected to by saved UUID
        if let uuidString = UserDefaults.standard.string(forKey: Self.lastPeripheralKey),
           let uuid = UUID(uuidString: uuidString) {
            let known = centralManager.retrievePeripherals(withIdentifiers: [uuid])
            for peripheral in known {
                addDiscoveredPeripheral(peripheral, rssi: 0)
            }
        }

        // 3. Also scan for advertising peripherals
        centralManager.scanForPeripherals(
            withServices: [BLEConstants.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.stopScan()
            }
        }

        logger.info("Started scanning for DJI gimbals")
    }

    private func addDiscoveredPeripheral(_ peripheral: CBPeripheral, rssi: Int) {
        guard discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier }) == nil else {
            return // already in the list
        }
        let name = peripheral.name ?? "Unknown Gimbal"
        let gimbal = DiscoveredGimbal(
            id: peripheral.identifier,
            name: name,
            rssi: rssi,
            peripheral: peripheral
        )
        discoveredDevices.append(gimbal)
        logger.info("Retrieved known peripheral: \(name)")
    }

    func stopScan() {
        centralManager.stopScan()
        scanTimer?.invalidate()
        scanTimer = nil
        if case .scanning = connectionState {
            connectionState = .disconnected
        }
        logger.info("Stopped scanning")
    }

    func connect(to gimbal: DiscoveredGimbal) {
        stopScan()
        connectionState = .connecting
        connectedPeripheral = gimbal.peripheral
        gimbal.peripheral.delegate = self
        centralManager.connect(gimbal.peripheral, options: nil)
        logger.info("Connecting to \(gimbal.name)")
    }

    func disconnect() {
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        cleanup()
    }

    /// Sends data to the default write characteristic (FFF5), chunking by MTU if necessary.
    func send(_ data: Data) {
        guard let characteristic = writeCharacteristic,
              let peripheral = connectedPeripheral else {
            logger.warning("Cannot send: not connected")
            return
        }

        writeToCharacteristic(data, characteristic: characteristic, type: writeType, peripheral: peripheral)
    }

    /// Sends data to an alternative characteristic by UUID string.
    /// Returns true if the characteristic was found and write attempted.
    @discardableResult
    func sendToCharacteristic(_ data: Data, uuid: String, forceWriteType: CBCharacteristicWriteType? = nil) -> Bool {
        guard let characteristic = characteristicMap[uuid],
              let peripheral = connectedPeripheral else {
            logger.warning("Cannot send to \(uuid): characteristic not found or not connected")
            return false
        }

        let type = forceWriteType ?? (characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)
        writeToCharacteristic(data, characteristic: characteristic, type: type, peripheral: peripheral)
        return true
    }

    /// Toggle between .withResponse and .withoutResponse for the default write characteristic
    func toggleWriteType() {
        if writeType == .withResponse {
            writeType = .withoutResponse
        } else {
            writeType = .withResponse
        }
        let typeStr = writeType == .withoutResponse ? "withoutResponse" : "withResponse"
        onLogMessage?("Write type changed to: \(typeStr)")
        logger.info("Write type toggled to: \(typeStr)")
    }

    var currentWriteTypeDescription: String {
        writeType == .withoutResponse ? "Without Response" : "With Response"
    }

    // MARK: - Private

    private func writeToCharacteristic(_ data: Data, characteristic: CBCharacteristic, type: CBCharacteristicWriteType, peripheral: CBPeripheral) {
        // CRITICAL: The DJI gimbal firmware only handles BLE writes ≤ 20 bytes
        // at the application layer, even if BLE MTU negotiation allows more.
        // The web-bluetooth reference implementation hardcodes 20-byte chunks.
        // Commands ≤ 20 bytes (motor=15, battery=13) work fine as single writes,
        // but rotation (21 bytes) MUST be chunked into 20 + 1 byte writes.
        let chunkSize = 20

        if data.count <= chunkSize {
            peripheral.writeValue(data, for: characteristic, type: type)
        } else {
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                let chunk = data[offset..<end]
                peripheral.writeValue(Data(chunk), for: characteristic, type: type)
                offset = end
            }
        }
    }

    private func cleanup() {
        connectedPeripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        allCharacteristics.removeAll()
        characteristicMap.removeAll()
        connectionState = .disconnected
    }

    private func describeProperties(_ props: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if props.contains(.read) { parts.append("R") }
        if props.contains(.write) { parts.append("W") }
        if props.contains(.writeWithoutResponse) { parts.append("WnR") }
        if props.contains(.notify) { parts.append("N") }
        if props.contains(.indicate) { parts.append("I") }
        if props.contains(.broadcast) { parts.append("B") }
        return parts.joined(separator: ",")
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEConnectionManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                logger.info("Bluetooth powered on")
            case .poweredOff:
                connectionState = .error("Bluetooth is off")
            case .unauthorized:
                connectionState = .error("Bluetooth unauthorized")
            case .unsupported:
                connectionState = .error("Bluetooth unsupported")
            default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            let name = peripheral.name ?? "Unknown Gimbal"
            let rssi = RSSI.intValue

            if let index = discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier }) {
                discoveredDevices[index].rssi = rssi
            } else {
                let gimbal = DiscoveredGimbal(
                    id: peripheral.identifier,
                    name: name,
                    rssi: rssi,
                    peripheral: peripheral
                )
                discoveredDevices.append(gimbal)
                logger.info("Discovered: \(name) (RSSI: \(rssi))")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            // Persist this peripheral's UUID for future reconnection
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastPeripheralKey)

            connectionState = .discoveringServices
            // Discover ALL services, not just FFF0
            peripheral.discoverServices(nil)
            onLogMessage?("Connected — discovering ALL services...")
            logger.info("Connected to \(peripheral.name ?? "gimbal"), discovering all services")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            let msg = error?.localizedDescription ?? "Unknown error"
            connectionState = .error("Connection failed: \(msg)")
            cleanup()
            logger.error("Connection failed: \(msg)")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            if let error = error {
                logger.warning("Disconnected with error: \(error.localizedDescription)")
            } else {
                logger.info("Disconnected")
            }
            cleanup()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEConnectionManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error = error {
                connectionState = .error("Service discovery failed: \(error.localizedDescription)")
                return
            }

            guard let services = peripheral.services, !services.isEmpty else {
                connectionState = .error("No services found")
                return
            }

            onLogMessage?("Found \(services.count) services:")
            for service in services {
                onLogMessage?("  SVC: \(service.uuid)")
            }

            // Discover ALL characteristics for ALL services
            pendingServiceDiscoveries = services.count
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            if let error = error {
                onLogMessage?("Char discovery failed for \(service.uuid): \(error.localizedDescription)")
                pendingServiceDiscoveries -= 1
                checkDiscoveryComplete()
                return
            }

            let chars = service.characteristics ?? []
            onLogMessage?("  SVC \(service.uuid) → \(chars.count) chars:")

            for char in chars {
                let props = describeProperties(char.properties)
                let uuidStr = char.uuid.uuidString
                let svcStr = service.uuid.uuidString

                onLogMessage?("    CHR \(uuidStr) [\(props)]")

                // Store in map for alternative writes
                characteristicMap[uuidStr] = char

                // Build discoverable characteristic
                let dc = DiscoveredCharacteristic(
                    id: "\(svcStr)/\(uuidStr)",
                    serviceUUID: svcStr,
                    characteristicUUID: uuidStr,
                    properties: props,
                    isNotify: char.properties.contains(.notify) || char.properties.contains(.indicate),
                    isWrite: char.properties.contains(.write),
                    isWriteNoResponse: char.properties.contains(.writeWithoutResponse),
                    isRead: char.properties.contains(.read)
                )
                allCharacteristics.append(dc)

                // Set up FFF4 (notify) and FFF5 (write) as before
                if char.uuid == BLEConstants.notifyCharacteristicUUID {
                    notifyCharacteristic = char
                    peripheral.setNotifyValue(true, for: char)
                    onLogMessage?("    ✓ Subscribed to FFF4 notifications")
                    logger.info("Subscribed to notify characteristic FFF4")
                } else if char.uuid == BLEConstants.writeCharacteristicUUID {
                    writeCharacteristic = char
                    let charProps = char.properties
                    if charProps.contains(.writeWithoutResponse) {
                        writeType = .withoutResponse
                    } else {
                        writeType = .withResponse
                    }
                    negotiatedMTU = peripheral.maximumWriteValueLength(for: writeType)
                    let typeStr = writeType == .withoutResponse ? "noResp" : "withResp"
                    onLogMessage?("    ✓ FFF5 write target (type=\(typeStr), MTU=\(negotiatedMTU))")
                    logger.info("FFF5 writeType=\(typeStr) MTU=\(self.negotiatedMTU)")
                }

                // Subscribe to ALL notify characteristics (not just FFF4)
                // to catch any data the gimbal sends on other channels
                if char.properties.contains(.notify) && char.uuid != BLEConstants.notifyCharacteristicUUID {
                    peripheral.setNotifyValue(true, for: char)
                    onLogMessage?("    ✓ Also subscribed to \(uuidStr) notifications")
                }
            }

            pendingServiceDiscoveries -= 1
            checkDiscoveryComplete()
        }
    }

    private func checkDiscoveryComplete() {
        if pendingServiceDiscoveries <= 0 {
            if notifyCharacteristic != nil && writeCharacteristic != nil {
                connectionState = .ready
                onLogMessage?("BLE fully connected. \(allCharacteristics.count) total characteristics found.")
                logger.info("BLE connection fully established with \(self.allCharacteristics.count) characteristics")
            } else {
                let hasNotify = notifyCharacteristic != nil
                let hasWrite = writeCharacteristic != nil
                onLogMessage?("⚠️ Missing: notify=\(hasNotify) write=\(hasWrite)")
                connectionState = .error("Missing required characteristics (FFF4/FFF5)")
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            guard error == nil, let data = characteristic.value else { return }

            if characteristic.uuid == BLEConstants.notifyCharacteristicUUID {
                // Standard DUML data on FFF4
                onDataReceived?(data)
            } else {
                // Data from other characteristics — log it
                let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                let charUUID = characteristic.uuid.uuidString
                onLogMessage?("RX[\(charUUID)]: \(hex)")
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error = error {
            Task { @MainActor in
                let charUUID = characteristic.uuid.uuidString
                onLogMessage?("⚠️ Write error [\(charUUID)]: \(error.localizedDescription)")
                logger.error("BLE write error [\(charUUID)]: \(error.localizedDescription)")
            }
        }
    }
}
