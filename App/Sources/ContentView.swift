import SwiftUI

struct ContentView: View {
    @StateObject private var capture = CaptureSession()

    var body: some View {
        LiveView(capture: capture)
    }
}
