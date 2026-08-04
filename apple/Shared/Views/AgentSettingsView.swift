import SwiftUI

struct AgentSettingsView: View {
    @ObservedObject private var manager = ExternalAgentManager.shared
    @State private var showForm = false
    @State private var editTarget: ExternalAgentConfig? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Agentes Externos", systemImage: "brain.head.profile")
                    .font(.title2).bold()
                Spacer()
                Button(action: { editTarget = nil; showForm = true }) {
                    Label("Agregar", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            if manager.agents.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "brain")
                        .font(.system(size: 40)).foregroundColor(.secondary)
                    Text("Sin agentes externos").font(.headline)
                    Text("Agrega una IA externa (DeepSeek, Anthropic, OpenAI)\ncon permisos controlados vía token MCP.")
                        .multilineTextAlignment(.center).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(manager.agents) { agent in
                        AgentRow(agent: agent)
                            .contentShape(Rectangle())
                            .onTapGesture { editTarget = agent; showForm = true }
                    }
                    .onDelete { indexSet in
                        for idx in indexSet { manager.removeAgent(manager.agents[idx]) }
                    }
                }
            }
        }
        .sheet(isPresented: $showForm) {
            AgentFormView(
                manager: manager,
                isPresented: $showForm,
                editAgent: editTarget
            )
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

// MARK: - Row

struct AgentRow: View {
    let agent: ExternalAgentConfig

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: providerIcon)
                .font(.title2).foregroundColor(providerColor).frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(agent.name).font(.headline)
                Text("\(agent.provider.rawValue) · \(agent.model)")
                    .font(.caption).foregroundColor(.secondary)
                Text(agent.workspaces.joined(separator: ", "))
                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 4) {
                PermissionBadge(title: "R", allowed: agent.readContent)
                PermissionBadge(title: "M", allowed: agent.readMetadata)
                PermissionBadge(title: "T", allowed: agent.readTelemetry)
                if agent.writeContent || agent.writeMetadata || agent.writeSystem {
                    PermissionBadge(title: "W", allowed: true)
                }
            }
            Button(action: { ExternalAgentManager.shared.removeAgent(agent) }) {
                Image(systemName: "trash").font(.caption).foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help("Eliminar agente")
        }
        .padding(.vertical, 4)
    }

    var providerIcon: String {
        switch agent.provider {
        case .deepseek: return "d.square"
        case .anthropic: return "a.square"
        case .openai: return "o.square"
        }
    }
    var providerColor: Color {
        switch agent.provider {
        case .deepseek: return .blue
        case .anthropic: return .orange
        case .openai: return .green
        }
    }
}

// MARK: - Form (Add / Edit)

struct AgentFormView: View {
    @ObservedObject var manager: ExternalAgentManager
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @Binding var isPresented: Bool
    var editAgent: ExternalAgentConfig?

    @State private var name = ""
    @State private var provider: ExternalAgentProvider = .deepseek
    @State private var apiKey = ""
    @State private var selectedWorkspaces: Set<String> = []
    @State private var customWorkspaces: [String] = []
    @State private var modelOverride = ""

    @State private var readContent = false
    @State private var readMetadata = true
    @State private var readSystem = false
    @State private var readTelemetry = true

    @State private var writeContent = false
    @State private var writeMetadata = false
    @State private var writeSystem = false

    var isEditing: Bool { editAgent != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "Editar Agente Externo" : "Nuevo Agente Externo").font(.title3).bold()
                Spacer()
                Button("Cancelar") { isPresented = false }.keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Nombre").font(.headline)
                            TextField("Ej: DeepSeek — Planner", text: $name).textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Proveedor").font(.headline)
                            Picker("Proveedor", selection: $provider) {
                                ForEach(ExternalAgentProvider.allCases, id: \.self) { p in Text(p.rawValue).tag(p) }
                            }.pickerStyle(.segmented)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("API Key").font(.headline)
                            SecureField(isEditing ? "•••••• (dejar vacío para mantener)" : "sk-...", text: $apiKey).textFieldStyle(.roundedBorder)
                            Text("Se guarda en el Keychain de macOS, nunca en disco.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Modelo (opcional)").font(.headline)
                            TextField(provider.defaultModel, text: $modelOverride).textFieldStyle(.roundedBorder)
                        }
                    }

                    Divider()

                    // Workspace
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Workspace y Carpeta").font(.headline)
                            Spacer()
                            Button(action: selectCustomFolder) {
                                Image(systemName: "folder.badge.plus"); Text("Añadir Otra")
                            }.buttonStyle(.plain).foregroundColor(.accentColor).font(.caption)
                        }
                        List {
                            let sysPath = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent(".vault_system/system_workspace").path
                            Toggle("⚙️ System Workspace (contexto de sistema)", isOn: Binding(
                                get: { selectedWorkspaces.contains(sysPath) },
                                set: { isOn in
                                    if isOn { selectedWorkspaces.insert(sysPath) }
                                    else { selectedWorkspaces.remove(sysPath) }
                                }
                            ))
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
                        }.frame(height: 120)
                    }

                    Divider()

                    Text("Permisos de Lectura").font(.headline)
                    Toggle("Contenido de notas (raw .md)", isOn: $readContent)
                    Toggle("Metadatos (_memory, _specs, _lore)", isOn: $readMetadata)
                    Toggle("Contexto de sistema (system_workspace)", isOn: $readSystem)
                    Toggle("Telemetría", isOn: $readTelemetry)

                    Divider()

                    Text("Permisos de Escritura").font(.headline)
                    Toggle("Crear / modificar notas", isOn: $writeContent)
                    Toggle("Gestionar metadatos (_memory, _specs, _lore)", isOn: $writeMetadata)
                    Toggle("Gestionar contexto de sistema", isOn: $writeSystem)

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Resumen de Acceso").font(.headline)
                        HStack(spacing: 6) {
                            PermissionBadge(title: "R", allowed: readContent)
                            PermissionBadge(title: "M", allowed: readMetadata)
                            PermissionBadge(title: "S", allowed: readSystem)
                            PermissionBadge(title: "T", allowed: readTelemetry)
                            PermissionBadge(title: "W", allowed: writeContent || writeMetadata || writeSystem)
                        }
                        Text("\(selectedWorkspaces.count) workspace(s) seleccionados")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }.padding()
            }

            Divider()

            HStack {
                if isEditing {
                    Button(role: .destructive) {
                        if let a = editAgent { manager.removeAgent(a) }
                        isPresented = false
                    } label: { Label("Eliminar", systemImage: "trash") }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button(isEditing ? "Guardar Cambios" : "Agregar Agente") {
                    save()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled((!isEditing && apiKey.trimmingCharacters(in: .whitespaces).isEmpty) || selectedWorkspaces.isEmpty)
                .keyboardShortcut(.defaultAction)
            }.padding()
        }
        .frame(width: 560, height: 820)
        .onAppear { loadEditValues() }
    }

    private func loadEditValues() {
        let allPaths = Set(workspaceManager.locations.map { $0.path })
        if let a = editAgent {
            name = a.name
            provider = a.provider
            modelOverride = a.model
            selectedWorkspaces = Set(a.workspaces)
            readContent = a.readContent; readMetadata = a.readMetadata
            readSystem = a.readSystem; readTelemetry = a.readTelemetry
            writeContent = a.writeContent; writeMetadata = a.writeMetadata
            writeSystem = a.writeSystem
        } else {
            selectedWorkspaces = allPaths
        }
    }

    private func save() {
        let ws = Array(selectedWorkspaces)
        let model = modelOverride.trimmingCharacters(in: .whitespaces).isEmpty
            ? provider.defaultModel : modelOverride.trimmingCharacters(in: .whitespaces)
        let agentName = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Agente \(provider.rawValue)" : name.trimmingCharacters(in: .whitespaces)
        let key = apiKey.trimmingCharacters(in: .whitespaces)

        if let existing = editAgent {
            // Editar: preservar API key si no se ingresó una nueva
            let finalKey = key.isEmpty ? (manager.getAPIKey(for: existing.id) ?? "") : key
            manager.removeAgent(existing)
            manager.addAgent(
                name: agentName, provider: provider, apiKey: finalKey,
                workspaces: ws,
                readContent: readContent, readMetadata: readMetadata,
                readSystem: readSystem, readTelemetry: readTelemetry,
                writeContent: writeContent, writeMetadata: writeMetadata,
                writeSystem: writeSystem
            )
        } else {
            manager.addAgent(
                name: agentName, provider: provider, apiKey: key,
                workspaces: ws,
                readContent: readContent, readMetadata: readMetadata,
                readSystem: readSystem, readTelemetry: readTelemetry,
                writeContent: writeContent, writeMetadata: writeMetadata,
                writeSystem: writeSystem
            )
        }
    }

    private func selectCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true; panel.prompt = "Añadir"
        if panel.runModal() == .OK {
            for url in panel.urls {
                let p = url.path
                if !customWorkspaces.contains(p) {
                    customWorkspaces.append(p)
                    selectedWorkspaces.insert(p)
                }
            }
        }
    }
}
