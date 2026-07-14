import Combine
import SwiftUI

func loadTokensFromUserDefaults() {
    if let json = UserDefaults.standard.string(forKey: "mcp_tokens_json") {
        _ = loadMcpTokensFromJson(jsonStr: json)
    }
}

func syncTokensToUserDefaults() {
    let json = exportMcpTokensToJson()
    UserDefaults.standard.set(json, forKey: "mcp_tokens_json")
}

@main
struct VaultApp: App {
    @StateObject private var workspaceManager = WorkspaceManager()

    init() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--mcp") {
            var token: String? = nil
            var workspace: String? = nil
            
            for arg in args {
                if arg.hasPrefix("--token=") {
                    token = String(arg.dropFirst("--token=".count))
                } else if arg.hasPrefix("--workspace=") {
                    workspace = String(arg.dropFirst("--workspace=".count))
                }
            }
            
            if let ws = workspace {
                runMcpServer(workspaceRoot: ws, tokenId: token)
            } else {
                fputs("Error: --workspace argument is required for MCP mode.\\n", stderr)
            }
            
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
                .environmentObject(workspaceManager)
                .onAppear {
                    // Cargar tokens persistidos antes de iniciar el daemon
                    loadTokensFromUserDefaults()
                    
                    // Inicializar el Exocórtex (Fase 4)
                    let status = initKnowledgeBase()
                    print("Vault Core Status: \(status)")
                    
                    // Iniciar el Cognitive Daemon (Arquitectura Dual-Brain)
                    let daemonStatus = startCognitiveDaemon()
                    print("Daemon: \(daemonStatus)")
                    
                    // Inicializar Observabilidad y Telemetría Nativa
                    _ = TelemetryManager.shared
                }
                .onOpenURL { url in
                    if workspaceManager.verifyAndResolveWorkspace(for: url) {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("OpenWorkspaceFile"),
                            object: nil,
                            userInfo: ["url": url]
                        )
                    } else {
                        let alert = NSAlert()
                        alert.messageText = "Acceso No Autorizado"
                        alert.informativeText = "El archivo no pertenece a ningún Workspace (Vault) autorizado. Añade la carpeta padre al Vault primero."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "Entendido")
                        alert.runModal()
                    }
                }
        }
        // Ocultar la barra de título en macOS para un look más moderno
        .windowStyle(HiddenTitleBarWindowStyle())
    }
}


class TelemetryManager {
    static let shared = TelemetryManager()
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        setupSubscriptions()
    }
    
    func setupSubscriptions() {
        // Suscribirse a remociones de workspace
        NotificationCenter.default.publisher(for: Notification.Name("WorkspaceRemoved"))
            .sink { notification in
                if let userInfo = notification.userInfo, let path = userInfo["path"] as? String {
                    _ = logFrictionEvent(
                        context: "Workspace",
                        action: "remove_location",
                        frictionDetail: "Usuario elimino el acceso al workspace en la ruta: \(path)"
                    )
                }
            }
            .store(in: &cancellables)
    }
    
    func logManualFriction(context: String, action: String, detail: String) {
        _ = logFrictionEvent(context: context, action: action, frictionDetail: detail)
    }
}
