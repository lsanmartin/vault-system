import SwiftUI

@main
struct VaultApp: App {
    @StateObject private var workspaceManager = WorkspaceManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
                .environmentObject(workspaceManager)
        }
        // Ocultar la barra de título en macOS para un look más moderno
        .windowStyle(HiddenTitleBarWindowStyle())
    }
}
