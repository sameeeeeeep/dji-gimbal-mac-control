import AVFoundation
import CoreAudio
import AudioToolbox
import os

/// Routes every AVAudioEngine in the app to the iPhone Continuity Camera mic
/// when one is connected. This is a gimbal app — the phone IS the camera, so
/// the phone should also be the mic. Falls back silently to the system default
/// input when no Continuity Camera is paired.
enum PreferredAudioInput {

    private static let logger = Logger(subsystem: "com.gimbal.controller", category: "AudioInput")

    /// User-selected mic UID, mirrored from `CameraTracker.selectedMicrophone`.
    /// When set, `apply(to:)` routes engines to this device. Set to `nil` to
    /// fall back to auto-pick among Continuity + external mics only.
    nonisolated(unsafe) static var preferredDeviceUID: String?

    /// Resolve the best non-laptop mic device ID to route to.
    /// Priority: user pick → Continuity Camera → any external (USB) mic.
    /// HARD RULE: never returns the laptop's built-in mic. If no non-laptop
    /// mic is connected, returns `nil` and the engine keeps system default
    /// (which is fine for *engine creation*, but `apply` will refuse to set
    /// the device — silent capture is preferred over capturing the laptop mic).
    static func selectedDeviceID() -> AudioDeviceID? {
        // 1. Honor the user's explicit pick if it still exists.
        if let uid = preferredDeviceUID, let id = audioDeviceID(forUID: uid) {
            return id
        }
        // 2. Auto-pick from Continuity + external only.
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let device = session.devices.first(where: { $0.deviceType == .continuityCamera })
            ?? session.devices.first
        guard let uid = device?.uniqueID else { return nil }
        return audioDeviceID(forUID: uid)
    }

    /// Apply the selected non-laptop mic to this engine's input node. Must be
    /// called before `engine.start()` and before reading `inputNode.outputFormat`.
    ///
    /// If no non-laptop mic is available, this DELIBERATELY does not set a
    /// device. macOS will leave the engine in a default-input state but the
    /// caller is expected to detect "no mic" upstream and not start the engine
    /// (or accept a silent input). We never silently fall back to the laptop.
    static func apply(to engine: AVAudioEngine) {
        guard let dev = selectedDeviceID() else {
            logger.warning("No non-laptop mic available; audio engine will not be routed.")
            return
        }
        guard let au = engine.inputNode.audioUnit else {
            logger.error("Input node has no audio unit; cannot route to selected mic")
            return
        }
        var id = dev
        let status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            logger.info("Routed audio engine to mic (deviceID=\(dev))")
        } else {
            logger.error("Failed to route to selected mic: OSStatus \(status)")
        }
    }

    /// True iff at least one non-laptop mic is currently available. Callers
    /// (transcriber, VAD) can guard their `start()` on this so they don't
    /// open the laptop mic by accident.
    static var hasNonLaptopMic: Bool {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return !session.devices.isEmpty
    }

    // MARK: - Core Audio device lookup

    /// Resolve an `AVCaptureDevice.uniqueID` to its Core Audio `AudioDeviceID`.
    /// They share the UID string — we just walk the system device list.
    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var size: UInt32 = 0
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size
        ) == noErr else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size, &devices
        ) == noErr else { return nil }

        for dev in devices {
            var uidStr: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let s = AudioObjectGetPropertyData(dev, &uidAddr, 0, nil, &uidSize, &uidStr)
            if s == noErr, (uidStr as String) == uid {
                return dev
            }
        }
        return nil
    }
}
