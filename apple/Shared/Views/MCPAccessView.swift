import SwiftUI

struct MCPAccessView: View {
    @State private var selectedTab: Int = 0
    @State private var tokens: [McpTokenRecord] = []
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Vault Config / Administrador MCP")
                .font(.title2)
                .bold()
                .padding(.top, 24)
                .padding(.bottom, 8)
            Picker("", selection: $selectedTab) {
                Text("Nuevo Acceso").tag(0)
                Text("Accesos Activos").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 350)
            .padding(.bottom, 8)
            
            if selectedTab == 0 {
                TokenCreateView(onTokenCreated: {
                    loadTokens()
                    selectedTab = 1
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TokenListView(tokens: $tokens)
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
                        
                        Text("Configuración JSON para el cliente:")
                            .font(.caption).bold()
                        TextEditor(text: .constant(getInstructions(token: token.tokenId)))
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
    
    private func getInstructions(token: String) -> String {
        """
        {
          "mcpServers": {
            "vault-system": {
              "command": "/Users/lsanmartin/dev/vault-system/target/release/vault_daemon",
              "args": [
                "--client-token",
                "\(token)"
              ]
            }
          }
        }
        """
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
