import SwiftUI

struct MCPAccessView: View {
    @State private var selectedTab: Int = 0
    @State private var tokens: [McpTokenRecord] = []
    @ObservedObject var brain = LocalBrain.shared
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Vault System — Configuración de Inteligencia")
                .font(.title2)
                .bold()
                .padding(.top, 24)
                .padding(.bottom, 8)
            Picker("", selection: $selectedTab) {
                Text("Nuevo Acceso").tag(0)
                Text("Accesos Activos").tag(1)
                Text("Cerebro Local").tag(2)
            }
            .pickerStyle(.segmented)
            .frame(width: 450)
            .padding(.bottom, 8)
            
            if selectedTab == 0 {
                TokenCreateView(onTokenCreated: {
                    loadTokens()
                    selectedTab = 1
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedTab == 1 {
                TokenListView(tokens: $tokens)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LocalBrainConfigView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { loadTokens() }
    }
    
    private func loadTokens() {
        // Obtenemos los tokens de la capa de Rust (FFI)
        self.tokens = getMcpTokens()
    }
}

struct TokenCreateView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    var onTokenCreated: () -> Void
    
    @State private var clientName: String = ""
    @State private var selectedWorkspaces: Set<String> = []
    @State private var customWorkspaces: [String] = []
    @State private var canWrite: Bool = false
    @State private var allowMetadata: Bool = false
    @State private var allowSystem: Bool = false
    @State private var generatedToken: String? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Genera un acceso cerrado para asistentes IA locales.")
                .foregroundColor(.secondary)
            
            Form {
                Section(header: Text("Detalles del Cliente")) {
                    TextField("Nombre del Cliente (ej. Claude Desktop)", text: $clientName)
                }
                
                Section(header: HStack {
                    Text("Workspaces Autorizados")
                    Spacer()
                    Button(action: selectCustomFolder) {
                        Image(systemName: "folder.badge.plus")
                        Text("Añadir Otra")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .font(.caption)
                }) {
                    List {
                        ForEach(workspaceManager.locations) { location in
                            Toggle(location.name, isOn: Binding(
                                get: { selectedWorkspaces.contains(location.path) },
                                set: { isOn in
                                    if isOn {
                                        selectedWorkspaces.insert(location.path)
                                    } else {
                                        selectedWorkspaces.remove(location.path)
                                    }
                                }
                            ))
                        }
                        
                        ForEach(customWorkspaces, id: \.self) { path in
                            let folderName = (path as NSString).lastPathComponent
                            Toggle(folderName + " (Custom)", isOn: Binding(
                                get: { selectedWorkspaces.contains(path) },
                                set: { isOn in
                                    if isOn {
                                        selectedWorkspaces.insert(path)
                                    } else {
                                        selectedWorkspaces.remove(path)
                                    }
                                }
                            ))
                        }
                    }
                    .frame(height: 120)
                }
                
                Section(header: Text("Permisos de Seguridad")) {
                    Toggle("Permitir Escritura (Crear/Modificar notas)", isOn: $canWrite)
                    Toggle("Permitir Editar Metadatos Cognitivos (Capas /_)", isOn: $allowMetadata)
                    Toggle("Permitir Editar Contexto de Sistema (system_workspace)", isOn: $allowSystem)
                }
            }
            .frame(maxHeight: 400)
            
            Button(action: generateToken) {
                Text("Generar Token de Acceso Seguro")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(clientName.isEmpty || selectedWorkspaces.isEmpty)
            
            Spacer()
        }
        .padding()
        .onAppear {
            // Preseleccionar todos por defecto
            selectedWorkspaces = Set(workspaceManager.locations.map { $0.path })
        }
    }
    
    private func generateToken() {
        let wsList = Array(selectedWorkspaces)
        
        _ = createMcpToken(
            clientName: clientName,
            workspaces: wsList,
            canWrite: canWrite,
            allowMetadata: allowMetadata,
            allowSystem: allowSystem
        )
        syncTokensToUserDefaults()
        onTokenCreated()
        
        // Reset form
        clientName = ""
        canWrite = false
        allowMetadata = false
        allowSystem = false
        selectedWorkspaces = Set(workspaceManager.locations.map { $0.path })
        customWorkspaces.removeAll()
    }
    
    private func selectCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Añadir al MCP"
        
        if panel.runModal() == .OK {
            for url in panel.urls {
                let path = url.path
                if !customWorkspaces.contains(path) {
                    customWorkspaces.append(path)
                    selectedWorkspaces.insert(path)
                }
            }
        }
    }
}

struct TokenListView: View {
    @Binding var tokens: [McpTokenRecord]
    
    var body: some View {
        VStack(alignment: .leading) {
            if tokens.isEmpty {
                Text("No hay accesos MCP configurados.")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                List(tokens, id: \.tokenId) { token in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(token.clientName)
                                .font(.headline)
                            Spacer()
                            Text(token.tokenId)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Button(role: .destructive) {
                                let success = revokeMcpToken(tokenId: token.tokenId)
                                if success {
                                    syncTokensToUserDefaults()
                                    self.tokens = getMcpTokens()
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 8)
                        }
                        
                        Text("Workspaces: \(token.workspaces.joined(separator: ", "))")
                            .font(.caption)
                        
                        HStack(spacing: 12) {
                            PermissionBadge(title: "Escritura", allowed: token.canWrite)
                            PermissionBadge(title: "Metadatos", allowed: token.allowMetadata)
                            PermissionBadge(title: "Contexto de Sistema", allowed: token.allowSystem)
                        }
                        
                        Divider().padding(.vertical, 4)
                        
                        HStack {
                            Text("Configuración JSON para el cliente:")
                                .font(.caption).bold()
                            Spacer()
                            Button(action: {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString(getInstructions(token: token), forType: .string)
                            }) {
                                Label("Copiar", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            
                            Button(action: { exportConfig(token: token) }) {
                                Label("Exportar JSON", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                        
                        TextEditor(text: .constant(getInstructions(token: token)))
                            .font(.system(.footnote, design: .monospaced))
                            .frame(height: 120)
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func getInstructions(token: McpTokenRecord) -> String {
        let wsPath = token.workspaces.first ?? "/Users/lsanmartin/obsidian"
        return """
        {
          "mcpServers": {
            "vault-system": {
              "command": "/Applications/VaultSystem.app/Contents/MacOS/VaultSystem",
              "args": [
                "--mcp",
                "--token=\(token.tokenId)",
                "--workspace=\(wsPath)"
              ]
            }
          }
        }
        """
    }
    
    private func exportConfig(token: McpTokenRecord) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "claude_desktop_config.json"
        panel.prompt = "Guardar Configuración"
        
        if panel.runModal() == .OK, let url = panel.url {
            let configString = getInstructions(token: token)
            try? configString.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct PermissionBadge: View {
    let title: String
    let allowed: Bool
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: allowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(allowed ? .green : .red)
                .font(.caption)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// Vista de control y descarga del Cerebro Local Gemma
struct LocalBrainConfigView: View {
    @ObservedObject var brain = LocalBrain.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cerebro Local (Gemma 4)")
                    .font(.headline)
                Text("Inferencia y procesamiento on-device 100% nativo sobre Metal/GPU, sin conexión a servidores externos para máxima privacidad.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 10)
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Modelo Configurado:")
                        .bold()
                    Spacer()
                    Text("mlx-community/gemma-4-12B-it-4bit")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.accentColor)
                }
                
                HStack {
                    Text("Tamaño del Modelo:")
                        .bold()
                    Spacer()
                    Text("7.7 GB (Quantized 4-bit)")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Estado de Carga:")
                        .bold()
                    Spacer()
                    if brain.isDownloading {
                        Text("Descargando pesos...")
                            .foregroundColor(.orange)
                            .bold()
                    } else if brain.modelStatus == .ready || brain.downloadProgress == 1.0 {
                        Text("Listo en Caché ✔️")
                            .foregroundColor(.green)
                            .bold()
                    } else {
                        Text("No Inicializado / Pendiente")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(16)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)
            
            if brain.isDownloading {
                VStack(spacing: 8) {
                    ProgressView(value: brain.downloadProgress, total: 1.0)
                        .progressViewStyle(.linear)
                    
                    HStack {
                        Text("Descargando de Hugging Face...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.1f%%", brain.downloadProgress * 100))
                            .font(.caption)
                            .bold()
                            .foregroundColor(.accentColor)
                    }
                    
                    Button(action: {
                        brain.cancelDownload()
                    }) {
                        Label("Cancelar Descarga", systemImage: "xmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                    .controlSize(.regular)
                    .padding(.top, 6)
                }
                .padding(.vertical, 10)
            } else {
                Button(action: {
                    brain.preloadModel()
                }) {
                    Label(brain.downloadProgress == 1.0 ? "Re-descargar / Forzar Carga" : "Descargar e Inicializar Modelo Local", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

struct MCPAccessView_Previews: PreviewProvider {
    static var previews: some View {
        MCPAccessView()
    }
}
