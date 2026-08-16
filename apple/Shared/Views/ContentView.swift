import SwiftUI

struct ContentView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var coreMessage: String = "Esperando acción..."
    @State private var dbStatus: String = "DB No inicializada"
    @State private var isHydrating: Bool = false
    @State private var isDBReady: Bool = false
    @State private var showMCPConfig: Bool = false
    @ObservedObject var brain = LocalBrain.shared
    @State private var showChat: Bool = false
    @State private var showTelemetry: Bool = false
    @State private var showAgentSettings: Bool = false
    
    // Patrones del "Anillo de Inteligencia" y "Flujo" a ignorar por defecto
    private let defaultIgnorePatterns = [
        "_memory.md", "_metadata.md", "_specs.md", "_lore.md",
        "00-Sistema", "01-Diario", "05-IA-Drafts",
        "agent.md", ".git", ".obsidian"
    ]

    var body: some View {
        if !workspaceManager.isAuthorized {
            VStack(spacing: 20) {
                HStack {
                    Image(systemName: "brain.head.profile")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                        .foregroundColor(.gray)
                    
                    Text("Vault System")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Spacer()
                }
                
                VStack(spacing: 15) {
                    Text("Privacidad por Diseño")
                        .font(.headline)
                    Text("Vault System requiere acceso explícito a tus carpetas para operar. Todo el procesamiento ocurre de forma local y segura.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 20)
                    
                    Button("Añadir mi primer Vault") {
                        workspaceManager.requestAccess()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(40)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.05)))
            }
            .padding(30)
            .frame(width: 550)
        } else {
            // El Editor principal ocupa todo el espacio disponible
            ZStack {
                ZStack(alignment: .bottomLeading) {
                    MainEditorView(
                        showChat: $showChat,
                        showTelemetry: $showTelemetry,
                        showAgentSettings: $showAgentSettings,
                        showMCPConfig: $showMCPConfig
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                    if brain.isDownloading {
                        VStack {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .controlSize(.small)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Descargando Cerebro Local (\(ModelManager.shared.downloadingModelID?.components(separatedBy: "/").last ?? "modelo local"))...")
                                        .font(.subheadline)
                                        .fontWeight(.bold)
                                        .foregroundColor(.primary)
                                    
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule()
                                                .fill(Color.secondary.opacity(0.2))
                                                .frame(height: 6)
                                            
                                            Capsule()
                                                .fill(LinearGradient(gradient: Gradient(colors: [.accentColor, .purple]), startPoint: .leading, endPoint: .trailing))
                                                .frame(width: geo.size.width * CGFloat(brain.downloadProgress), height: 6)
                                                .animation(.interactiveSpring(), value: brain.downloadProgress)
                                        }
                                    }
                                    .frame(height: 6)
                                }
                                
                                Text(String(format: "%.1f%%", brain.downloadProgress * 100))
                                    .font(.subheadline)
                                    .fontWeight(.bold)
                                    .foregroundColor(.accentColor)
                                    .frame(width: 50, alignment: .trailing)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial)
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.3), lineWidth: 1))
                            .shadow(color: .black.opacity(0.25), radius: 15, x: 0, y: 8)
                            .padding(.top, 16)
                            .padding(.horizontal, 20)
                            
                            Spacer()
                        }
                        .zIndex(50)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                
                if showMCPConfig {
                    ZStack {
                        Color.black.opacity(0.8)
                            .ignoresSafeArea()
                        
                        VStack(spacing: 0) {
                            HStack {
                                Spacer()
                                Button(action: {
                                    withAnimation { showMCPConfig = false }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 28))
                                        .foregroundColor(.white.opacity(0.8))
                                        .padding()
                                }
                                .buttonStyle(.plain)
                            }
                            
                            MCPAccessView()
                                .environmentObject(workspaceManager)
                                .padding()
                                .frame(width: 800, height: 650)
                                .background(Color(NSColor.windowBackgroundColor))
                                .cornerRadius(16)
                                .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 10)
                            
                            Spacer()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(100)
                    .transition(.opacity)
                }

            }
            .sheet(isPresented: $showAgentSettings) {
                AgentSettingsView().frame(width: 560, height: 820)
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(WorkspaceManager())
    }
}
