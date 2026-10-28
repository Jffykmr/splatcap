import ARKit
import SceneKit
import SwiftUI

/// Camera full screen with the live LiDAR points on top.
private struct ARViewContainer: UIViewRepresentable {
    let capture: CaptureSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = capture.session
        view.automaticallyUpdatesLighting = false
        let overlay = PointOverlayView(frame: view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlay)
        capture.onFrame = { [weak overlay] frame in overlay?.update(frame: frame) }
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
        .onAppear { capture.preview(mode: mode) }
        .onChange(of: mode) { _, new in capture.preview(mode: new) }
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
            if capture.detailBlockMs > 0 { Text("Pausa dello scatto: \(capture.detailBlockMs) ms").font(.caption.monospacedDigit()) }
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
