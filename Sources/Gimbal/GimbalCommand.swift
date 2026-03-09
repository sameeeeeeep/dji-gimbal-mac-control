import Foundation

/// Builds DUML payloads for specific gimbal commands.
enum GimbalCommand {

    /// Rotation command.
    /// Angles in degrees (multiplied by 10 for 0.1-degree units internally).
    /// Time in 10ms units (0-255).
    static func rotate(
        mode: DUMLConstants.RotationMode,
        yaw: Double,
        pitch: Double,
        roll: Double,
        time: UInt8 = 0
    ) -> (cmdSet: UInt8, cmdID: UInt8, payload: Data) {
        // Speed mode: raw speed values; angle modes: 0.1-degree units (x10)
        let scale: Double = (mode == .speed) ? 1.0 : 10.0
        let yawRaw = Int16(clamping: Int(yaw * scale))
        let rollRaw = Int16(clamping: Int(roll * scale))
        let pitchRaw = Int16(clamping: Int(pitch * scale))

        var data = Data()
        withUnsafeBytes(of: yawRaw.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: rollRaw.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: pitchRaw.littleEndian) { data.append(contentsOf: $0) }
        data.append(mode.rawValue)
        data.append(time)

        // om-research: speed mode uses cmdID 0x0C, angle modes use 0x14
        let cmdID: UInt8 = (mode == .speed)
            ? DUMLConstants.GimbalCmd.speedControl.rawValue
            : DUMLConstants.GimbalCmd.absAngleControl.rawValue

        return (
            cmdSet: DUMLConstants.CmdSet.gimbal.rawValue,
            cmdID: cmdID,
            payload: data
        )
    }

    /// Recenter gimbal to origin (absolute 0,0,0).
    static func recenter() -> (cmdSet: UInt8, cmdID: UInt8, payload: Data) {
        rotate(mode: .absoluteAngle, yaw: 0, pitch: 0, roll: 0, time: 20)
    }

    /// Set gimbal mode (follow / lock / FPV).
    static func setMode(_ mode: GimbalMode) -> (cmdSet: UInt8, cmdID: UInt8, payload: Data) {
        let modeValue: UInt8
        switch mode {
        case .follow: modeValue = 0x00
        case .lock:   modeValue = 0x01
        case .fpv:    modeValue = 0x02
        }
        return (
            cmdSet: DUMLConstants.CmdSet.gimbal.rawValue,
            cmdID: DUMLConstants.GimbalCmd.resetAndSetMode.rawValue,
            payload: Data([modeValue, 0x01])
        )
    }

    /// Suspend or resume gimbal motors.
    static func setMotorState(on: Bool) -> (cmdSet: UInt8, cmdID: UInt8, payload: Data) {
        // Magic values from om-research: 0x2AB5 = suspend, 0x7EF2 = resume
        let value: UInt16 = on ? 0x7EF2 : 0x2AB5
        var data = Data()
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        return (
            cmdSet: DUMLConstants.CmdSet.gimbal.rawValue,
            cmdID: DUMLConstants.GimbalCmd.suspendResume.rawValue,
            payload: data
        )
    }

    /// Start auto-calibration.
    static func startCalibration() -> (cmdSet: UInt8, cmdID: UInt8, payload: Data) {
        (
            cmdSet: DUMLConstants.CmdSet.gimbal.rawValue,
            cmdID: DUMLConstants.GimbalCmd.calibration.rawValue,
            payload: Data([0x01]) // JointCoarse
        )
    }

    /// Request battery status.
    static func requestBatteryStatus() -> (cmdSet: UInt8, cmdID: UInt8, payload: Data) {
        (
            cmdSet: DUMLConstants.CmdSet.battery.rawValue,
            cmdID: DUMLConstants.BatteryCmd.statusPush.rawValue,
            payload: Data()
        )
    }

    /// Query current gimbal position / angles.
    static func requestPosition() -> (cmdSet: UInt8, cmdID: UInt8, payload: Data) {
        (
            cmdSet: DUMLConstants.CmdSet.gimbal.rawValue,
            cmdID: DUMLConstants.GimbalCmd.getPosition.rawValue,
            payload: Data()
        )
    }
}
