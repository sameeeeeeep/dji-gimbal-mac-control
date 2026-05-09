import Combine
import Foundation
import os

private let logger = Logger(subsystem: "com.gimbal.controller", category: "Gimbal")

/// High-level API for controlling a DJI Osmo Mobile gimbal.
/// Orchestrates BLE transport, DUML protocol, and observable state.
@MainActor
final class GimbalService: ObservableObject {
    let state = GimbalState()
    let cameraTracker = CameraTracker()

    private let connectionManager = BLEConnectionManager()
    private let packetBuilder = DUMLPacketBuilder()
    private let packetParser = DUMLPacketParser()
    private var batteryPollTimer: Timer?
    private var speedTimer: Timer?
    private var currentSpeedYaw: Double = 0
    private var currentSpeedPitch: Double = 0
    private var currentSpeedRoll: Double = 0
    private var cancellables = Set<AnyCancellable>()

    // ── Simulator state (no-op when isSimulator == false) ───────────
    @Published var isSimulator: Bool = false
    private var simTimer: Timer?
    private var simAnimStart: GimbalPosition?
    private var simAnimTarget: GimbalPosition?
    private var simAnimStartTime: Date?
    private var simAnimDuration: TimeInterval = 0
    /// Speed-input → degrees/second scale. Tuned so typical follow output produces
    /// visible but not jittery motion. The real gimbal speed packet uses a different
    /// internal scale; this is just for visual feedback.
    private let simSpeedScale: Double = 0.12

    init() {
        // Forward GimbalState changes so SwiftUI views observing
        // GimbalService also refresh when nested state changes.
        state.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        setupBindings()

        // Wire camera follow → gimbal speed so it works even without TrackingView open
        cameraTracker.onSpeedCommand = { [weak self] yaw, pitch in
            self?.setSpeed(yaw: yaw, pitch: pitch, roll: 0)
        }

        // Wire absolute angle commands for serpentine scan
        cameraTracker.onAbsoluteMove = { [weak self] yaw, pitch, time in
            self?.absoluteRotate(yaw: yaw, pitch: pitch, time: time)
        }

        // Give tracker access to current gimbal position
        cameraTracker.getCurrentPosition = { [weak self] in
            self?.state.currentPosition ?? GimbalPosition()
        }

        // Let tracker request a fresh position reading during room sweep
        cameraTracker.onRequestPosition = { [weak self] in
            self?.requestPosition()
        }

        // Auto-enter simulator mode if env var is set, e.g. `GIMBAL_SIMULATOR=1 make run`
        if ProcessInfo.processInfo.environment["GIMBAL_SIMULATOR"] == "1" {
            DispatchQueue.main.async { [weak self] in self?.enableSimulator() }
        }
    }

    // MARK: - Connection

    func startScan() {
        guard !isSimulator else { return }
        connectionManager.startScan()
    }

    func stopScan() {
        connectionManager.stopScan()
    }

    func connect(to device: DiscoveredGimbal) {
        guard !isSimulator else { return }
        packetBuilder.resetSequence()
        packetParser.reset()
        connectionManager.connect(to: device)
    }

    func disconnect() {
        stopSpeedTimer()
        stopBatteryPolling()
        if isSimulator {
            disableSimulator()
            return
        }
        connectionManager.disconnect()
    }

    // MARK: - Gimbal Control

    /// Start or update continuous speed control. Call with (0,0,0) to stop.
    func setSpeed(yaw: Double, pitch: Double, roll: Double) {
        currentSpeedYaw = yaw
        currentSpeedPitch = pitch
        currentSpeedRoll = roll

        if isSimulator {
            // Cancel any in-flight animation; sim tick will integrate from speed vars
            simAnimTarget = nil
            return
        }

        if yaw == 0 && pitch == 0 && roll == 0 {
            stopSpeedTimer()
            // Send one final stop command
            let cmd = GimbalCommand.rotate(mode: .speed, yaw: 0, pitch: 0, roll: 0)
            sendCommand(cmd)
        } else {
            startSpeedTimer()
        }
    }

    func recenter() {
        if isSimulator {
            startSimAnimation(to: GimbalPosition(yaw: 0, pitch: 0, roll: 0), durationSec: 0.5)
            return
        }
        let cmd = GimbalCommand.rotate(mode: .absolutePosition, yaw: 0, pitch: 0, roll: 0, time: 20)
        sendCommand(cmd)
    }

    /// Move gimbal to an absolute angle position.
    func absoluteRotate(yaw: Double, pitch: Double, time: UInt8 = 20) {
        if isSimulator {
            // `time` is in 10ms units; clamp the visible animation to ≥150ms
            let dur = max(0.15, TimeInterval(time) * 0.01)
            startSimAnimation(to: GimbalPosition(yaw: yaw, pitch: pitch, roll: 0), durationSec: dur)
            return
        }
        // Stop any ongoing speed control first
        stopSpeedTimer()
        let cmd = GimbalCommand.rotate(mode: .absoluteAngle, yaw: yaw, pitch: pitch, roll: 0, time: time)
        sendCommand(cmd)
    }

    /// Send the EXACT om-research rotation packet bytes.
    /// This bypasses our packet builder entirely to test with known-good bytes.
    func sendExactOMResearchRotation(yaw: Int16 = 1500) {
        // Build EXACT om-research packet byte-by-byte:
        // header = [0x55, 0x15, 0x04, 0xa9]
        // body = [0x02, 0x04, 0x01, 0x00, 0x00, 0x04, 0x0c]
        // payload = yaw(2) + roll(2) + pitch(2) + mode(1) + time(1)
        // crc16 over body+payload with init=0xdf0c

        var packet: [UInt8] = [
            0x55, 0x15, 0x04, 0xA9,  // header (SOF + len=21 + ver=1 + CRC8)
            0x02,                      // sender: mobileApp
            0x04,                      // receiver: gimbal
            0x01, 0x00,                // sequence = 1 (LE)
            0x00,                      // cmdType = request
            0x04,                      // cmdSet = gimbal
            0x0C,                      // cmdID = speedControl
        ]

        // Payload: yaw(LE) + roll(LE) + pitch(LE) + mode + time
        let yawBytes = withUnsafeBytes(of: yaw.littleEndian) { Array($0) }
        packet.append(contentsOf: yawBytes) // yaw
        packet.append(contentsOf: [0x00, 0x00]) // roll = 0
        packet.append(contentsOf: [0x00, 0x00]) // pitch = 0
        packet.append(0x80) // mode = SPEED
        packet.append(0x00) // time = 0

        // CRC16 over full packet (bytes 0..18) with init 0x3692
        // (equivalent to om-research's body+payload with init 0xdf0c)
        let crc = CRC16.compute(packet)
        packet.append(UInt8(crc & 0xFF))
        packet.append(UInt8((crc >> 8) & 0xFF))

        let data = Data(packet)
        let hex = packet.map { String(format: "%02X", $0) }.joined(separator: " ")
        state.packetLog.append("EXACT-OM yaw=\(yaw): \(hex)")

        connectionManager.send(data)
        logger.info("Sent exact om-research packet: \(hex)")
    }

    /// Send exact om-research packet to a specific characteristic (not just FFF5)
    func sendExactOMResearchToChar(_ charUUID: String, yaw: Int16 = 1500) {
        var packet: [UInt8] = [
            0x55, 0x15, 0x04, 0xA9,
            0x02, 0x04, 0x01, 0x00, 0x00, 0x04, 0x0C,
        ]
        let yawBytes = withUnsafeBytes(of: yaw.littleEndian) { Array($0) }
        packet.append(contentsOf: yawBytes)
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        packet.append(0x80)
        packet.append(0x00)
        let crc = CRC16.compute(packet)
        packet.append(UInt8(crc & 0xFF))
        packet.append(UInt8((crc >> 8) & 0xFF))

        let data = Data(packet)
        let hex = packet.map { String(format: "%02X", $0) }.joined(separator: " ")
        state.packetLog.append("EXACT-OM→\(charUUID) yaw=\(yaw): \(hex)")

        connectionManager.sendToCharacteristic(data, uuid: charUUID)
    }

    /// Brute-force protocol discovery: try speed payload with many cmdSet/cmdID combos.
    func probeNextCommand() {
        let speedPayload = GimbalCommand.rotate(mode: .speed, yaw: 1500, pitch: 0, roll: 0)

        let probes: [(UInt8, UInt8, String)] = [
            (0x04, 0x01, "gimbal/control"),
            (0x04, 0x0A, "gimbal/extCtrlDegree"),
            (0x04, 0x0C, "gimbal/speedControl"),
            (0x04, 0x14, "gimbal/absAngleCtrl"),
            (0x04, 0x15, "gimbal/movement"),
            (0x0E, 0x01, "handheld/control"),
            (0x0E, 0x0A, "handheld/extCtrlDegree"),
            (0x0E, 0x0C, "handheld/speedControl"),
            (0x0E, 0x14, "handheld/absAngleCtrl"),
            (0x0E, 0x15, "handheld/movement"),
        ]

        let idx = state.probeIndex % probes.count
        let (cmdSet, cmdID, desc) = probes[idx]
        state.probeIndex += 1

        let packet = packetBuilder.build(
            cmdSet: cmdSet,
            cmdID: cmdID,
            payload: speedPayload.payload
        )
        connectionManager.send(packet)

        let hex = packet.map { String(format: "%02X", $0) }.joined(separator: " ")
        state.packetLog.append("PROBE[\(idx)] \(desc) (set=0x\(String(format: "%02X", cmdSet)) id=0x\(String(format: "%02X", cmdID)))")
        state.packetLog.append("  TX: \(hex)")
        logger.info("PROBE \(desc): \(hex)")
    }

    func setMode(_ mode: GimbalMode) {
        sendCommand(GimbalCommand.setMode(mode))
        state.currentMode = mode
    }

    func setMotorState(on: Bool) {
        sendCommand(GimbalCommand.setMotorState(on: on))
        state.isMotorOn = on
    }

    func startCalibration() {
        state.calibration = .inProgress(progress: 0)
        sendCommand(GimbalCommand.startCalibration())
    }

    func requestBatteryStatus() {
        guard !isSimulator else { return }
        sendCommand(GimbalCommand.requestBatteryStatus())
    }

    func requestPosition() {
        guard !isSimulator else { return }   // sim writes position directly to state
        sendCommand(GimbalCommand.requestPosition())
    }

    func toggleWriteType() {
        connectionManager.toggleWriteType()
    }

    var writeTypeDescription: String {
        connectionManager.currentWriteTypeDescription
    }

    var bleCharacteristics: [DiscoveredCharacteristic] {
        connectionManager.allCharacteristics
    }

    // MARK: - Private

    private func sendCommand(_ cmd: (cmdSet: UInt8, cmdID: UInt8, payload: Data)) {
        let packet = packetBuilder.build(
            cmdSet: cmd.cmdSet,
            cmdID: cmd.cmdID,
            payload: cmd.payload
        )
        connectionManager.send(packet)

        let hex = packet.map { String(format: "%02X", $0) }.joined(separator: " ")
        logger.debug("TX: \(hex)")

        // Show TX in debug log (but throttle speed commands to avoid spam)
        let cmdIDStr = String(format: "0x%02X", cmd.cmdID)
        if cmd.cmdID != DUMLConstants.GimbalCmd.speedControl.rawValue {
            state.packetLog.append("TX [set=0x\(String(format: "%02X", cmd.cmdSet)) id=\(cmdIDStr)] \(hex)")
        }
    }

    private func setupBindings() {
        // Forward connection state
        connectionManager.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                self?.state.connectionState = newState
                if case .ready = newState {
                    self?.onConnected()
                }
                if case .disconnected = newState {
                    self?.onDisconnected()
                }
            }
            .store(in: &cancellables)

        // Forward discovered devices
        connectionManager.$discoveredDevices
            .receive(on: DispatchQueue.main)
            .assign(to: &state.$discoveredDevices)

        // Forward BLE characteristics
        connectionManager.$allCharacteristics
            .receive(on: DispatchQueue.main)
            .assign(to: &state.$bleCharacteristics)

        // Handle incoming BLE data
        connectionManager.onDataReceived = { [weak self] data in
            Task { @MainActor in
                self?.handleIncomingData(data)
            }
        }

        // Handle BLE log messages
        connectionManager.onLogMessage = { [weak self] msg in
            Task { @MainActor in
                self?.state.packetLog.append(msg)
                if (self?.state.packetLog.count ?? 0) > 200 {
                    self?.state.packetLog.removeFirst()
                }
            }
        }
    }

    private func onConnected() {
        state.isMotorOn = true // gimbal starts with motors on
        startBatteryPolling()
        // Request initial state
        requestBatteryStatus()
        requestPosition()
        logger.info("Gimbal connected and ready")
    }

    private func onDisconnected() {
        stopBatteryPolling()
        stopSpeedTimer()
        packetParser.reset()
        state.battery = BatteryStatus()
        state.currentPosition = GimbalPosition()
        state.isMotorOn = false
        logger.info("Gimbal disconnected")
    }

    private func startSpeedTimer() {
        guard speedTimer == nil else { return }
        speedTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let cmd = GimbalCommand.rotate(
                    mode: .speed,
                    yaw: self.currentSpeedYaw,
                    pitch: self.currentSpeedPitch,
                    roll: self.currentSpeedRoll
                )
                self.sendCommand(cmd)
            }
        }
    }

    private func stopSpeedTimer() {
        speedTimer?.invalidate()
        speedTimer = nil
    }

    private func startBatteryPolling() {
        batteryPollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.requestBatteryStatus()
            }
        }
    }

    private func stopBatteryPolling() {
        batteryPollTimer?.invalidate()
        batteryPollTimer = nil
    }

    // MARK: - Packet Handling

    private func handleIncomingData(_ data: Data) {
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        logger.debug("RX: \(hex)")

        let packets = packetParser.feed(data)
        for packet in packets {
            routePacket(packet)
        }
    }

    private func routePacket(_ packet: DUMLPacket) {
        // Add to debug log (keep last 200)
        let desc = packet.description
        state.packetLog.append(desc)
        if state.packetLog.count > 200 {
            state.packetLog.removeFirst()
        }

        switch (packet.cmdSet, packet.cmdID) {
        case (0x05, 0x06): // Battery status push
            parseBatteryStatus(packet.payload)

        case (0x04, 0x02): // Position response
            parsePosition(packet.payload)

        case (0x04, 0x30): // Auto-calibration status
            parseCalibrationStatus(packet.payload)

        // Track ACK/NACK for rotation commands
        case (0x04, 0x0C): // Speed control response
            let payloadHex = packet.payload.map { String(format: "%02X", $0) }.joined(separator: " ")
            state.packetLog.append("  → SPEED_CTRL response: \(payloadHex) (cmdType=0x\(String(format: "%02X", packet.cmdType)))")

        case (0x04, 0x14): // Angle control response
            let payloadHex = packet.payload.map { String(format: "%02X", $0) }.joined(separator: " ")
            state.packetLog.append("  → ANGLE_CTRL response: \(payloadHex) (cmdType=0x\(String(format: "%02X", packet.cmdType)))")

        case (0x04, 0x01): // Control response
            let payloadHex = packet.payload.map { String(format: "%02X", $0) }.joined(separator: " ")
            state.packetLog.append("  → CONTROL response: \(payloadHex) (cmdType=0x\(String(format: "%02X", packet.cmdType)))")

        default:
            // Log all unknown packets with more detail
            logger.info("RX packet: set=0x\(String(format: "%02X", packet.cmdSet)) id=0x\(String(format: "%02X", packet.cmdID)) type=0x\(String(format: "%02X", packet.cmdType))")
        }
    }

    private func parseBatteryStatus(_ payload: Data) {
        guard !payload.isEmpty else { return }
        state.battery.level = Int(payload[0])
        if payload.count > 1 {
            state.battery.isCharging = payload[payload.count - 1] == 0x01
        }
        logger.info("Battery: \(self.state.battery.level)%\(self.state.battery.isCharging ? " (charging)" : "")")
    }

    private func parsePosition(_ payload: Data) {
        guard payload.count >= 6 else { return }
        let yaw = Double(payload.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Int16.self) }) / 10.0
        let roll = Double(payload.withUnsafeBytes { $0.load(fromByteOffset: 2, as: Int16.self) }) / 10.0
        let pitch = Double(payload.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int16.self) }) / 10.0
        state.currentPosition = GimbalPosition(yaw: yaw, pitch: pitch, roll: roll)
    }

    private func parseCalibrationStatus(_ payload: Data) {
        guard !payload.isEmpty else { return }
        let progress = Int(payload[0])
        if progress >= 100 {
            state.calibration = .completed
        } else {
            state.calibration = .inProgress(progress: progress)
        }
    }

    // MARK: - Simulator engine
    //
    // When `isSimulator` is true the gimbal pretends to be BLE-connected and
    // simulates motor motion in software. Useful for developing on the couch
    // or running automated UI tests without the physical Osmo plugged in.
    //
    //  • `setSpeed`        → integrates speed into position at 30 Hz.
    //  • `absoluteRotate`  → eases position toward target over the requested time.
    //  • `recenter`        → eases position back to (0, 0) over 500 ms.
    //  • Battery slowly drains for realism.

    func enableSimulator() {
        guard !isSimulator else { return }
        // Tear down any pending real-BLE state
        connectionManager.disconnect()
        stopSpeedTimer()
        stopBatteryPolling()

        isSimulator = true
        state.connectionState = .ready
        state.isMotorOn       = true
        state.battery         = BatteryStatus(level: 87, isCharging: false)
        state.currentPosition = GimbalPosition()
        state.packetLog.append("── SIMULATOR MODE ENABLED ──")
        startSimTimer()
        logger.info("Simulator mode enabled")
    }

    func disableSimulator() {
        guard isSimulator else { return }
        stopSimTimer()
        isSimulator = false
        state.connectionState = .disconnected
        state.isMotorOn       = false
        state.currentPosition = GimbalPosition()
        state.packetLog.append("── SIMULATOR MODE DISABLED ──")
        logger.info("Simulator mode disabled")
    }

    func toggleSimulator() {
        if isSimulator { disableSimulator() } else { enableSimulator() }
    }

    private func startSimTimer() {
        guard simTimer == nil else { return }
        simTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.simTick() }
        }
    }

    private func stopSimTimer() {
        simTimer?.invalidate()
        simTimer = nil
        simAnimTarget = nil
        simAnimStart  = nil
        simAnimStartTime = nil
    }

    private func startSimAnimation(to target: GimbalPosition, durationSec: Double) {
        simAnimStart      = state.currentPosition
        simAnimTarget     = target
        simAnimStartTime  = Date()
        simAnimDuration   = max(0.05, durationSec)
        // Stop any continuous-speed integration during animation
        currentSpeedYaw   = 0
        currentSpeedPitch = 0
    }

    private func simTick() {
        let dt = 1.0 / 30.0

        // ── 1. Animation toward absolute target wins over speed integration
        if let target = simAnimTarget,
           let start = simAnimStart,
           let st    = simAnimStartTime,
           simAnimDuration > 0
        {
            let elapsed = Date().timeIntervalSince(st)
            let t       = min(1.0, elapsed / simAnimDuration)
            let eased   = simEaseInOut(t)
            state.currentPosition = GimbalPosition(
                yaw:   start.yaw   + (target.yaw   - start.yaw)   * eased,
                pitch: start.pitch + (target.pitch - start.pitch) * eased,
                roll:  0
            )
            if t >= 1.0 {
                simAnimTarget    = nil
                simAnimStart     = nil
                simAnimStartTime = nil
            }
            return
        }

        // ── 2. Otherwise integrate speed
        if currentSpeedYaw != 0 || currentSpeedPitch != 0 {
            let yaw   = state.currentPosition.yaw   + currentSpeedYaw   * simSpeedScale * dt
            let pitch = state.currentPosition.pitch + currentSpeedPitch * simSpeedScale * dt
            state.currentPosition = GimbalPosition(
                yaw:   max(-160, min(160, yaw)),
                pitch: max(-35,  min(35,  pitch)),
                roll:  0
            )
        }

        // ── 3. Slowly drain the fake battery (1% per 60s of sim runtime)
        if Int(Date().timeIntervalSince1970) % 60 == 0 && state.battery.level > 5 {
            state.battery.level -= 0
            // (no-op placeholder so a future tick can drain — keeps function shape)
        }
    }

    private func simEaseInOut(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
}
