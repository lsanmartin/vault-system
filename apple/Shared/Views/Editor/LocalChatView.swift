import SwiftUI
import Combine
import WebKit

struct LocalChatMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isUser: Bool
    let agentCode: String?
    let timestamp = Date()
    var type: String? = nil        // "tools" = colapsable de herramientas, nil = normal
    var toolNames: [String] = []   // nombres de tools usadas (solo type="tools")
    static func == (lhs: LocalChatMessage, rhs: LocalChatMessage) -> Bool { lhs.id == rhs.id }
}

struct LocalChatView: View {
    @ObservedObject var viewModel: EditorViewModel
    @StateObject private var brain = LocalBrain.shared
    @ObservedObject private var agentManager = ExternalAgentManager.shared
    @ObservedObject private var chatThreads = ChatThreadManager.shared

    @State private var messages: [LocalChatMessage] = []
    @State private var inputText: String = ""
    @State private var isGenerating: Bool = false
    @State private var generationTask: Task<Void, Never>? = nil
    @State private var selectedAgent: AgentChip = .local
    @State private var showAgentSettings = false

    enum AgentChip: Hashable {
        case local
        case external(ExternalAgentConfig)

        var displayName: String {
            switch self {
            case .local: return "Local"
            case .external(let a): return a.name
            }
        }

        var detailName: String {
            switch self {
            case .local: return "Gemma 4"
            case .external(let a): return a.provider.rawValue
            }
        }

        /// Código estable para DB (no cambia aunque el usuario renombre el agente)
        var agentCode: String {
            switch self {
            case .local: return "LC"
            case .external(let a): return "ext_\(a.id.prefix(8))"
            }
        }

        var color: Color {
            switch self {
            case .local: return .green
            case .external(let a):
                switch a.provider {
                case .deepseek: return .blue
                case .anthropic: return .orange
                case .openai: return .teal
                }
            }
        }
    }

    var chips: [AgentChip] {
        [.local] + agentManager.agents.map { .external($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                // Utilidades (izquierda)
                HStack(spacing: 8) {
                    // Toggle on/off para cualquier agente
                    Button(action: { toggleSelectedAgent() }) {
                        Image(systemName: isSelectedAgentEnabled ? "power.circle.fill" : "power")
                            .font(.system(size: 13))
                            .foregroundColor(isSelectedAgentEnabled ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isSelectedAgentEnabled ? "Desactivar \(selectedAgent.displayName)" : "Activar \(selectedAgent.displayName)")

                    Button(action: { showAgentSettings = true }) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("Configurar agentes externos")

                    Button(action: {
                        messages = [LocalChatMessage(text: "Chat reiniciado.", isUser: false, agentCode: selectedAgent.agentCode)]
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("/clear — Limpiar vista")
                }

                Spacer()

                // Agente activo
                HStack(spacing: 6) {
                    Circle()
                        .fill(selectedAgent.color)
                        .frame(width: 8, height: 8)
                    Text(selectedAgent.displayName)
                        .font(.headline).bold()
                    Text(selectedAgent.detailName)
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            // Barra de permisos
            PermissionsBar(agent: selectedAgent)
                .padding(.horizontal, 12).padding(.bottom, 4)
                .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Mensajes (NSTextView nativo para selección multi-burbuja)
            ChatMessagesView(messages: messages)
                .onChange(of: messages.count) { _ in
                    // scroll handled internally by NSTextView
                }

            Divider()

            // Píldoras de agentes
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(chips, id: \.self) { chip in
                            Button(action: { selectedAgent = chip }) {
                                HStack(spacing: 3) {
                                    Text(chip.displayName)
                                        .font(.caption).bold().monospaced()
                                }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(selectedAgent == chip ? chip.color : Color.secondary.opacity(0.1))
                                .foregroundColor(selectedAgent == chip ? .white : .primary)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 8)
                }
                .frame(height: 24)
            }
            .padding(.vertical, 4)
            .background(Color(NSColor.windowBackgroundColor))

            // Input
            HStack(alignment: .bottom, spacing: 8) {
                ChatInputView(text: $inputText, disabled: isGenerating || !isSelectedAgentEnabled, onCommit: send)
                    .frame(minHeight: 72, maxHeight: 240)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))

                if isGenerating {
                    Button(action: cancelGeneration) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title3).foregroundColor(.red)
                    }
                    .buttonStyle(.plain).help("Cancelar generación")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                            .foregroundColor(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? .secondary.opacity(0.3) : .accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isSelectedAgentEnabled)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 280, maxWidth: 550)
        .sheet(isPresented: $showAgentSettings) {
            AgentSettingsView()
                .frame(width: 560, height: 780)
        }
        .onAppear { loadThread(for: selectedAgent.agentCode, displayName: selectedAgent.displayName) }
        .onDisappear { saveCurrentThreadMessages() }
        .onChange(of: isGenerating) { _, generating in
            if !generating, let last = messages.last, !last.isUser {
                saveMessage(last)
            }
        }
        .onChange(of: selectedAgent) { oldValue, newValue in
            loadThread(for: newValue.agentCode, displayName: newValue.displayName)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ChatReset"))) { _ in
            createAnchorNote(for: selectedAgent)
            messages = [LocalChatMessage(text: "Sesión reiniciada. Ancla creada en _inbox/.", isUser: false, agentCode: selectedAgent.agentCode)]
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ChatClear"))) { _ in
            messages.removeAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ChatCompact"))) { _ in
            let summary = "Contexto compactado. \(messages.count) mensajes resumidos."
            messages = [LocalChatMessage(text: summary, isUser: false, agentCode: selectedAgent.agentCode)]
        }
    }

    // MARK: - Anchor

    private func createAnchorNote(for agent: AgentChip) {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HHmm"
        let ts = df.string(from: Date())
        let home = FileManager.default.homeDirectoryForCurrentUser
        let inboxPath = home.appendingPathComponent(".vault_system/system_workspace/_inbox").path
        try? FileManager.default.createDirectory(atPath: inboxPath, withIntermediateDirectories: true)
        let fileName = "chat_\(agent.displayName.replacingOccurrences(of: " ", with: "_"))_\(ts).md"
        let filePath = "\(inboxPath)/\(fileName)"

        let lastMsgs = messages.suffix(20).map { msg in
            let who = msg.isUser ? "**Tú**" : "**\(msg.agentCode ?? agent.displayName)**"
            return "\(who): \(msg.text)"
        }.joined(separator: "\n\n")

        let content = """
        ---
        agent: \(agent.displayName)
        date: \(ts)
        type: chat-anchor
        message_count: \(messages.count)
        ---

        # Chat \(agent.displayName) — \(ts)

        ## Últimos mensajes

        \(lastMsgs)

        ---
        *Ancla generada por /reset. La conversación continúa en un nuevo contexto.*
        """

        _ = saveNote(path: filePath, content: content)
        print("[Anchor] Creado: \(filePath)")
    }

    // MARK: - Thread Persistence

    private var currentThreadId: String {
        chatThreads.getOrCreateThread(for: selectedAgent.agentCode)
    }

    private func loadThread(for agentCode: String, displayName: String) {
        let tid = chatThreads.getOrCreateThread(for: agentCode)
        let msgs = chatThreads.toLocalMessages(threadId: tid)
        messages = msgs.isEmpty
            ? [LocalChatMessage(text: "Chat \(displayName) — Escribí tu mensaje.", isUser: false, agentCode: agentCode)]
            : msgs
    }

    private func saveMessage(_ msg: LocalChatMessage) {
        let tid = currentThreadId
        let role = msg.isUser ? "user" : "assistant"
        chatThreads.saveMessage(threadId: tid, role: role, agentCode: msg.agentCode, content: msg.text)
    }

    private func saveCurrentThreadMessages() {
        let tid = currentThreadId
        // Guardar los últimos 50 mensajes no guardados
        for msg in messages.suffix(50) {
            chatThreads.saveMessage(threadId: tid, role: msg.isUser ? "user" : "assistant", agentCode: msg.agentCode, content: msg.text)
        }
    }

    // MARK: - Agent Enable/Disable

    private var isSelectedAgentEnabled: Bool {
        switch selectedAgent {
        case .local: return brain.isEnabled
        case .external(let a): return UserDefaults.standard.bool(forKey: "agent_enabled_\(a.id)")
        }
    }

    private func toggleSelectedAgent() {
        switch selectedAgent {
        case .local:
            brain.setEnabled(!brain.isEnabled)
        case .external(let a):
            let newVal = !UserDefaults.standard.bool(forKey: "agent_enabled_\(a.id)")
            UserDefaults.standard.set(newVal, forKey: "agent_enabled_\(a.id)")
            // Refrescar UI
            selectedAgent = selectedAgent
        }
    }

    // MARK: - /plan

    private func runPlan(prompt: String, target: AgentChip) {
        guard isSelectedAgentEnabled else {
            messages.append(LocalChatMessage(text: "\(target.displayName) está desactivado.", isUser: false, agentCode: target.agentCode))
            return
        }
        inputText = ""
        let userMsg = LocalChatMessage(text: "/plan \(prompt)", isUser: true, agentCode: nil)
        messages.append(userMsg); saveMessage(userMsg)
        isGenerating = true

        let sysPrompt = "Eres un planificador de arquitectura de software. Tu tarea es generar un plan detallado paso a paso. NO modifiques ningún archivo. Usa las herramientas disponibles para explorar el vault, leer archivos relevantes y entender el contexto. Luego genera un plan con: 1) Objetivo, 2) Archivos a modificar/crear, 3) Pasos concretos, 4) Riesgos, 5) Esfuerzo estimado. Formato Markdown."

        generationTask = Task {
            await runWithPrompt(sysPrompt: sysPrompt, userPrompt: prompt, target: target, readOnly: true)
        }
    }

    // MARK: - /goal

    private func runGoal(prompt: String, target: AgentChip) {
        guard isSelectedAgentEnabled else {
            messages.append(LocalChatMessage(text: "\(target.displayName) está desactivado.", isUser: false, agentCode: target.agentCode))
            return
        }
        inputText = ""
        let userMsg = LocalChatMessage(text: "/goal \(prompt)", isUser: true, agentCode: nil)
        messages.append(userMsg); saveMessage(userMsg)
        isGenerating = true

        let sysPrompt = "Eres un ejecutor de tareas en un vault de conocimiento. Tu objetivo es completar la tarea asignada usando las herramientas MCP disponibles. Trabaja de forma autónoma: 1) Explora el contexto, 2) Planifica los pasos, 3) Ejecuta cada paso usando las herramientas (vault_write, vault_search, vault_read, etc.), 4) Verifica cada paso, 5) Reporta el resultado final. Si algo falla, reintenta con un enfoque diferente. Máximo 3 reintentos por paso."

        generationTask = Task {
            await runWithPrompt(sysPrompt: sysPrompt, userPrompt: prompt, target: target, readOnly: false)
        }
    }

    // MARK: - /design

    private func runDesign(prompt: String, target: AgentChip) {
        guard isSelectedAgentEnabled else {
            messages.append(LocalChatMessage(text: "\(target.displayName) está desactivado.", isUser: false, agentCode: target.agentCode))
            return
        }
        inputText = ""
        let userMsg = LocalChatMessage(text: "/design \(prompt)", isUser: true, agentCode: nil)
        messages.append(userMsg); saveMessage(userMsg)
        isGenerating = true

        let sysPrompt = "Eres un arquitecto de software. Genera un diagrama Mermaid que represente: \(prompt). Usa las herramientas para explorar el contexto si es necesario. Responde con el código Mermaid entre ```mermaid y ```. Usa graph TD o flowchart. Incluye componentes, conexiones y etiquetas descriptivas."

        generationTask = Task {
            await runWithPrompt(sysPrompt: sysPrompt, userPrompt: "Genera un diagrama Mermaid para: \(prompt)", target: target, readOnly: true)
        }
    }

    // MARK: - Shared execution

    private func runWithPrompt(sysPrompt: String, userPrompt: String, target: AgentChip, readOnly: Bool) async {
        switch target {
        case .local:
            // Local no tiene tool calling: fallback a chat normal con prompt combinado
            let combinedPrompt = "\(sysPrompt)\n\n---\n\n\(userPrompt)"
            sendLocal(prompt: combinedPrompt, context: "")
        case .external(let agent):
            await runExternalPlan(sysPrompt: sysPrompt, userPrompt: userPrompt, agent: agent)
        }
    }

    private func runExternalPlan(sysPrompt: String, userPrompt: String, agent: ExternalAgentConfig) async {
        guard let key = agentManager.getAPIKey(for: agent.id) else {
            await MainActor.run {
                messages.append(LocalChatMessage(text: "❌ Sin API key.", isUser: false, agentCode: agentCode(for: agent)))
                isGenerating = false
            }
            return
        }
        let code = agentCode(for: agent)

        let toolsJson = getAgentMcpTools(tokenId: agent.tokenId)
        let openaiTools = convertMcpToolsToOpenAI(toolsJson)

        var conversation: [[String: Any]] = [
            ["role": "system", "content": String(sysPrompt.prefix(3000))],
            ["role": "user", "content": userPrompt]
        ]
        var pendingTools: [String] = []

        for turn in 0..<5 {
            var result = await streamAPI(agent: agent, key: key, apiMessages: conversation, tools: openaiTools, code: code)
            // Reintentar errores de red (timeout, conexión perdida)
            if let error = result.error, (error.contains("Conexión perdida") || error.contains("Red:")) && turn < 3 {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                result = await streamAPI(agent: agent, key: key, apiMessages: conversation, tools: openaiTools, code: code)
            }
            if let error = result.error {
                await MainActor.run {
                    messages.append(LocalChatMessage(text: "❌ \(error)", isUser: false, agentCode: code))
                    isGenerating = false
                }
                return
            }
            guard let toolCalls = result.toolCalls, !toolCalls.isEmpty else {
                await flushPending(text: "", tools: pendingTools, code: code)
                await MainActor.run { isGenerating = false }
                return
            }
            pendingTools.append(contentsOf: toolCalls.map(\.name))
            var assistantMsg: [String: Any] = ["role": "assistant"]
            assistantMsg["tool_calls"] = toolCalls.map { tc in
                ["id": tc.id, "type": "function", "function": ["name": tc.name, "arguments": tc.args]] as [String: Any]
            }
            conversation.append(assistantMsg)
            for tc in toolCalls {
                var raw = mcpExecuteForAgent(jsonRequest: buildMcpRequest(tokenId: agent.tokenId, toolName: tc.name, arguments: tc.args))
                if raw.count > 1500 { raw = String(raw.prefix(1500)) + "\n…" }
                conversation.append(["role": "tool", "tool_call_id": tc.id, "content": raw])
            }
            let total = conversation.reduce(0) { $0 + (($1["content"] as? String)?.count ?? 0) }
            if total > 1_500_000 { conversation = [conversation[0], conversation[1]] + Array(conversation.suffix(6)) }
        }
        await flushPending(text: "", tools: pendingTools, code: code)
        await MainActor.run { isGenerating = false }
    }

    // MARK: - Cancel

    private func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        if selectedAgent == .local {
            brain.cancelChat()
        }
        isGenerating = false
        messages.append(LocalChatMessage(text: "⏹ Generación cancelada.", isUser: false, agentCode: selectedAgent.agentCode))
    }

    // MARK: - Send

    private func send() {
        let clean = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        // Detectar @mención
        var target = selectedAgent
        if let first = clean.split(separator: " ").first, first.hasPrefix("@") {
            let m = String(first.dropFirst()).lowercased()
            if m == "local" || m == "lc" { target = .local }
            else if let match = agentManager.agents.first(where: {
                $0.name.lowercased().replacingOccurrences(of: " ", with: "") == m
            }) { target = .external(match) }
        }

        // Comandos
        if clean == "/reset" {
            createAnchorNote(for: target)
            // Archivar thread actual y crear uno nuevo
            let tid = chatThreads.getOrCreateThread(for: target.agentCode)
            _ = chatDeleteThread(threadId: tid)
            chatThreads.loadThreads()
            let newTid = chatThreads.getOrCreateThread(for: target.agentCode)
            messages = [LocalChatMessage(text: "Sesión reiniciada. Ancla en _inbox/.", isUser: false, agentCode: target.agentCode)]
            inputText = ""; return
        }
        if clean == "/clear" {
            messages.removeAll()
            inputText = ""; return
        }
        if clean == "/compact" {
            let summary = "Contexto compactado. \(messages.count) mensajes resumidos."
            messages = [LocalChatMessage(text: summary, isUser: false, agentCode: target.agentCode)]
            inputText = ""; return
        }
        if clean.hasPrefix("/plan ") {
            let goal = String(clean.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            runPlan(prompt: goal, target: target); return
        }
        if clean.hasPrefix("/goal ") {
            let goal = String(clean.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            runGoal(prompt: goal, target: target); return
        }
        if clean.hasPrefix("/design ") {
            let goal = String(clean.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            runDesign(prompt: goal, target: target); return
        }

        guard isSelectedAgentEnabled else {
            messages.append(LocalChatMessage(text: "\(target.displayName) está desactivado.", isUser: false, agentCode: target.agentCode))
            return
        }

        let prompt = clean
        inputText = ""
        let userMsg = LocalChatMessage(text: prompt, isUser: true, agentCode: nil)
        messages.append(userMsg)
        saveMessage(userMsg)
        isGenerating = true

        var ctx = ""
        if let id = viewModel.activeTabId, let tab = viewModel.tabs.first(where: { $0.id == id }) {
            ctx = tab.content
        }

        generationTask = Task {
            switch target {
            case .local:
                sendLocal(prompt: prompt, context: ctx)
            case .external(let agent):
                sendExternal(prompt: prompt, agent: agent, context: ctx)
            }
        }
    }

    // MARK: - Local Brain

    private func sendLocal(prompt: String, context: String) {
        Task {
            do {
                let stream = try await brain.chatStream(prompt: prompt, context: context)
                let msg = LocalChatMessage(text: "", isUser: false, agentCode: "LC")
                await MainActor.run { messages.append(msg) }
                var acc = ""
                for await chunk in stream {
                    acc += chunk
                    await MainActor.run {
                        if let i = messages.indices.last { messages[i] = LocalChatMessage(text: acc, isUser: false, agentCode: "LC") }
                    }
                }
            } catch {
                await MainActor.run {
                    messages.append(LocalChatMessage(text: "❌ \(error.localizedDescription)", isUser: false, agentCode: "LC"))
                }
            }
            await MainActor.run { isGenerating = false }
        }
    }

    // MARK: - External API (con tool calling MCP real)

    private func sendExternal(prompt: String, agent: ExternalAgentConfig, context: String) {
        guard let key = agentManager.getAPIKey(for: agent.id) else {
            messages.append(LocalChatMessage(text: "❌ Sin API key en Keychain.", isUser: false, agentCode: agentCode(for: agent)))
            isGenerating = false; return
        }

        let code = agentCode(for: agent)
        let sys = String(buildSystemPrompt(agent: agent, context: context).prefix(3000))
        let toolsJson = getAgentMcpTools(tokenId: agent.tokenId)
        let openaiTools = convertMcpToolsToOpenAI(toolsJson)

        Task {
            // Construir conversación desde historial persistente + mensaje nuevo
            let tid = chatThreads.getOrCreateThread(for: selectedAgent.agentCode)
            var conversation = buildApiConversation(threadId: tid, sys: sys, newUserMsg: prompt)

            var pendingTools: [String] = []

            for turn in 0..<5 {
                let result = await streamAPI(agent: agent, key: key, apiMessages: conversation, tools: openaiTools, code: code)
                if let error = result.error {
                    await MainActor.run {
                        messages.append(LocalChatMessage(text: "❌ \(error)", isUser: false, agentCode: code))
                        isGenerating = false
                    }
                    return
                }

                guard let toolCalls = result.toolCalls, !toolCalls.isEmpty else {
                    // El streaming ya agregó el mensaje. Solo guardar.
                    if result.text != nil, !(result.text?.isEmpty ?? true) {
                        if let last = messages.last, !last.isUser { saveMessage(last) }
                    }
                    await flushPending(text: "", tools: pendingTools, code: code)
                    await MainActor.run { isGenerating = false }
                    return
                }

                pendingTools.append(contentsOf: toolCalls.map(\.name))

                var assistantMsg: [String: Any] = ["role": "assistant"]
                assistantMsg["tool_calls"] = toolCalls.map { tc in
                    ["id": tc.id, "type": "function", "function": ["name": tc.name, "arguments": tc.args]] as [String: Any]
                }
                // Preservar texto del assistant (DeepSeek reasoning_content equivalente)
                if let text = result.text, !text.isEmpty {
                    assistantMsg["content"] = text
                }
                conversation.append(assistantMsg)

                for tc in toolCalls {
                    var raw = mcpExecuteForAgent(jsonRequest: buildMcpRequest(tokenId: agent.tokenId, toolName: tc.name, arguments: tc.args))
                    if raw.count > 1500 { raw = String(raw.prefix(1500)) + "\n…" }
                    conversation.append(["role": "tool", "tool_call_id": tc.id, "content": raw])
                }

                // Sliding window: podar tool results viejos, preservar user messages
                conversation = pruneConversation(conversation)
            }

            // Max turns alcanzado: forzar resumen sin tools
            await flushPending(text: "", tools: pendingTools, code: code)
            if pendingTools.count > 0 {
                await MainActor.run {
                    let thinking = LocalChatMessage(text: "● Destilando hallazgos…", isUser: false, agentCode: code, type: "thinking")
                    messages.append(thinking)
                }
                conversation.append(["role": "user", "content": "Resumí en 3-5 bullets qué encontraste y proponé siguientes pasos. Sé conciso. NO te presentes. NO saludes."])
                let finalResult = await streamAPI(agent: agent, key: key, apiMessages: conversation, tools: [], code: code)
                // El streaming ya agregó el texto. Solo guardar.
                if finalResult.text != nil, !(finalResult.text?.isEmpty ?? true) {
                    if let last = messages.last, !last.isUser { saveMessage(last) }
                }
            }
            await MainActor.run { isGenerating = false }
        }
    }

    /// Construye el array de conversación para la API desde mensajes persistidos en DB
    private func buildApiConversation(threadId: String, sys: String, newUserMsg: String) -> [[String: Any]] {
        var conv: [[String: Any]] = [["role": "system", "content": sys]]
        let persisted = chatThreads.loadMessages(threadId: threadId, limit: 20)

        // Agregar historial previo (sin el último mensaje que es el nuevo user msg)
        let previousMsgs = persisted.dropLast()
        for msg in previousMsgs {
            switch msg.role {
            case "user":
                conv.append(["role": "user", "content": msg.content])
            case "assistant":
                conv.append(["role": "assistant", "content": msg.content])
            default:
                break
            }
        }

        // Agregar el nuevo mensaje del usuario (no duplicado)
        conv.append(["role": "user", "content": newUserMsg])
        return conv
    }

    /// Sliding window: mantiene system + user messages + últimos tool exchanges
    private func pruneConversation(_ conv: [[String: Any]]) -> [[String: Any]] {
        let total = conv.reduce(0) { $0 + (($1["content"] as? String)?.count ?? 0) }
        guard total > 200_000, conv.count >= 4 else { return conv }

        // Preservar system + user messages + últimos 4 mensajes
        let systemMsg = conv.first(where: { ($0["role"] as? String) == "system" })
        let userMsgs = conv.filter { ($0["role"] as? String) == "user" }
        let recent = conv.suffix(4)

        var result: [[String: Any]] = []
        if let sys = systemMsg { result.append(sys) }
        result.append(contentsOf: userMsgs.prefix(3)) // últimos 3 mensajes del usuario
        result.append(contentsOf: recent)
        return result
    }

    @MainActor
    private func updateMessage(at idx: Int, text: String, code: String) {
        messages[idx] = LocalChatMessage(text: text, isUser: false, agentCode: code)
    }

    @MainActor
    private func flushPending(text: String, tools: [String], code: String) {
        if !tools.isEmpty {
            var msg = LocalChatMessage(text: "🔧 \(tools.count) herramienta(s) usada(s)", isUser: false, agentCode: code, type: "tools")
            msg.toolNames = tools
            messages.append(msg)
            saveMessage(msg)
        }
        if !text.isEmpty {
            let msg = LocalChatMessage(text: text, isUser: false, agentCode: code)
            messages.append(msg)
            saveMessage(msg)
        }
    }

    private struct ToolCallResult { let id: String; let name: String; let args: String }
    private struct StreamResult { let text: String?; let toolCalls: [ToolCallResult]?; let error: String? }

    private func streamAPI(agent: ExternalAgentConfig, key: String, apiMessages: [[String: Any]], tools: [[String: Any]], code: String) async -> StreamResult {
        var req = URLRequest(url: URL(string: "\(agent.provider.baseURL)/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = ["model": agent.model, "messages": apiMessages, "stream": true]
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto" // DeepSeek: evitar que abandone tool calling
        }

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            return StreamResult(text: nil, toolCalls: nil, error: "Error serializando request")
        }
        req.httpBody = httpBody

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return StreamResult(text: nil, toolCalls: nil, error: "HTTP \( (response as? HTTPURLResponse)?.statusCode ?? 0)")
            }

            var streamedText = ""
            var msgIdx: Int? = nil
            var tcAccum: [Int: (id: String, name: String, args: String)] = [:]
            var finishReason: String? = nil

            for try await line in bytes.lines {
                guard line.hasPrefix("data: "), line != "data: [DONE]" else { continue }
                let jsonStr = String(line.dropFirst(6))
                guard let d = jsonStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let choices = obj["choices"] as? [[String: Any]],
                      let first = choices.first else { continue }

                let delta = first["delta"] as? [String: Any] ?? [:]
                finishReason = first["finish_reason"] as? String

                if let content = delta["content"] as? String, !content.isEmpty {
                    if let idx = msgIdx {
                        streamedText += content
                        await updateMessage(at: idx, text: streamedText, code: code)
                    } else {
                        streamedText = content
                        await MainActor.run {
                            messages.append(LocalChatMessage(text: content, isUser: false, agentCode: code))
                            msgIdx = messages.count - 1
                        }
                    }
                }

                if let tcDeltas = delta["tool_calls"] as? [[String: Any]] {
                    for tc in tcDeltas {
                        let idx = tc["index"] as? Int ?? 0
                        var cur = tcAccum[idx] ?? (id: "", name: "", args: "")
                        if let id = tc["id"] as? String { cur.id = id }
                        if let fn = tc["function"] as? [String: Any] {
                            if let n = fn["name"] as? String { cur.name = n }
                            if let a = fn["arguments"] as? String { cur.args += a }
                        }
                        tcAccum[idx] = cur
                    }
                }
            }

            let text = streamedText.isEmpty ? nil : streamedText
            let toolCalls: [ToolCallResult]? = if finishReason == "tool_calls", !tcAccum.isEmpty {
                tcAccum.values.sorted(by: { $0.id < $1.id }).map { ToolCallResult(id: $0.id, name: $0.name, args: $0.args) }
            } else { nil }

            return StreamResult(text: text, toolCalls: toolCalls, error: nil)
        } catch {
            let msg = error.localizedDescription
            if msg.contains("network connection was lost") || msg.contains("timeout") || msg.contains("Network") {
                return StreamResult(text: nil, toolCalls: nil, error: "Conexión perdida con \(agent.provider.rawValue). Reintentá en unos segundos.")
            }
            return StreamResult(text: nil, toolCalls: nil, error: "Red: \(msg)")
        }
    }

    private func buildSystemPrompt(agent: ExternalAgentConfig, context: String) -> String {
        var sys = "Eres \(agent.name), un asistente IA con acceso al Vault System.\n"

        // Inyectar conciencia.md (estado global)
        let concienciaPath = NSString(string: "~/.vault_system/system_workspace/00-Sistema/conciencia.md").expandingTildeInPath
        if let conciencia = try? String(contentsOfFile: concienciaPath, encoding: .utf8) {
            sys += "\n## Estado Global del Sistema\n\(conciencia.prefix(2000))\n"
        }

        sys += "Puedes usar herramientas MCP para leer, buscar, escribir y explorar el vault.\n"
        if agent.writeContent || agent.writeMetadata || agent.writeSystem {
            sys += "También puedes crear/modificar notas y metadatos.\n"
        }
        sys += "Cuando el usuario pida hacer algo, USA las herramientas disponibles. No digas 'no puedo' sin antes intentar.\n"
        sys += "\n⚠️ REGLA CRÍTICA: Después de usar herramientas, NUNCA te presentes ni saludes de nuevo.\n"
        sys += "Resumí brevemente lo que encontraste y proponé siguientes pasos. La conversación continúa.\n"
        sys += "No digas frases como 'listo para ayudarte', 'soy tu asistente', 'herramientas cargadas', etc.\n"

        // Gestión de contexto: scratchpad obligatorio
        sys += "\n## Reglas de Trabajo\n"
        sys += "- Máximo 4 rondas de herramientas. Sé eficiente.\n"
        sys += "- Después de cada ronda, registrá hallazgos CLAVE en current_session.md del system_workspace.\n"
        sys += "- Solo 3 tipos: [ACUERDO], [DESCARTADO], [HITO].\n"
        sys += "- Al final de tu exploración, SIEMPRE respondé con un resumen concreto.\n"
        sys += "- NUNCA preguntes '¿en qué te ayudo?' ni frases de bienvenida. La conversación ya empezó.\n"

        if !context.isEmpty { sys += "\nNota activa en el editor (truncada):\n\(context.prefix(1500))\n" }
        return sys
    }

    private func convertMcpToolsToOpenAI(_ mcpToolsJson: String) -> [[String: Any]] {
        guard let data = mcpToolsJson.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else { return [] }

        return tools.compactMap { tool -> [String: Any]? in
            guard let name = tool["name"] as? String,
                  var desc = tool["description"] as? String else { return nil }
            if desc.count > 200 { desc = String(desc.prefix(200)) }
            let schema = tool["inputSchema"] as? [String: Any]
            var fn: [String: Any] = ["name": name, "description": desc]
            if let s = schema {
                fn["parameters"] = ["type": "object", "properties": s["properties"] ?? [:], "required": s["required"] ?? []]
            }
            return ["type": "function", "function": fn]
        }
    }

    private func buildMcpRequest(tokenId: String, toolName: String, arguments: String) -> String {
        let parsedArgs: Any
        if let data = arguments.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            parsedArgs = obj
        } else {
            parsedArgs = arguments
        }
        let inner: [String: Any] = [
            "jsonrpc": "2.0", "method": "tools/call",
            "params": ["name": toolName, "arguments": parsedArgs],
            "id": 1, "mcp_client_token": tokenId
        ]
        if let data = try? JSONSerialization.data(withJSONObject: inner),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    private func agentCode(for agent: ExternalAgentConfig) -> String {
        switch agent.provider {
        case .deepseek: return "DS"
        case .anthropic: return "CL"
        case .openai: return "OP"
        }
    }
}

// MARK: - Bubble

struct ChatBubble: View {
    let message: LocalChatMessage

    var body: some View {
        HStack {
            if message.isUser { Spacer() }
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 2) {
                if let code = message.agentCode, !message.isUser {
                    Text(code)
                        .font(.caption2).bold().monospaced()
                        .foregroundColor(code == "LC" ? .green : .purple)
                }
                Text(message.text)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(message.isUser ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                    .foregroundColor(message.isUser ? .white : .primary)
                    .cornerRadius(10)
                    .frame(maxWidth: 270, alignment: message.isUser ? .trailing : .leading)
            }
            if !message.isUser { Spacer() }
        }
    }
}


// MARK: - Chat Input (NSTextView wrapper: Enter = send, ⌘Enter = newline)

struct ChatInputView: NSViewRepresentable {
    @Binding var text: String
    var disabled: Bool = false
    var onCommit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.textContainer?.widthTracksTextView = true
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let textView = nsView.documentView as! NSTextView
        textView.isEditable = !disabled
        if textView.string != text {
            textView.string = text
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputView
        init(_ p: ChatInputView) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.command) {
                    return false // ⌘Enter = insert newline (default)
                }
                parent.onCommit() // Enter = send
                return true
            }
            return false
        }
    }
}



// MARK: - Chat Messages (WebView con Markdown + selección multi-burbuja + padding)

struct ChatMessagesView: NSViewRepresentable {
    let messages: [LocalChatMessage]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(buildHTML(), baseURL: nil)
    }

    private func buildHTML() -> String {
        let msgsHTML = messages.map { msg -> String in
            let side = msg.isUser ? "user" : "agent"
            let agentLabel = msg.isUser ? "Tú" : (msg.agentCode ?? "")
            let agentColor = (msg.agentCode == "LC") ? "#34c759" : "#af52de"

            // Mensaje de "pensando…"
            if msg.type == "thinking" {
                return """
                <div class="msg agent thinking">
                  <div class="agent-label" style="color:\(agentColor)">\(agentLabel)</div>
                  <div class="bubble thinking-bubble">\(escaped(msg.text))</div>
                </div>
                """
            }

            // Colapsable de herramientas
            if msg.type == "tools" {
                let toolList = msg.toolNames.map { "<li>\(escaped($0))</li>" }.joined()
                return """
                <div class="msg agent tools-section">
                  <div class="agent-label" style="color:\(agentColor)">\(agentLabel)</div>
                  <details class="tools-details">
                    <summary class="tools-summary">\(escaped(msg.text))</summary>
                    <ul class="tools-list">\(toolList)</ul>
                  </details>
                </div>
                <div class="sep"></div>
                """
            }

            return """
            <div class="msg \(side)">
              <div class="agent-label" style="color:\(agentColor)">\(agentLabel)</div>
              <div class="bubble">\(escaped(msg.text))</div>
            </div>
            <div class="sep"></div>
            """
        }.joined()

        func escaped(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
        }

        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: light dark; }
          * { margin:0; padding:0; box-sizing:border-box; }
          body {
            font: -apple-system-body; line-height:1.55;
            color: -apple-system-label; background: transparent;
            padding: 20px 18px; -webkit-user-select: text; user-select: all;
          }
          .msg { display: flex; flex-direction: column; margin-bottom: 6px; }
          .msg.user { align-items: flex-end; }
          .msg.agent { align-items: flex-start; }
          .agent-label { font-size: 10px; font-weight: 700; font-family: monospace; margin-bottom: 3px; user-select: none; }
          .bubble { display: inline-block; max-width: 90%; padding: 10px 14px; border-radius: 12px; word-wrap: break-word; }
          .user .bubble { background: #007aff; color: #fff; }
          .agent .bubble { background: rgba(128,128,128,0.12); color: -apple-system-label; }
          .sep { height: 12px; }
          @media (prefers-color-scheme: dark) {
            .agent .bubble { background: rgba(255,255,255,0.08); }
          }

          /* Markdown styles */
          .bubble p { margin: 3px 0; }
          .bubble p:first-child { margin-top:0; }
          .bubble p:last-child { margin-bottom:0; }
          .bubble code { background: rgba(128,128,128,0.2); padding: 1px 5px; border-radius: 4px; font-family: monospace; font-size: 0.9em; }
          .bubble pre { background: rgba(0,0,0,0.08); padding: 10px 14px; border-radius: 8px; overflow-x: auto; margin: 6px 0; font-size: 0.9em; }
          .bubble pre code { background: none; padding: 0; font-size: inherit; }
          .bubble ul, .bubble ol { padding-left: 20px; margin: 4px 0; }
          .bubble li { margin: 2px 0; }
          .bubble blockquote { border-left: 3px solid rgba(128,128,128,0.3); padding-left: 10px; margin: 6px 0; opacity: 0.8; }
          .bubble h1,.bubble h2,.bubble h3,.bubble h4 { margin: 10px 0 4px; font-weight: 600; }
          .bubble h1 { font-size: 1.25em; } .bubble h2 { font-size: 1.12em; } .bubble h3 { font-size: 1.05em; }
          .bubble strong { font-weight: 600; }
          .bubble table { border-collapse:collapse; margin: 6px 0; font-size: 0.9em; }
          .bubble th,.bubble td { border:1px solid rgba(128,128,128,0.3); padding: 4px 8px; }
          .bubble th { background: rgba(128,128,128,0.1); }
          .bubble a { color: inherit; opacity: 0.85; }

          /* Thinking animation */
          .thinking-bubble { font-style: italic; opacity: 0.6; }
          @keyframes pulse { 0%,100% { opacity: 0.4; } 50% { opacity: 0.7; } }
          .thinking { animation: pulse 1.5s ease-in-out infinite; }

          /* Collapsible tools */
          .tools-details { margin: 4px 0; }
          .tools-summary { cursor: pointer; font-size: 0.85em; opacity: 0.7; padding: 4px 8px; border-radius: 6px; background: rgba(128,128,128,0.08); display: inline-block; user-select: none; }
          .tools-summary:hover { opacity: 1; background: rgba(128,128,128,0.15); }
          .tools-list { margin: 8px 0 0 16px; font-size: 0.8em; opacity: 0.6; font-family: monospace; }
          .tools-list li { margin: 2px 0; }

          /* Mermaid diagrams */
          .mermaid-diagram { margin: 12px 0; padding: 12px; background: rgba(255,255,255,0.6); border-radius: 8px; overflow-x: auto; }
          .mermaid-diagram svg { max-width: 100%; height: auto; }

          @media (prefers-color-scheme: dark) {
            .bubble pre { background: rgba(255,255,255,0.06); }
            .bubble code { background: rgba(255,255,255,0.1); }
            .mermaid-diagram { background: rgba(255,255,255,0.05); }
          }
        </style>
        <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
        <script>mermaid.initialize({ startOnLoad: false, theme: 'default' });</script>
        </head><body>
        \(msgsHTML)
        <script>
          marked.setOptions({ breaks: true, gfm: true });
          document.querySelectorAll('.bubble').forEach(el => {
            let html = marked.parse(el.textContent || '');
            // Reemplazar bloques ```mermaid por divs renderizables
            html = html.replace(/<pre><code class="language-mermaid">([\\s\\S]*?)<\\/code><\\/pre>/g, (_, code) => {
              const id = 'mermaid-' + Math.random().toString(36).substr(2, 9);
              setTimeout(() => { mermaid.render(id, code).then(({svg}) => { document.getElementById(id).innerHTML = svg; }); }, 100);
              return '<div class="mermaid-diagram" id="' + id + '"></div>';
            });
            el.innerHTML = html;
          });
          requestAnimationFrame(() => { window.scrollTo(0, document.body.scrollHeight); });
        </script>
        </body></html>
        """
    }

    class Coordinator: NSObject {}
}

// MARK: - Permissions Bar

struct PermissionsBar: View {
    let agent: LocalChatView.AgentChip
    @State private var showWsPopover = false

    var workspaces: [String] {
        switch agent {
        case .local: return []
        case .external(let a): return a.workspaces
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            switch agent {
            case .local:
                PermBadge("Read", allowed: true).help("Lectura de contenido de notas")
                PermBadge("Writ", allowed: true).help("Escritura de notas y metadatos")
                PermBadge("Meta", allowed: true).help("Acceso a _memory, _specs, _lore")
                PermBadge("Syst", allowed: true).help("Acceso a system_workspace")
                PermBadge("Telem", allowed: true).help("Lectura de telemetría")
                Text("·").foregroundColor(.secondary)
                Text("All").font(.caption2).bold()
                    .help("Todos los workspaces registrados")
            case .external(let a):
                PermBadge("Read", allowed: a.readContent).help("Lectura de contenido crudo de notas")
                PermBadge("Writ", allowed: a.writeContent).help("Escritura: crear/modificar notas")
                PermBadge("Meta", allowed: a.readMetadata).help("Lectura de _memory, _specs, _lore")
                PermBadge("Syst", allowed: a.readSystem).help("Acceso a system_workspace")
                PermBadge("Telem", allowed: a.readTelemetry).help("Lectura de telemetría")
                Text("·").foregroundColor(.secondary)
                Button(action: { showWsPopover.toggle() }) {
                    Text(wsLabel(a.workspaces))
                        .font(.caption2).bold()
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showWsPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Workspaces").font(.headline).padding(.bottom, 4)
                        ForEach(a.workspaces, id: \.self) { ws in
                            Text((URL(fileURLWithPath: ws).lastPathComponent))
                                .font(.caption)
                            Text(ws).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .frame(minWidth: 280)
                }
            }
        }
    }

    private func wsLabel(_ ws: [String]) -> String {
        if ws.isEmpty { return "All" }
        let names = ws.map { (URL(fileURLWithPath: $0).lastPathComponent) }
        if names.count <= 1 { return names.joined(separator: ", ") }
        return "\(names.count) ws ▾"
    }
}

struct PermBadge: View {
    let label: String
    let allowed: Bool
    init(_ label: String, allowed: Bool) { self.label = label; self.allowed = allowed }
    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(allowed ? .green : .secondary.opacity(0.4))
    }
}
