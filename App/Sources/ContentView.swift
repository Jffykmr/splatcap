import ARKit
import SplatcapCore
import SwiftUI

struct ContentView: View {
    private let hasLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    var body: some View {
        VStack(spacing: 12) {
            Text("Splatcap \(SplatcapCore.version)").font(.title)
            Text("LiDAR: \(hasLiDAR ? "sì" : "no")").font(.title2)
        }
    }
}
