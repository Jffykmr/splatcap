import ARKit
import SplatcapCore
import SwiftUI

struct ContentView: View {
    private let hasLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    @StateObject private var capture = CaptureSession()
    @State private var mode = CaptureSession.Mode.continuous

    var body: some View {
        VStack(spacing: 12) {
            Text("Splatcap \(SplatcapCore.version)").font(.title)
            Text("LiDAR: \(hasLiDAR ? "sì" : "no")")

            Picker("Modalità", selection: $mode) {
                ForEach(CaptureSession.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(capture.isRunning)

            Button(capture.isRunning ? "Ferma" : "Avvia cattura") {
                capture.isRunning ? capture.stop() : capture.start(mode: mode)
            }
            .buttonStyle(.borderedProminent)
            .tint(capture.isRunning ? .red : .blue)

            VStack(alignment: .leading, spacing: 4) {
                Text("Sessione: \(capture.sessionName)")
                Text("Foto salvate: \(capture.frameCount)")
                Text("Ultima foto: \(capture.lastImageInfo)")
                Text("Fotogrammi/s ARKit: \(capture.fps)")
                Text("Punti LiDAR affidabili: \(capture.reliablePointsPercent)%")
                Text("Tracking: \(capture.trackingText)")
                if capture.detailBlockMs > 0 { Text("Blocco in Dettaglio: \(capture.detailBlockMs) ms") }
                if let e = capture.lastError { Text(e).foregroundColor(.red) }
            }
            .font(.callout.monospacedDigit())
        }
        .padding()
    }
}
