import SwiftUI
import SceneKit
import AppKit

/// Interactive 360° panorama sphere.
///
/// The equirectangular panorama is mapped onto the inside of an SCNSphere.
/// The user drags to look around. Cyan pins mark detected people at their
/// real gimbal angles. Clicking a pin calls `onTapSubject`.
struct PanoramaSphereView: NSViewRepresentable {
    let panorama: NSImage
    let subjects: [SubjectMapEntry]
    var onTapSubject: ((SubjectMapEntry) -> Void)? = nil

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = .black
        scnView.allowsCameraControl = false
        scnView.antialiasingMode = .multisampling4X
        scnView.showsStatistics = false

        let scene = buildScene(coordinator: context.coordinator)
        scnView.scene = scene
        scnView.pointOfView = context.coordinator.cameraNode

        // Pan to look around
        let pan = NSPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:)))
        scnView.addGestureRecognizer(pan)

        // Click to navigate to a person pin
        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleClick(_:)))
        scnView.addGestureRecognizer(click)

        // Scroll wheel zoom
        let scroll = NSMagnificationGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMagnify(_:)))
        scnView.addGestureRecognizer(scroll)

        context.coordinator.scnView = scnView
        return scnView
    }

    func updateNSView(_ nsView: SCNView, context: Context) { }

    func makeCoordinator() -> Coordinator {
        Coordinator(subjects: subjects, onTapSubject: onTapSubject)
    }

    // MARK: - Scene

    private func buildScene(coordinator: Coordinator) -> SCNScene {
        let scene = SCNScene()

        // ── Sphere ────────────────────────────────────────────────────────────
        let sphere = SCNSphere(radius: 10)
        sphere.segmentCount = 128

        let mat = SCNMaterial()
        mat.diffuse.contents = panorama
        mat.lightingModel = .constant    // no lighting — raw texture colour
        mat.isDoubleSided = true         // visible from inside

        // Mirror horizontally: when viewing from inside, the panorama is
        // left-right flipped relative to the equirectangular convention.
        // SCNMatrix4 UV transform: scale U by –1, translate U by +1 → U' = 1–U.
        mat.diffuse.contentsTransform = SCNMatrix4(
            m11: -1, m12: 0, m13: 0, m14: 0,
            m21:  0, m22: 1, m23: 0, m24: 0,
            m31:  0, m32: 0, m33: 1, m34: 0,
            m41:  1, m42: 0, m43: 0, m44: 1
        )
        mat.diffuse.wrapS = .repeat
        mat.diffuse.wrapT = .clampToBorder
        sphere.materials = [mat]

        let sphereNode = SCNNode(geometry: sphere)
        scene.rootNode.addChildNode(sphereNode)

        // ── Camera ────────────────────────────────────────────────────────────
        let camera = SCNCamera()
        camera.fieldOfView = 80
        camera.zNear = 0.1
        camera.zFar  = 100
        let camNode = SCNNode()
        camNode.camera = camera
        camNode.position = SCNVector3(0, 0, 0)
        // Face forward (yaw=0, pitch=0 of the gimbal scan)
        camNode.eulerAngles = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(camNode)
        coordinator.cameraNode = camNode

        // ── Subject pins ──────────────────────────────────────────────────────
        for entry in subjects {
            let pin = makePinNode(entry: entry)
            scene.rootNode.addChildNode(pin)
        }

        return scene
    }

    // MARK: - Pin construction

    private func makePinNode(entry: SubjectMapEntry) -> SCNNode {
        let yawRad   = Float(entry.approximateYaw   * .pi / 180)
        let pitchRad = Float(entry.approximatePitch * .pi / 180)
        let r: Float = 9.4  // slightly inside sphere surface

        // Cartesian position for this gimbal angle.
        // We negate X to match the horizontal-mirror we applied to the texture,
        // so the pin visually sits on the correct person in the panorama.
        let x = -r * cos(pitchRad) * sin(yawRad)
        let y =  r * sin(pitchRad)
        let z = -r * cos(pitchRad) * cos(yawRad)

        // ── Dot ──
        let dot = SCNSphere(radius: 0.2)
        let dotMat = SCNMaterial()
        dotMat.diffuse.contents  = NSColor.cyan
        dotMat.emission.contents = NSColor.cyan
        dotMat.lightingModel = .constant
        dot.materials = [dotMat]

        let pinNode = SCNNode(geometry: dot)
        pinNode.position = SCNVector3(x, y, z)
        pinNode.name = entry.id.uuidString   // used for hit testing

        // ── Pulse ring ──
        let ring = SCNTorus(ringRadius: 0.35, pipeRadius: 0.04)
        let ringMat = SCNMaterial()
        ringMat.diffuse.contents  = NSColor.cyan.withAlphaComponent(0.5)
        ringMat.emission.contents = NSColor.cyan.withAlphaComponent(0.3)
        ringMat.lightingModel = .constant
        ring.materials = [ringMat]
        let ringNode = SCNNode(geometry: ring)
        pinNode.addChildNode(ringNode)

        // ── Text label ──
        let label = entry.name ?? "Person \(entry.speakerNumber)"
        let text  = SCNText(string: label, extrusionDepth: 0)
        text.font = NSFont.boldSystemFont(ofSize: 0.5)
        text.flatness = 0.1
        let textMat = SCNMaterial()
        textMat.diffuse.contents  = NSColor.white
        textMat.emission.contents = NSColor.white
        textMat.lightingModel = .constant
        text.materials = [textMat]

        let textNode = SCNNode(geometry: text)
        let (bMin, bMax) = textNode.boundingBox
        textNode.pivot = SCNMatrix4MakeTranslation(
            (bMin.x + bMax.x) / 2,
            bMin.y,
            (bMin.z + bMax.z) / 2)
        textNode.position = SCNVector3(0, 0.45, 0)
        textNode.name = entry.id.uuidString   // also hittable via parent
        pinNode.addChildNode(textNode)

        // Always face the camera (billboard)
        let constraint = SCNBillboardConstraint()
        constraint.freeAxes = [.Y, .X]
        pinNode.constraints = [constraint]

        return pinNode
    }

    // MARK: - Coordinator (gestures + hit testing)

    class Coordinator: NSObject {
        var scnView: SCNView?
        var cameraNode: SCNNode?
        let subjects: [SubjectMapEntry]
        var onTapSubject: ((SubjectMapEntry) -> Void)?

        private var yaw: Float = 0      // radians
        private var pitch: Float = 0    // radians
        private var fov: CGFloat = 80   // degrees
        private var lastDragLoc: CGPoint = .zero

        init(subjects: [SubjectMapEntry], onTapSubject: ((SubjectMapEntry) -> Void)?) {
            self.subjects = subjects
            self.onTapSubject = onTapSubject
        }

        @objc func handlePan(_ gesture: NSPanGestureRecognizer) {
            guard let view = scnView, let cam = cameraNode else { return }
            let loc = gesture.location(in: view)
            switch gesture.state {
            case .began:
                lastDragLoc = loc
            case .changed:
                let dx = Float(loc.x - lastDragLoc.x)
                let dy = Float(loc.y - lastDragLoc.y)
                lastDragLoc = loc
                // Sensitivity: ~0.25° per pixel
                yaw   -= dx * 0.25 * (.pi / 180)
                pitch += dy * 0.25 * (.pi / 180)
                pitch  = max(-.pi / 2, min(.pi / 2, pitch))
                cam.eulerAngles = SCNVector3(pitch, yaw, 0)
            default: break
            }
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let view = scnView else { return }
            let loc = gesture.location(in: view)
            let hits = view.hitTest(loc, options: [
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue
            ])
            for hit in hits {
                let nodeName = hit.node.name ?? hit.node.parent?.name
                guard let name = nodeName,
                      let uuid = UUID(uuidString: name),
                      let entry = subjects.first(where: { $0.id == uuid }) else { continue }
                onTapSubject?(entry)
                flashNode(hit.node.name == entry.id.uuidString ? hit.node : hit.node.parent!)
                break
            }
        }

        @objc func handleMagnify(_ gesture: NSMagnificationGestureRecognizer) {
            guard let cam = cameraNode?.camera else { return }
            fov = max(30, min(100, fov - gesture.magnification * 20))
            cam.fieldOfView = fov
        }

        private func flashNode(_ node: SCNNode) {
            let flash = SCNAction.sequence([
                SCNAction.fadeOpacity(to: 0.3, duration: 0.1),
                SCNAction.fadeOpacity(to: 1.0, duration: 0.2)
            ])
            node.runAction(flash)
        }
    }
}

// MARK: - Loading overlay

struct PanoramaBuildingView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.85))
            VStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Building panorama…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 200)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08)))
    }
}
