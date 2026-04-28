import Foundation

@MainActor
final class PresetsManager: ObservableObject {
    @Published var customPresets: [GimbalPreset] = []

    var allPresets: [GimbalPreset] { GimbalPreset.templates + customPresets }

    private let storageKey = "com.gimbal.customPresets"

    init() { load() }

    // MARK: - Mutations

    func savePosition(name: String, yaw: Double, pitch: Double, roll: Double,
                      transitionTime: UInt8 = 20) {
        let preset = GimbalPreset(
            name: name, yaw: yaw, pitch: pitch, roll: roll,
            transitionTime: transitionTime, isBuiltIn: false
        )
        customPresets.append(preset)
        persist()
    }

    func delete(_ preset: GimbalPreset) {
        customPresets.removeAll { $0.id == preset.id }
        persist()
    }

    func rename(_ preset: GimbalPreset, to name: String) {
        guard let idx = customPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        customPresets[idx].name = name
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(customPresets) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([GimbalPreset].self, from: data) else { return }
        customPresets = saved
    }
}
