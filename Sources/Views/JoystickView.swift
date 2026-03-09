import SwiftUI

/// A 2D virtual joystick for pan/tilt gimbal control.
/// Reports normalized (-1..1) deltas on both axes while dragging.
/// Returns to center (0, 0) when released.
struct JoystickView: View {
    let label: String
    let onMove: (Double, Double) -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false

    private let outerRadius: CGFloat = 70
    private let knobRadius: CGFloat = 18

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            ZStack {
                // Outer ring
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 2)
                    .frame(width: outerRadius * 2, height: outerRadius * 2)

                // Crosshair lines
                Path { path in
                    path.move(to: CGPoint(x: outerRadius, y: 10))
                    path.addLine(to: CGPoint(x: outerRadius, y: outerRadius * 2 - 10))
                    path.move(to: CGPoint(x: 10, y: outerRadius))
                    path.addLine(to: CGPoint(x: outerRadius * 2 - 10, y: outerRadius))
                }
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                .frame(width: outerRadius * 2, height: outerRadius * 2)

                // Knob
                Circle()
                    .fill(isDragging ? Color.accentColor : Color.secondary.opacity(0.6))
                    .frame(width: knobRadius * 2, height: knobRadius * 2)
                    .shadow(color: .black.opacity(isDragging ? 0.3 : 0.1), radius: isDragging ? 4 : 2)
                    .offset(dragOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let clamped = clampToCircle(value.translation)
                                dragOffset = clamped
                                isDragging = true
                                let dx = clamped.width / outerRadius
                                let dy = -clamped.height / outerRadius // invert Y (up = positive)
                                onMove(dx, dy)
                            }
                            .onEnded { _ in
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    dragOffset = .zero
                                }
                                isDragging = false
                                onMove(0, 0)
                            }
                    )
            }
            .frame(width: outerRadius * 2, height: outerRadius * 2)
        }
    }

    private func clampToCircle(_ translation: CGSize) -> CGSize {
        let distance = sqrt(translation.width * translation.width + translation.height * translation.height)
        let maxDistance = outerRadius - knobRadius
        if distance <= maxDistance {
            return translation
        }
        let scale = maxDistance / distance
        return CGSize(width: translation.width * scale, height: translation.height * scale)
    }
}
