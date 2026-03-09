import Foundation

enum DUMLConstants {
    static let sof: UInt8 = 0x55

    /// Device types (5-bit field in sender/receiver bytes)
    enum DeviceType: UInt8 {
        case any       = 0x00
        case camera    = 0x01
        case mobileApp = 0x02
        case flyc      = 0x03
        case gimbal    = 0x04
        case battery   = 0x05
        case remoteCtrl  = 0x06
        case wifi      = 0x07
        case pc        = 0x0A
    }

    /// Packet type flags (bits in the attribute/cmdType byte)
    enum CmdType: UInt8 {
        case request  = 0x00
        case ack      = 0x20   // bit 5
    }

    /// Command sets
    enum CmdSet: UInt8 {
        case general  = 0x00
        case special  = 0x01
        case camera   = 0x02
        case flyc     = 0x03
        case gimbal   = 0x04
        case battery  = 0x05
        case remoteCtrl = 0x06
        case wifi     = 0x07
        case osd      = 0x09
        case handheld = 0x0E
    }

    /// Gimbal commands (cmd_set = 0x04)
    enum GimbalCmd: UInt8 {
        case control           = 0x01
        case getPosition       = 0x02
        case paramsGet         = 0x05
        case adjustRoll        = 0x07
        case calibration       = 0x08
        case extCtrlDegree     = 0x0A
        case speedControl      = 0x0C   // speed-mode rotation (om-research)
        case suspendResume     = 0x0D
        case userParamsSet     = 0x0F
        case userParamsGet     = 0x10
        case absAngleControl   = 0x14
        case movement          = 0x15
        case typeGet           = 0x1C
        case degreeInfoSub     = 0x1E
        case autoCalibStatus   = 0x30
        case lock              = 0x39
        case rotateCamera      = 0x3A
        case resetAndSetMode   = 0x4C
        case stickStateGet     = 0x57
    }

    /// Battery commands (cmd_set = 0x05)
    enum BatteryCmd: UInt8 {
        case statusPush = 0x06
    }

    /// Rotation modes for gimbal movement
    enum RotationMode: UInt8 {
        case absoluteAngle    = 0x01
        case relativeAngle    = 0x04
        case absolutePosition = 0x05
        case speed            = 0x80
    }
}
