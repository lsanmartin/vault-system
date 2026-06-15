import SwiftUI

@main
struct VaultApp: App {
    @StateObject private var workspaceManager = WorkspaceManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
                .environmentObject(workspaceManager)
                .onAppear {
                    // Inicializar el Exocórtex (Fase 4)
                    let status = initKnowledgeBase()
                    print("Vault Core Status: \(status)")
                    
                    // Iniciar el Cognitive Daemon (Arquitectura Dual-Brain)
                    let daemonStatus = startCognitiveDaemon()
                    print("Daemon: \(daemonStatus)")
                }
        }
        // Ocultar la barra de título en macOS para un look más moderno
        .windowStyle(HiddenTitleBarWindowStyle())
    }
}
