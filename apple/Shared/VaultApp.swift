import Combine
import AppKit
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
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspaceManager = WorkspaceManager.shared

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

            // Cargar tokens desde UserDefaults ANTES de iniciar el server MCP
            loadTokensFromUserDefaults()

            if let ws = workspace {
                runMcpServer(workspaceRoot: ws, tokenId: token)
            } else {
                fputs("Error: --workspace argument is required for MCP mode.\\n", stderr)
            }

            exit(0)
        }
        
        // Registrar listener para eventos de interfaz (FFI/MCP)
        registerUiListener(listener: AppUiActionListener())
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

                    if status.contains("Error CRITICO") {
                        let alert = NSAlert()
                        alert.messageText = "Error Crítico de Inicialización"
                        alert.informativeText = status
                        alert.alertStyle = .critical
                        alert.addButton(withTitle: "Entendido")
                        alert.runModal()
                    }

                    // Iniciar el Cognitive Daemon (Arquitectura Dual-Brain)
                    let daemonStatus = startCognitiveDaemon()
                    print("Daemon: \(daemonStatus)")

                    // Inicializar el Cerebro Local y disparar la digestión inicial
                    LocalBrain.shared.updatePendingCount()
                    LocalBrain.shared.startDigestion()

                    // Inicializar Observabilidad y Telemetría Nativa
                    _ = TelemetryManager.shared

                    // Cierre determinista movido a AppDelegate.applicationShouldTerminate
                    // (async + timeout, ver AppDelegate abajo). El observer síncrono de
                    // willTerminate cuelga el quit con git add masivo en iCloud.
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

class AppUiActionListener: UiActionListener {
    func createNote(title: String, content: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("UiCreateNote"),
                object: nil,
                userInfo: ["title": title, "content": content]
            )
        }
    }
    
    func openNote(path: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("UiOpenNote"),
                object: nil,
                userInfo: ["path": path]
            )
        }
    }
    
    func setEditorMode(mode: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("UiSetEditorMode"),
                object: nil,
                userInfo: ["mode": mode]
            )
        }
    }

    func chatReset() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("ChatReset"), object: nil)
        }
    }

    func chatClear() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("ChatClear"), object: nil)
        }
    }

    func chatCompact() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("ChatCompact"), object: nil)
        }
    }
}

/// Intercepta Cmd+Q para que el shutdown del workspace (consolidación + git snapshot)
/// corra en background con timeout. Antes corría síncrono en willTerminate y la app
/// se quedaba pegada: `git add -A` indexaba ~93K untracked en iCloud.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let replyLock = NSLock()
    private var didReply = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Política por defecto: al cerrar la app, el chat local queda desactivado.
        // setEnabled(false) persiste vault_brain_enabled=false en UserDefaults y libera
        // el modelo de la GPU, de modo que cada lanzamiento arranca con el chat local
        // apagado; el usuario lo activa manualmente cuando lo necesite.
        LocalBrain.shared.setEnabled(false)

        let locations = WorkspaceManager.shared.allLocations
        guard !locations.isEmpty else { return .terminateNow }

        print("[OnStop] Iniciando cierre determinista (async)...")
        // Timeout de seguridad: el quit nunca debe colgarse, aunque el shutdown tarde.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak sender] in
            guard let sender else { return }
            self.replyOnce(sender, true)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            for location in locations {
                let result = shutdownVaultSession(workspacePath: location.path)
                print("[OnStop] \(location.name): \(result)")
            }
            DispatchQueue.main.async { [weak sender] in
                guard let sender else { return }
                self.replyOnce(sender, true)
            }
        }
        return .terminateLater
    }

    /// reply(toApplicationShouldTerminate:) debe llamarse exactamente una vez.
    private func replyOnce(_ sender: NSApplication, _ shouldTerminate: Bool) {
        replyLock.lock()
        if !didReply {
            didReply = true
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        replyLock.unlock()
    }
}

