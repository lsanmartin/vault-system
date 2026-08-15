import SwiftUI

struct MCPAccessView: View {
    @State private var selectedTab: Int = 0
    @State private var tokens: [McpTokenRecord] = []

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
                ModelManagerView()
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

    // Lectura
    @State private var readContent: Bool = true
    @State private var readMetadata: Bool = true
    @State private var readSystem: Bool = false
    @State private var readTelemetry: Bool = false

    // Escritura
    @State private var writeContent: Bool = false
    @State private var writeMetadata: Bool = false
    @State private var writeSystem: Bool = false

    @State private var generatedToken: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Genera un acceso cerrado para asistentes IA. Define workspace, permisos de lectura y escritura.")
                .foregroundColor(.secondary)

            ScrollView {
                Form {
                    Section(header: Text("Detalles del Cliente")) {
                        TextField("Nombre del Cliente (ej. Claude Desktop)", text: $clientName)
                    }

                    Section(header: HStack {
                        Text("Workspace y Carpeta")
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
                                        if isOn { selectedWorkspaces.insert(location.path) }
                                        else { selectedWorkspaces.remove(location.path) }
                                    }
                                ))
                            }
                            ForEach(customWorkspaces, id: \.self) { path in
                                Toggle((path as NSString).lastPathComponent + " (Custom)", isOn: Binding(
                                    get: { selectedWorkspaces.contains(path) },
                                    set: { isOn in
                                        if isOn { selectedWorkspaces.insert(path) }
                                        else { selectedWorkspaces.remove(path) }
                                    }
                                ))
                            }
                        }
                        .frame(height: 100)
                    }

                    Section(header: Text("Permisos de Lectura")) {
                        Toggle("Contenido de notas (raw .md)", isOn: $readContent)
                        Toggle("Metadatos (_memory, _specs, _lore)", isOn: $readMetadata)
                        Toggle("Contexto de sistema (system_workspace)", isOn: $readSystem)
                        Toggle("Telemetría", isOn: $readTelemetry)
                    }

                    Section(header: Text("Permisos de Escritura")) {
                        Toggle("Crear / modificar notas", isOn: $writeContent)
                        Toggle("Gestionar metadatos (_memory, _specs, _lore)", isOn: $writeMetadata)
                        Toggle("Gestionar contexto de sistema", isOn: $writeSystem)
                        Text("⛔ La telemetría es de solo lectura. No se puede modificar.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .frame(maxHeight: 520)
            }

            Button(action: generateToken) {
                Text("Generar Token de Acceso Seguro")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(clientName.isEmpty || selectedWorkspaces.isEmpty)
        }
        .padding()
        .onAppear {
            selectedWorkspaces = Set(workspaceManager.locations.map { $0.path })
        }
    }

    private func generateToken() {
        let wsList = Array(selectedWorkspaces)

        _ = createMcpToken(
            clientName: clientName,
            workspaces: wsList,
            allowedPaths: [],
            readContent: readContent,
            readMetadata: readMetadata,
            readSystem: readSystem,
            readTelemetry: readTelemetry,
            writeContent: writeContent,
            writeMetadata: writeMetadata,
            writeSystem: writeSystem
        )
        syncTokensToUserDefaults()
        onTokenCreated()

        // Reset form
        clientName = ""
        readContent = true; readMetadata = true; readSystem = false; readTelemetry = false
        writeContent = false; writeMetadata = false; writeSystem = false
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
                        
                        HStack(spacing: 6) {
                            PermissionBadge(title: "Notas", allowed: token.readContent)
                            PermissionBadge(title: "Meta", allowed: token.readMetadata)
                            PermissionBadge(title: "Sistema", allowed: token.readSystem)
                            PermissionBadge(title: "Telem", allowed: token.readTelemetry)
                        }
                        HStack(spacing: 6) {
                            PermissionBadge(title: "W:Notas", allowed: token.writeContent)
                            PermissionBadge(title: "W:Meta", allowed: token.writeMetadata)
                            PermissionBadge(title: "W:Sis", allowed: token.writeSystem)
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

struct MCPAccessView_Previews: PreviewProvider {
    static var previews: some View {
        MCPAccessView()
    }
}
