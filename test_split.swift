import SwiftUI

struct ContentView: View {
    @State private var isZen = false
    var body: some View {
        NavigationSplitView {
            if !isZen {
                Text("Sidebar")
            }
        } content: {
            if !isZen {
                Text("Content")
            }
        } detail: {
            VStack {
                Text("Detail")
                Button("Toggle Zen") { isZen.toggle() }
            }
        }
    }
}
