import ARKit
import SceneKit
import SwiftUI

/// Camera full screen with the live LiDAR points on top.
private struct ARViewContainer: UIViewRepresentable {
    let capture: CaptureSession

    final class Coordinator { let overlay = PointOverlay() }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = capture.session
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        view.scene.rootNode.addChildNode(context.coordinator.overlay.node)
        let overlay = context.coordinator.overlay
        capture.onFrame = { frame in overlay.update(frame: frame) }
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct LiveView: View {
    @ObservedObject var capture: CaptureSession
    @State private var mode = CaptureSession.Mode.continuous

    var body: some View {
        ZStack {
            ARViewContainer(capture: capture).ignoresSafeArea()
            VStack(spacing: 8) {
                topBar
                Spacer()
                bottomControls
            }
            .padding()
        }
        .onAppear { capture.preview() }
    }

    private var topBar: some View {
        VStack(spacing: 2) {
            HStack(spacing: 16) {
                Label("\(capture.frameCount)", systemImage: "photo")
                Label("\(capture.reliablePointsPercent)%", systemImage: "dot.radiowaves.left.and.right")
                Label("\(capture.fps) fps", systemImage: "speedometer")
            }
            .font(.headline.monospacedDigit())
            Text("Tracking: \(capture.trackingText) · esposizione \(capture.exposureText)").font(.caption.monospacedDigit())
            Text("Ultima foto: \(capture.lastImageInfo)").font(.caption.monospacedDigit())
            if let e = capture.lastError { Text(e).font(.caption).foregroundColor(.red) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var bottomControls: some View {
        VStack(spacing: 12) {
            Picker("Modalità", selection: $mode) {
                ForEach(CaptureSession.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(capture.isRunning)
            .frame(maxWidth: 280)

            Button {
                capture.isRunning ? capture.stop() : capture.start(mode: mode)
            } label: {
                ZStack {
                    Circle().strokeBorder(.white, lineWidth: 4).frame(width: 76, height: 76)
                    RoundedRectangle(cornerRadius: capture.isRunning ? 6 : 30)
                        .fill(.red)
                        .frame(width: capture.isRunning ? 32 : 60, height: capture.isRunning ? 32 : 60)
                }
            }
            Text(capture.isRunning ? capture.sessionName : "Pronto").font(.caption).foregroundColor(.white)
        }
    }
}
