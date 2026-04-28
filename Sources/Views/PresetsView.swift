import SwiftUI

struct PresetsView: View {
    @ObservedObject var gimbal: GimbalService
    @ObservedObject var presets: PresetsManager

    @State private var newPresetName = ""
    @State private var deletingPreset: GimbalPreset?
    @State private var editingPreset: GimbalPreset?
    @State private var editingName = ""

    var body: some View {
        VStack(spacing: 0) {
            // Save current position bar
            saveBar

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Built-in templates
                    PresetSection(title: "Templates", systemImage: "star") {
                        ForEach(GimbalPreset.templates) { preset in
                            PresetRow(preset: preset, isConnected: isConnected) {
                                apply(preset)
                            }
                        }
                    }

                    // Custom presets
                    if !presets.customPresets.isEmpty {
                        PresetSection(title: "My Presets", systemImage: "bookmark") {
                            ForEach(presets.customPresets) { preset in
                                PresetRow(
                                    preset: preset,
                                    isConnected: isConnected,
                                    onApply: { apply(preset) },
                                    onDelete: { presets.delete(preset) },
                                    onRename: {
                                        editingPreset = preset
                                        editingName = preset.name
                                    }
                                )
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 360)
        .sheet(item: $editingPreset) { preset in
            RenameSheet(name: $editingName) {
                presets.rename(preset, to: editingName)
                editingPreset = nil
            } onCancel: {
                editingPreset = nil
            }
        }
    }

    // MARK: - Save bar

    private var saveBar: some View {
        HStack(spacing: 10) {
            TextField("Preset name…", text: $newPresetName)
                .textFieldStyle(.roundedBorder)

            Button("Save Position") {
                let name = newPresetName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let pos = gimbal.state.currentPosition
                presets.savePosition(name: name,
                                     yaw: pos.yaw, pitch: pos.pitch, roll: pos.roll)
                newPresetName = ""
            }
            .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            // Current position hint
            HStack(spacing: 6) {
                Image(systemName: "location")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                let pos = gimbal.state.currentPosition
                Text(String(format: "Y %.0f°  P %.0f°  R %.0f°", pos.yaw, pos.pitch, pos.roll))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.bottom, 2)
        }
        .padding(.bottom, 18)
    }

    // MARK: - Helpers

    private var isConnected: Bool { gimbal.state.connectionState.isConnected }

    private func apply(_ preset: GimbalPreset) {
        gimbal.absoluteRotate(yaw: preset.yaw, pitch: preset.pitch, time: preset.transitionTime)
    }
}

// MARK: - Section container

private struct PresetSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            content()
        }
    }
}

// MARK: - Preset row

private struct PresetRow: View {
    let preset: GimbalPreset
    let isConnected: Bool
    var onApply: () -> Void
    var onDelete: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            // Angle badges
            HStack(spacing: 6) {
                AngleBadge(label: "Y", value: preset.yaw)
                AngleBadge(label: "P", value: preset.pitch)
            }
            .frame(width: 130, alignment: .leading)

            Text(preset.name)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Apply") { onApply() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isConnected)

            if onRename != nil || onDelete != nil {
                Menu {
                    if let rename = onRename {
                        Button("Rename…", action: rename)
                    }
                    if let delete = onDelete {
                        Divider()
                        Button("Delete", role: .destructive, action: delete)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.medium)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }
}

// MARK: - Angle badge

private struct AngleBadge: View {
    let label: String
    let value: Double

    var body: some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(String(format: "%+.0f°", value))
                .font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
    }
}

// MARK: - Rename sheet

private struct RenameSheet: View {
    @Binding var name: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Preset")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            HStack {
                Button("Cancel", action: onCancel)
                Button("Save") { onSave() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 300)
    }
}
