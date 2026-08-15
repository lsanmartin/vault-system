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
    var applyContent: String? = nil     // texto editable propuesto (Opciones IA para notas)
    var applyInstruction: String? = nil // label para la cabecera "### ✨ ..."
    var applyNoteId: String? = nil      // nota destino (para verificar que no cambió)
    var persistedId: Int64? = nil       // id real en DuckDB (lazy loading, búsqueda, ancla de scroll)
    var persistedDate: Date? = nil      // timestamp real persistido; nil = mensaje en memoria (usar Date())
    var effectiveDate: Date { persistedDate ?? timestamp }
    static func == (lhs: LocalChatMessage, rhs: LocalChatMessage) -> Bool { lhs.id == rhs.id }
}

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

    /// Código estable para DB (no cambia aunque el usuario renombre el agente).
    /// Es la clave de thread de `ChatThreadManager`; para etiquetas visibles
    /// (DS/CL/OP) los flujos externos usan `ChatAgentSupport.agentCode(for:)`.
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

/// Sidebar del chat: header global de configuración + N secciones verticales,
/// una por agente (Local + cada agente externo configurado). Cada sección
/// (`AgentChatSection`) es un chat independiente con su propio thread, input,
/// feed WebView y estado. Al agregar un agente externo la lista pasa de 2 a 3
/// secciones automáticamente (dividen la altura por igual).
struct LocalChatView: View {
    @ObservedObject var viewModel: EditorViewModel
    @ObservedObject private var agentManager = ExternalAgentManager.shared

    @State private var showAgentSettings = false
    @State private var showModelManager = false
    /// Pesos de altura por agentCode (proporciones entre secciones, persistidas).
    /// Vacio = todos iguales. El tirador entre secciones los ajusta y se guardan en UserDefaults.
    @State private var weights: [String: Double] = [:]

    private static let weightsKey = "vault_chat_weights"
    private static let minWeight = 0.12   // una sección nunca queda por debajo de esta proporción
    private static let minSectionHeight: CGFloat = 100   // piso de alto por sección (adaptativo si la ventana es corta)
    private static let bottomInset: CGFloat = 12          // margen inferior tras el último chat (evita input cortado)

    var chips: [AgentChip] {
        [.local] + agentManager.agents.map { .external($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header global de configuración (no pertenece a ninguna sección)
            HStack(spacing: 8) {
                Button(action: { showAgentSettings = true }) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Configurar agentes externos")

                Button(action: { showModelManager = true }) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Modelos locales (Cerebro MLX)")

                Spacer()

                Text("\(chips.count) \(chips.count == 1 ? "chat" : "chats")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Secciones por agente: cada una ocupa su proporción de la altura.
            // Entre secciones hay un tirador que redimensiona la proporción.
            GeometryReader { geo in
                // `total` ya descuenta el margen inferior: las secciones nunca llegan al borde de la ventana.
                let total = max(geo.size.height - Self.bottomInset, 1)
                let codes = chips.map { $0.agentCode }
                let sum = codes.reduce(0.0) { acc, c in acc + (weights[c] ?? 1.0) }
                // Piso adaptativo: si la ventana es tan corta que n×100 supera el alto, el piso baja
                // para que las secciones sumen ≤ total (nunca desbordan ni quedan traslapadas).
                let minSection = min(Self.minSectionHeight, total / CGFloat(max(codes.count, 1)))
                VStack(spacing: 0) {
                    ForEach(Array(chips.enumerated()), id: \.element) { i, chip in
                        AgentChatSection(agent: chip, viewModel: viewModel)
                            .frame(height: max(minSection, total * (weights[chip.agentCode] ?? 1.0) / sum))
                        if i < chips.count - 1 {
                            ChatSectionDivider { deltaPts in
                                resizeWeights(index: i, codes: codes, deltaPts: deltaPts, total: total)
                            }
                        }
                    }
                    // Margen inferior tras el último chat: el input no queda pegado ni cortado al borde.
                    Spacer(minLength: Self.bottomInset)
                }
            }
        }
        .frame(minWidth: 280, maxWidth: 550)
        .sheet(isPresented: $showAgentSettings) {
            AgentSettingsView()
                .frame(width: 560, height: 780)
        }
        .sheet(isPresented: $showModelManager) {
            ModelManagerView()
                .frame(width: 620, height: 720)
        }
        .onAppear {
            weights = loadWeights()
        }
    }

    // MARK: - Proporciones (tirador entre secciones)

    private func loadWeights() -> [String: Double] {
        guard let data = UserDefaults.standard.data(forKey: Self.weightsKey),
              let stored = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return stored
    }

    private func saveWeights(_ w: [String: Double]) {
        if let data = try? JSONEncoder().encode(w) {
            UserDefaults.standard.set(data, forKey: Self.weightsKey)
        }
    }

    /// Ajusta el peso relativo de las secciones `i` e `i+1` (la del tirador arrastrado).
    /// `deltaPts` > 0 → la sección superior crece (la inferior se encoge), y viceversa.
    /// La suma de pesos se conserva; el cambio se persiste (proporción sobrevive al reinicio).
    private func resizeWeights(index i: Int, codes: [String], deltaPts: CGFloat, total: CGFloat) {
        guard total > 0, i >= 0, i < codes.count - 1 else { return }
        let frac = Double(deltaPts / total)
        var w = weights
        for c in codes where w[c] == nil { w[c] = 1.0 }
        let a = codes[i], b = codes[i + 1]
        let na = (w[a] ?? 1.0) + frac
        let nb = (w[b] ?? 1.0) - frac
        guard na > Self.minWeight, nb > Self.minWeight else { return }
        w[a] = na
        w[b] = nb
        weights = w
        saveWeights(w)
    }
}

/// Tirador horizontal entre dos secciones del chat: drag vertical redimensiona la
/// proporción (la sección superior crece/encoge según la dirección del arrastre).
struct ChatSectionDivider: View {
    var onDrag: (CGFloat) -> Void
    @State private var lastTranslation: CGFloat = 0

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(NSColor.windowBackgroundColor))
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 3, height: 3)
                }
            }
        }
        .frame(height: 10)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let d = value.translation.height - lastTranslation
                    lastTranslation = value.translation.height
                    if d != 0 { onDrag(d) }
                }
                .onEnded { _ in lastTranslation = 0 }
        )
        .help("Arrastrar para redimensionar")
    }
}

/// Chat independiente de UN agente: header propio (identidad + power + búsqueda
/// + trash), barra de permisos, opciones de Nota IA, feed WebView e input. Todo
/// el estado (mensajes, input, generación, búsqueda, lazy-loading) es por sección
/// y los threads en DuckDB ya están keyed por `agent.agentCode`.
struct AgentChatSection: View {
    let agent: AgentChip
    @ObservedObject var viewModel: EditorViewModel
    @ObservedObject private var brain = LocalBrain.shared
    @ObservedObject private var agentManager = ExternalAgentManager.shared
    @ObservedObject private var chatThreads = ChatThreadManager.shared
    @EnvironmentObject var workspaceManager: WorkspaceManager

    @State private var messages: [LocalChatMessage] = []
    @State private var inputText: String = ""
    @State private var isGenerating: Bool = false
    @State private var generationTask: Task<Void, Never>? = nil
    @State private var streamMsgID: UUID? = nil   // mensaje en streaming (append 1er chunk + update por id)
    @State private var agentStateEpoch = 0        // fuerza re-render del header al togglear agentes externos

    // Lazy loading (chat infinito tipo WhatsApp)
    @State private var hasMoreOlder = true
    @State private var isLoadingOlder = false
    @State private var preserveAnchorId: Int64? = nil   // primer mensaje visible previo (ancla de scroll)
    @State private var pendingScrollToId: Int64? = nil  // salto desde búsqueda

    // Búsqueda en el chat
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var searchResults: [PersistentMessage] = []

    // Opciones IA para notas (preferencias globales, compartidas entre secciones)
    @AppStorage("vault_noteai_autoApply") private var noteAIAutoApply = false
    @AppStorage("vault_noteai_mode") private var noteAIModeRaw = "Insertar al final"
    @State private var noteAITitleOverride = ""
    @State private var notePanelExpanded = false   // panel de Opciones IA desplegado (header en una línea)

    private var applyMode: NoteAIMode {
        NoteAIMode(rawValue: noteAIModeRaw) ?? .insertAtEnd
    }

    /// Índice del tab activo en `viewModel.tabs`, o nil si no hay nota abierta.
    private var activeTabIndex: Int? {
        guard let id = viewModel.activeTabId else { return nil }
        return viewModel.tabs.firstIndex(where: { $0.id == id })
    }

    private func noteInWorkspace(_ path: String, _ workspaces: [String]) -> Bool {
        workspaces.contains { ws in
            let w = ws.hasSuffix("/") ? String(ws.dropLast()) : ws
            return path.hasPrefix(w + "/") || path == w
        }
    }

    /// Contenido de la nota activa (contexto para el modelo), o "" si no hay tab abierta.
    private func activeNoteContext() -> String {
        guard let id = viewModel.activeTabId,
              let tab = viewModel.tabs.first(where: { $0.id == id }) else { return "" }
        return tab.content
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header de la sección — UNA línea: identidad + permisos inline + acciones.
            // El panel de Opciones IA se despliega al tocar sparkles ▾ (no ocupa alto si está cerrado).
            HStack(spacing: 5) {
                // Grupo izquierdo (identidad + permisos): prioridad BAJA → comprime/trunca
                // cuando el sidebar es angosto, para que las acciones de la derecha
                // NUNCA queden fuera del borde (antes el fixedSize las empujaba y no se podían tocar).
                HStack(spacing: 5) {
                    Circle()
                        .fill(agent.color)
                        .frame(width: 7, height: 7)
                    Text(agent.displayName)
                        .font(.subheadline).bold()
                        .lineLimit(1)              // comprime y trunca antes que romper la línea
                    Text(agent.detailName)
                        .font(.caption2).foregroundColor(.secondary)
                        .lineLimit(1)
                    PermissionsBar(agent: agent)   // badges inline (comprimibles, no fixedSize)
                        .layoutPriority(0)
                }
                .id(agentStateEpoch)   // re-crea el header al togglear agentes externos (UserDefaults no observa)
                .layoutPriority(0)

                Spacer(minLength: 4)

                // Grupo de acciones: prioridad ALTA → siempre recibe su ancho completo.
                HStack(spacing: 4) {
                    // Opciones IA para notas (desplegable desde el header)
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) { notePanelExpanded.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9))
                                .foregroundColor(notePanelExpanded ? .purple : .secondary)
                            Image(systemName: notePanelExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("Opciones IA para notas")

                    // Toggle on/off de ESTE agente
                    Button(action: { toggleAgent() }) {
                        Image(systemName: isAgentEnabled ? "power.circle.fill" : "power")
                            .font(.system(size: 12))
                            .foregroundColor(isAgentEnabled ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isAgentEnabled ? "Desactivar \(agent.displayName)" : "Activar \(agent.displayName)")

                    // Búsqueda (del thread de esta sección)
                    Button(action: {
                        withAnimation { isSearching.toggle() }
                        if !isSearching { searchText = ""; searchResults = [] }
                    }) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(isSearching ? .accentColor : .secondary)
                    .help("Buscar en el chat")

                    // /clear de esta sección
                    Button(action: {
                        messages = [LocalChatMessage(text: "Chat reiniciado.", isUser: false, agentCode: agent.agentCode)]
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("/clear — Limpiar vista")
                }
                .layoutPriority(1)
            }
            .padding(.horizontal).padding(.vertical, 3)
            .background(Color(NSColor.windowBackgroundColor))

            // Buscador (chat infinito, tipo WhatsApp)
            if isSearching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.system(size: 11))
                    TextField("Buscar mensajes…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit { runSearch(searchText) }
                    if !searchText.isEmpty {
                        Button("Buscar") { runSearch(searchText) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    Button("Cancelar") { isSearching = false; searchText = ""; searchResults = [] }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color(NSColor.windowBackgroundColor))
                .transition(.move(edge: .top))
            }

            // Panel de Opciones IA para notas (desplegable desde el header)
            if notePanelExpanded {
                NoteAIOptionsPanel(
                    viewModel: viewModel,
                    isEnabled: isAgentEnabled,
                    autoApply: $noteAIAutoApply,
                    modeRaw: $noteAIModeRaw,
                    titleOverride: $noteAITitleOverride,
                    onRun: { instruction, title in
                        runNoteAIAction(instruction: instruction, actionTitle: title)
                    }
                )
                .padding(.horizontal, 10).padding(.bottom, 4)
                .background(Color(NSColor.windowBackgroundColor))
            }

            Divider()

            // Mensajes (WKWebView: chat infinito + marcas de sesión + búsqueda)
            ChatMessagesView(
                messages: messages,
                preserveAnchorId: preserveAnchorId,
                pendingScrollToId: pendingScrollToId,
                onApplyNote: { msgID in handleApplyRequest(messageID: msgID) },
                onRequestOlder: { loadOlderMessages() }
            )
            .background(Color(NSColor.windowBackgroundColor))
            .overlay(alignment: .top) {
                if isSearching && !searchResults.isEmpty {
                    ChatSearchResultsList(results: searchResults, onSelect: { id in jumpToMessage(id: id) })
                        .frame(maxHeight: 260)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .shadow(radius: 6)
                        .padding(.horizontal, 10).padding(.top, 6)
                }
            }
                .onChange(of: messages.count) { _ in
                    // scroll handled internally por buildHTML (JS)
                }

            Divider()

            // Acciones rápidas de IA para notas
            NoteAIQuickActionsRow(
                actions: NoteAIAction.all,
                isEnabled: isAgentEnabled,
                onAction: { action in
                    runNoteAIAction(instruction: action.instruction, actionTitle: action.title)
                }
            )
            .padding(.horizontal, 8).padding(.vertical, 1)
            .background(Color(NSColor.windowBackgroundColor))

            // Input
            HStack(alignment: .bottom, spacing: 8) {
                ChatInputView(text: $inputText, disabled: !isAgentEnabled, onCommit: send)
                    .frame(minHeight: 44, maxHeight: 200)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(3)
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
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isAgentEnabled)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .overlay(alignment: .top) { Divider() }
        .onAppear { loadThread() }
        .onDisappear {
            DispatchQueue.global().async { saveCurrentThreadMessages() }
        }
        .onChange(of: isGenerating) { _, generating in
            if !generating, let last = messages.last, !last.isUser {
                saveMessage(last)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ChatReset"))) { _ in
            createAnchorNote(for: agent)
            messages = [LocalChatMessage(text: "Sesión reiniciada. Ancla creada en _inbox/.", isUser: false, agentCode: agent.agentCode)]
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ChatClear"))) { _ in
            messages.removeAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ChatCompact"))) { _ in
            let summary = "Contexto compactado. \(messages.count) mensajes resumidos."
            messages = [LocalChatMessage(text: summary, isUser: false, agentCode: agent.agentCode)]
        }
        // @mención desde otra sección → este agente la envía en su propio thread
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ChatMentionRedirect"))) { notification in
            guard let code = notification.userInfo?["agentCode"] as? String,
                  let text = notification.userInfo?["text"] as? String,
                  code == agent.agentCode else { return }
            inputText = ""
            let userMsg = LocalChatMessage(text: text, isUser: true, agentCode: nil)
            messages.append(userMsg)
            saveMessage(userMsg)
            isGenerating = true
            let ctx = activeNoteContext()
            generationTask = Task {
                switch agent {
                case .local:
                    sendLocal(prompt: text, context: ctx)
                case .external(let a):
                    sendExternal(prompt: text, agent: a, context: ctx)
                }
            }
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
        chatThreads.getOrCreateThread(for: agent.agentCode)
    }

    private func loadThread() {
        // Recargar threads desde DB (por si se crearon en otra sesión)
        chatThreads.loadThreads()
        let tid = chatThreads.getOrCreateThread(for: agent.agentCode)
        // Carga inicial liviana: últimas 60 (chat infinito → scroll arriba carga el resto)
        let raw = chatThreads.toLocalMessages(threadId: tid, limit: 60)
        // Limpieza de filas decorativas persistidas por versiones anteriores:
        // solo se excluye el placeholder "Chat X — Escribí tu mensaje." (con etiqueta ext_xxx).
        // Los marcadores de sesión "── … ──" (p. ej. de /reset) SÍ se conservan y se
        // renderizan como anclas: son la recuperación de las marcas de reinicio.
        let msgs = raw.filter { msg in
            !(msg.text.hasPrefix("Chat ") && msg.text.contains("— Escribí tu mensaje"))
        }.map { msg -> LocalChatMessage in
            var m = msg
            if m.text.hasPrefix("── ") && m.text.hasSuffix(" ──") {
                m.type = "anchor"
            }
            return m
        }
        if msgs.isEmpty {
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
            let ts = df.string(from: Date())
            messages = [
                LocalChatMessage(text: "── Sesión iniciada \(ts) ──", isUser: false, agentCode: nil, type: "anchor")
            ]
            hasMoreOlder = false
        } else {
            messages = msgs
            hasMoreOlder = true
        }
        isLoadingOlder = false
        preserveAnchorId = nil
        pendingScrollToId = nil
        isSearching = false
        searchText = ""
        searchResults = []
    }

    private func saveMessage(_ msg: LocalChatMessage) {
        // Idempotente: no re-guardar mensajes ya persistidos (evita duplicados en DB)
        guard msg.persistedId == nil else { return }
        let tid = currentThreadId
        let role = msg.isUser ? "user" : "assistant"
        let id = chatThreads.saveMessage(threadId: tid, role: role, agentCode: msg.agentCode, content: msg.text)
        if id > 0, let idx = messages.firstIndex(where: { $0.id == msg.id }) {
            messages[idx].persistedId = id
            messages[idx].persistedDate = Date()
        }
    }

    private func saveCurrentThreadMessages() {
        // Red de seguridad al cerrar: guardar solo lo que aún no está en DB.
        // (No usa saveMessage(_:) porque corre desde hilo background y no debe mutar @State)
        let tid = currentThreadId
        // No persistir mensajes decorativos (anchors "── … ──"): no son conversación real.
        for msg in messages where msg.persistedId == nil && msg.type != "anchor" {
            _ = chatThreads.saveMessage(threadId: tid, role: msg.isUser ? "user" : "assistant", agentCode: msg.agentCode, content: msg.text)
        }
    }

    // MARK: - Chat infinito (lazy loading)

    /// Carga la página anterior de mensajes (previos al primero visible) y la antepone sin perder el scroll.
    private func loadOlderMessages() {
        guard hasMoreOlder, !isLoadingOlder else { return }
        guard let anchor = messages.first?.persistedId, anchor > 1 else {
            hasMoreOlder = false   // no hay más historial (o solo mensajes en memoria)
            return
        }
        // Fijar el ancla ANTES del render: primer mensaje visible previo.
        // Se mantiene hasta que el usuario envíe un mensaje o salte desde
        // búsqueda (allí send()/jumpToMessage() lo limpian), de modo que el
        // reload tras anteponer mensajes viejos vuelve a centrarlo y NO cae
        // al fondo. Antes se limpiaba con DispatchQueue.main.async, lo que
        // disparaba un segundo reload sin ancla → el JS ejecutaba scrollToBottom
        // (el "salto al final" de la conversación).
        preserveAnchorId = anchor
        isLoadingOlder = true
        let tid = currentThreadId
        let older = chatThreads.loadMessages(threadId: tid, limit: 60, beforeId: anchor)
        if older.isEmpty {
            hasMoreOlder = false
        } else {
            let olderLocal = older.map { msg -> LocalChatMessage in
                var local = LocalChatMessage(text: msg.content, isUser: msg.role == "user", agentCode: msg.agentCode)
                local.persistedId = msg.id
                local.persistedDate = Self.parsePersistedDate(msg.timestamp)
                return local
            }
            messages.insert(contentsOf: olderLocal, at: 0)
            if older.count < 60 { hasMoreOlder = false }
        }
        isLoadingOlder = false
    }

    // MARK: - Búsqueda

    private func runSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchResults = []; return }
        let tid = currentThreadId
        searchResults = chatThreads.searchMessages(threadId: tid, query: q, limit: 100)
    }

    /// Salta a un resultado de búsqueda: carga TODO el historial del thread y resalta el mensaje.
    /// Nota: antes se cargaba `beforeId: id` con `limit: 80`, pero el SQL es `id < ?2` (exclusivo),
    /// así que el match quedaba FUERA del resultado y la ventana se truncaba a 1-2 mensajes si el
    /// resultado era antiguo → el JS no encontraba el data-mid y caía al fondo. Con el historial
    /// completo, el match siempre está presente y la conversación se ve completa.
    private func jumpToMessage(id: Int64) {
        let all = loadAllMessages()
        guard !all.isEmpty else { return }
        messages = all
        hasMoreOlder = false   // ya está cargado TODO el historial
        preserveAnchorId = nil
        pendingScrollToId = id
        isSearching = false
        searchText = ""
        searchResults = []
        // NOTA: pendingScrollToId NO se limpia con DispatchQueue.main.async.
        // Eso disparaba un segundo reload sin targetId → el JS caía al else
        // (scrollToBottom). Se consume en la próxima acción real (send()/loadThread()).
    }

    /// Carga completo el historial del thread activo (ascendente) paginando hacia atrás.
    private func loadAllMessages() -> [LocalChatMessage] {
        let tid = currentThreadId
        var all: [LocalChatMessage] = []
        var beforeId: Int64? = nil
        while true {
            let batch = chatThreads.loadMessages(threadId: tid, limit: 500, beforeId: beforeId)
            if batch.isEmpty { break }
            let locals = batch.map { msg -> LocalChatMessage in
                var local = LocalChatMessage(text: msg.content, isUser: msg.role == "user", agentCode: msg.agentCode)
                local.persistedId = msg.id
                local.persistedDate = Self.parsePersistedDate(msg.timestamp)
                return local
            }
            // batch viene ascendente (los últimos `limit` antes de beforeId); anteponer
            // preserva el orden cronológico global (más antiguos primero).
            all.insert(contentsOf: locals, at: 0)
            if batch.count < 500 { break }
            guard let oldest = batch.first?.id else { break }
            beforeId = oldest   // siguiente página: antes del mensaje más antiguo de esta
        }
        return all
    }

    private static func parsePersistedDate(_ s: String) -> Date? {
        // DuckDB + crate chrono devuelve "2026-08-10 12:34:56.123456" (con fracción de microsegundos).
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let parts = s.split(separator: " ")
        if parts.count >= 2 {
            // Recortar la fracción del componente de hora y reintentar.
            let timePart = parts[1].split(separator: ".").first ?? parts[1]
            if let d = df.date(from: "\(parts[0]) \(timePart)") { return d }
        }
        return df.date(from: s) ?? df.date(from: String(s.split(separator: " ").first ?? ""))
    }

    // MARK: - Agent Enable/Disable

    private var isAgentEnabled: Bool {
        switch agent {
        case .local: return brain.isEnabled
        case .external(let a): return UserDefaults.standard.bool(forKey: "agent_enabled_\(a.id)")
        }
    }

    private func toggleAgent() {
        switch agent {
        case .local:
            brain.setEnabled(!brain.isEnabled)
        case .external(let a):
            let newVal = !UserDefaults.standard.bool(forKey: "agent_enabled_\(a.id)")
            UserDefaults.standard.set(newVal, forKey: "agent_enabled_\(a.id)")
            // UserDefaults no es observable: forzar re-render del header (id(agentStateEpoch))
            agentStateEpoch += 1
        }
    }

    // MARK: - /plan

    private func runPlan(prompt: String) {
        guard isAgentEnabled else {
            messages.append(LocalChatMessage(text: "\(agent.displayName) está desactivado.", isUser: false, agentCode: agent.agentCode))
            return
        }
        inputText = ""
        let userMsg = LocalChatMessage(text: "/plan \(prompt)", isUser: true, agentCode: nil)
        messages.append(userMsg); saveMessage(userMsg)
        isGenerating = true

        let sysPrompt = "Eres un planificador de arquitectura de software. Tu tarea es generar un plan detallado paso a paso. NO modifiques ningún archivo. Usa las herramientas disponibles para explorar el vault, leer archivos relevantes y entender el contexto. Luego genera un plan con: 1) Objetivo, 2) Archivos a modificar/crear, 3) Pasos concretos, 4) Riesgos, 5) Esfuerzo estimado. Formato Markdown."

        generationTask = Task {
            await runWithPrompt(sysPrompt: sysPrompt, userPrompt: prompt, readOnly: true)
        }
    }

    // MARK: - /goal

    private func runGoal(prompt: String) {
        guard isAgentEnabled else {
            messages.append(LocalChatMessage(text: "\(agent.displayName) está desactivado.", isUser: false, agentCode: agent.agentCode))
            return
        }
        inputText = ""
        let userMsg = LocalChatMessage(text: "/goal \(prompt)", isUser: true, agentCode: nil)
        messages.append(userMsg); saveMessage(userMsg)
        isGenerating = true

        let sysPrompt = "Eres un ejecutor de tareas en un vault de conocimiento. Tu objetivo es completar la tarea asignada usando las herramientas MCP disponibles. Trabaja de forma autónoma: 1) Explora el contexto, 2) Planifica los pasos, 3) Ejecuta cada paso usando las herramientas (vault_write, vault_search, vault_read, etc.), 4) Verifica cada paso, 5) Reporta el resultado final. Si algo falla, reintenta con un enfoque diferente. Máximo 3 reintentos por paso."

        generationTask = Task {
            await runWithPrompt(sysPrompt: sysPrompt, userPrompt: prompt, readOnly: false)
        }
    }

    // MARK: - /design

    private func runDesign(prompt: String) {
        guard isAgentEnabled else {
            messages.append(LocalChatMessage(text: "\(agent.displayName) está desactivado.", isUser: false, agentCode: agent.agentCode))
            return
        }
        inputText = ""
        let userMsg = LocalChatMessage(text: "/design \(prompt)", isUser: true, agentCode: nil)
        messages.append(userMsg); saveMessage(userMsg)
        isGenerating = true

        let sysPrompt = "Eres un arquitecto de software. Genera un diagrama Mermaid que represente: \(prompt). Usa las herramientas para explorar el contexto si es necesario. Responde con el código Mermaid entre ```mermaid y ```. Usa graph TD o flowchart. Incluye componentes, conexiones y etiquetas descriptivas."

        generationTask = Task {
            await runWithPrompt(sysPrompt: sysPrompt, userPrompt: "Genera un diagrama Mermaid para: \(prompt)", readOnly: true)
        }
    }

    // MARK: - Shared execution

    private func runWithPrompt(sysPrompt: String, userPrompt: String, readOnly: Bool) async {
        switch agent {
        case .local:
            // Local no tiene tool calling: fallback a chat normal con prompt combinado
            let combinedPrompt = "\(sysPrompt)\n\n---\n\n\(userPrompt)"
            sendLocal(prompt: combinedPrompt, context: "")
        case .external(let a):
            await runExternalPlan(sysPrompt: sysPrompt, userPrompt: userPrompt, agent: a)
        }
    }

    private func runExternalPlan(sysPrompt: String, userPrompt: String, agent: ExternalAgentConfig, noteAI: NoteAIApplyInfo? = nil) async {
        guard let key = agentManager.getAPIKey(for: agent.id) else {
            await MainActor.run {
                messages.append(LocalChatMessage(text: "❌ Sin API key.", isUser: false, agentCode: ChatAgentSupport.agentCode(for: agent)))
                isGenerating = false
            }
            return
        }
        let code = ChatAgentSupport.agentCode(for: agent)
        let beforeCount = messages.count

        let toolsJson = getAgentMcpTools(tokenId: agent.tokenId)
        let openaiTools = ChatAgentSupport.convertMcpToolsToOpenAI(toolsJson)

        var conversation: [[String: Any]] = [
            ["role": "system", "content": String(sysPrompt.prefix(6000))],
            ["role": "user", "content": userPrompt]
        ]
        var pendingTools: [String] = []
        var wroteActiveNote = false

        for turn in 0..<5 {
            var result = await ChatAgentSupport.streamAPI(
                agent: agent, key: key, apiMessages: conversation, tools: openaiTools,
                onDelta: { [self] text in
                    self.streamMessage(text, code: code)
                }
            )
            // Reintentar errores de red (timeout, conexión perdida)
            if let error = result.error, (error.contains("Conexión perdida") || error.contains("Red:")) && turn < 3 {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                result = await ChatAgentSupport.streamAPI(
                    agent: agent, key: key, apiMessages: conversation, tools: openaiTools,
                    onDelta: { [self] text in
                        self.streamMessage(text, code: code)
                    }
                )
            }
            if let error = result.error {
                await MainActor.run {
                    messages.append(LocalChatMessage(text: "❌ \(error)", isUser: false, agentCode: code))
                    isGenerating = false
                    streamMsgID = nil
                }
                return
            }
            guard let toolCalls = result.toolCalls, !toolCalls.isEmpty else {
                await flushPending(text: "", tools: pendingTools, code: code)
                await MainActor.run { streamMsgID = nil }
                if let noteAI, let text = result.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await MainActor.run {
                        finalizeNoteAIMessage(noteAI: noteAI, content: text, index: messages.indices.last, wroteActiveNote: wroteActiveNote)
                    }
                }
                await MainActor.run { isGenerating = false }
                return
            }
            pendingTools.append(contentsOf: toolCalls.map(\.name))
            // Detectar escritura directa: nota activa (path == noteId) o, en modo crear-nota, cualquier vault_write.
            if let noteAI {
                for tc in toolCalls where tc.name == "vault_write" {
                    if let data = tc.args.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let path = obj["path"] as? String, !path.isEmpty,
                       noteAI.noteId == nil || path == noteAI.noteId {
                        wroteActiveNote = true
                    }
                }
            }
            var assistantMsg: [String: Any] = ["role": "assistant"]
            assistantMsg["tool_calls"] = toolCalls.map { tc in
                ["id": tc.id, "type": "function", "function": ["name": tc.name, "arguments": tc.args]] as [String: Any]
            }
            conversation.append(assistantMsg)
            for tc in toolCalls {
                var raw = mcpExecuteForAgent(jsonRequest: ChatAgentSupport.buildMcpRequest(tokenId: agent.tokenId, toolName: tc.name, arguments: tc.args))
                if raw.count > 1500 { raw = String(raw.prefix(1500)) + "\n…" }
                conversation.append(["role": "tool", "tool_call_id": tc.id, "content": raw])
            }
            let total = conversation.reduce(0) { $0 + (($1["content"] as? String)?.count ?? 0) }
            if total > 1_500_000 { conversation = [conversation[0], conversation[1]] + Array(conversation.suffix(6)) }
        }
        await flushPending(text: "", tools: pendingTools, code: code)
        await MainActor.run {
            streamMsgID = nil
            isGenerating = false
        }
        _ = beforeCount
    }

    // MARK: - Cancel

    private func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        if agent == .local {
            brain.cancelChat()
        }
        isGenerating = false
        streamMsgID = nil
        messages.append(LocalChatMessage(text: "⏹ Generación cancelada.", isUser: false, agentCode: agent.agentCode))
    }

    // MARK: - Send

    private func send() {
        let clean = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        // Detectar @mención → redirigir a la sección del agente mencionado.
        // Solo si apunta a OTRO agente; mencionarse a sí mismo envía normal.
        if let first = clean.split(separator: " ").first, first.hasPrefix("@") {
            let m = String(first.dropFirst()).lowercased()
            var targetCode: String? = nil
            if m == "local" || m == "lc" {
                targetCode = AgentChip.local.agentCode
            } else if let match = agentManager.agents.first(where: {
                $0.name.lowercased().replacingOccurrences(of: " ", with: "") == m
            }) {
                targetCode = AgentChip.external(match).agentCode
            }
            if let targetCode, targetCode != agent.agentCode {
                // La sección destino (mismo agentCode) recibe el mensaje vía ChatMentionRedirect
                NotificationCenter.default.post(
                    name: NSNotification.Name("ChatMentionRedirect"),
                    object: nil,
                    userInfo: ["agentCode": targetCode, "text": clean]
                )
                inputText = ""
                return
            }
        }

        // Comandos (pertenecen a la sección actual)
        if clean == "/reset" {
            createAnchorNote(for: agent)
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
            let ts = df.string(from: Date())
            // Marcador visible en el feed (persiste en el MISMO thread, no borra historial)
            let marker = LocalChatMessage(text: "── Contexto reiniciado \(ts) ──", isUser: false, agentCode: agent.agentCode, type: "anchor")
            messages.append(marker)
            saveMessage(marker)
            inputText = ""; return
        }
        if clean == "/clear" {
            messages.removeAll()
            inputText = ""; return
        }
        if clean == "/compact" {
            let summary = "Contexto compactado. \(messages.count) mensajes resumidos."
            messages = [LocalChatMessage(text: summary, isUser: false, agentCode: agent.agentCode)]
            inputText = ""; return
        }
        if clean.hasPrefix("/plan ") {
            let goal = String(clean.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            runPlan(prompt: goal); return
        }
        if clean.hasPrefix("/goal ") {
            let goal = String(clean.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            runGoal(prompt: goal); return
        }
        if clean.hasPrefix("/design ") {
            let goal = String(clean.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            runDesign(prompt: goal); return
        }
        if clean.hasPrefix("/nota ") {
            let instruction = String(clean.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            guard !instruction.isEmpty else { inputText = ""; return }
            runNoteAIAction(instruction: instruction, actionTitle: instruction)
            return
        }

        guard isAgentEnabled else {
            messages.append(LocalChatMessage(text: "\(agent.displayName) está desactivado.", isUser: false, agentCode: agent.agentCode))
            return
        }

        let prompt = clean
        inputText = ""
        // Mensaje nuevo → limpiar anclas de lazy loading/búsqueda y volver al fondo.
        // Si quedaran preserveAnchorId/pendingScrollToId seteados, el reload del
        // HTML anclaría en un mensaje viejo en vez de mostrar el recién enviado.
        preserveAnchorId = nil
        pendingScrollToId = nil
        let userMsg = LocalChatMessage(text: prompt, isUser: true, agentCode: nil)
        messages.append(userMsg)
        saveMessage(userMsg)
        isGenerating = true

        let ctx = activeNoteContext()

        generationTask = Task {
            switch agent {
            case .local:
                sendLocal(prompt: prompt, context: ctx)
            case .external(let a):
                sendExternal(prompt: prompt, agent: a, context: ctx)
            }
        }
    }

    // MARK: - Local Brain

    private func sendLocal(prompt: String, context: String, noteAI: NoteAIApplyInfo? = nil) {
        let code = agent.agentCode
        Task {
            do {
                let stream = try await brain.chatStream(prompt: prompt, context: context)
                let msg = LocalChatMessage(text: "", isUser: false, agentCode: code)
                await MainActor.run {
                    streamMsgID = msg.id
                    messages.append(msg)
                }
                var acc = ""
                for await chunk in stream {
                    acc += chunk
                    await MainActor.run {
                        if let i = messages.indices.last { messages[i] = LocalChatMessage(text: acc, isUser: false, agentCode: code) }
                    }
                }
                if let noteAI {
                    await MainActor.run {
                        finalizeNoteAIMessage(noteAI: noteAI, content: acc, index: messages.indices.last, wroteActiveNote: false)
                    }
                }
            } catch {
                await MainActor.run {
                    messages.append(LocalChatMessage(text: "❌ \(error.localizedDescription)", isUser: false, agentCode: code))
                }
            }
            await MainActor.run {
                streamMsgID = nil
                isGenerating = false
            }
        }
    }

    // MARK: - External API (con tool calling MCP real)

    private func sendExternal(prompt: String, agent: ExternalAgentConfig, context: String) {
        guard let key = agentManager.getAPIKey(for: agent.id) else {
            messages.append(LocalChatMessage(text: "❌ Sin API key en Keychain.", isUser: false, agentCode: ChatAgentSupport.agentCode(for: agent)))
            isGenerating = false; return
        }

        let code = ChatAgentSupport.agentCode(for: agent)
        // Saludo/casual: NO se envían herramientas → respuesta breve, sin auditoría del vault.
        // "hola" no debe disparar 9 llamadas MCP explorando el vault.
        let casual = ChatAgentSupport.isCasualMessage(prompt)
        let sys: String
        if casual {
            // Prompt mínimo: sin menciones de herramientas, scratchpad ni contexto del vault,
            // para que el modelo no se sienta en "modo trabajo" ni alucine un tool_call.
            sys = "Eres \(agent.name), un asistente conversacional. Responde de forma breve, natural y en español. No menciones herramientas, archivos, current_session.md ni scratchpad."
        } else {
            sys = String(ChatAgentSupport.buildSystemPrompt(agent: agent, context: context).prefix(6000))
        }
        let openaiTools: [[String: Any]]
        if casual {
            openaiTools = []
        } else {
            let toolsJson = getAgentMcpTools(tokenId: agent.tokenId)
            openaiTools = ChatAgentSupport.convertMcpToolsToOpenAI(toolsJson)
        }
        print("[Chat] casual=\(casual) tools_enviadas=\(openaiTools.count)")

        Task {
            // Construir conversación desde historial persistente + mensaje nuevo.
            // La clave de thread es el code del chip (ext_<id8>), no el label DS/CL/OP.
            let tid = chatThreads.getOrCreateThread(for: AgentChip.external(agent).agentCode)
            var conversation = ChatAgentSupport.buildApiConversation(threadId: tid, sys: sys, newUserMsg: prompt)

            var pendingTools: [String] = []

            for turn in 0..<5 {
                let result = await ChatAgentSupport.streamAPI(
                    agent: agent, key: key, apiMessages: conversation, tools: openaiTools,
                    onDelta: { [self] text in
                        self.streamMessage(text, code: code)
                    }
                )
                if let error = result.error {
                    await MainActor.run {
                        messages.append(LocalChatMessage(text: "❌ \(error)", isUser: false, agentCode: code))
                        isGenerating = false
                        streamMsgID = nil
                    }
                    return
                }

                guard let toolCalls = result.toolCalls, !toolCalls.isEmpty else {
                    // Turno casual donde el modelo alucinó un tool_call SIN texto (DeepSeek es "agentic").
                    // Reintento forzando respuesta directa en texto, sin herramientas.
                    if casual && result.text == nil {
                        conversation.append(["role": "user", "content": "Responde directamente en texto. NO invoques ninguna herramienta ni tool_call."])
                        _ = await ChatAgentSupport.streamAPI(agent: agent, key: key, apiMessages: conversation, tools: [])
                        if let last = messages.last, !last.isUser { saveMessage(last) }
                        await flushPending(text: "", tools: pendingTools, code: code)
                        await MainActor.run { isGenerating = false; streamMsgID = nil }
                        return
                    }
                    // El streaming ya agregó el mensaje. Solo guardar.
                    if result.text != nil, !(result.text?.isEmpty ?? true) {
                        if let last = messages.last, !last.isUser { saveMessage(last) }
                    }
                    await flushPending(text: "", tools: pendingTools, code: code)
                    await MainActor.run { isGenerating = false; streamMsgID = nil }
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
                    var raw = mcpExecuteForAgent(jsonRequest: ChatAgentSupport.buildMcpRequest(tokenId: agent.tokenId, toolName: tc.name, arguments: tc.args))
                    if raw.count > 1500 { raw = String(raw.prefix(1500)) + "\n…" }
                    conversation.append(["role": "tool", "tool_call_id": tc.id, "content": raw])
                }

                // Sliding window: podar tool results viejos, preservar user messages
                conversation = ChatAgentSupport.pruneConversation(conversation)
            }

            // Max turns alcanzado: forzar resumen sin tools
            await flushPending(text: "", tools: pendingTools, code: code)
            if pendingTools.count > 0 {
                await MainActor.run {
                    let thinking = LocalChatMessage(text: "● Destilando hallazgos…", isUser: false, agentCode: code, type: "thinking")
                    messages.append(thinking)
                }
                conversation.append(["role": "user", "content": "Resumí en 3-5 bullets qué encontraste y proponé siguientes pasos. NO uses herramientas (no están disponibles). Solo texto."])
                let finalResult = await ChatAgentSupport.streamAPI(
                    agent: agent, key: key, apiMessages: conversation, tools: [],
                    onDelta: { [self] text in
                        self.streamMessage(text, code: code)
                    }
                )
                // El streaming ya agregó el texto. Solo guardar.
                if finalResult.text != nil, !(finalResult.text?.isEmpty ?? true) {
                    if let last = messages.last, !last.isUser { saveMessage(last) }
                }
            }
            await MainActor.run { isGenerating = false; streamMsgID = nil }
        }
    }

    /// Streaming del texto de UN mensaje de esta sección: primer chunk → append,
    /// chunks siguientes → update por `streamMsgID` (sin duplicar ni recargar WebView).
    @MainActor
    private func streamMessage(_ fullText: String, code: String) {
        if let id = streamMsgID, let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx] = LocalChatMessage(text: fullText, isUser: false, agentCode: code)
        } else {
            let msg = LocalChatMessage(text: fullText, isUser: false, agentCode: code)
            messages.append(msg)
            streamMsgID = msg.id
        }
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

    // MARK: - Nota IA (Opciones IA para notas)

    /// Orquesta una acción de IA sobre la nota activa con el agente de ESTA sección.
    /// Sin nota activa —o si la instrucción pide explícitamente crear una nota— el resultado va a una nota nueva.
    private func runNoteAIAction(instruction: String, actionTitle: String) {
        let effectiveEnabled: Bool = {
            switch agent {
            case .local: return brain.isEnabled
            case .external(let a): return UserDefaults.standard.bool(forKey: "agent_enabled_\(a.id)")
            }
        }()
        guard effectiveEnabled else {
            messages.append(LocalChatMessage(text: "\(agent.displayName) está desactivado.", isUser: false, agentCode: agent.agentCode))
            return
        }
        let wantsNew = wantsCreateNew(instruction)
        inputText = ""
        let noteAI: NoteAIApplyInfo
        if let idx = activeTabIndex, !wantsNew {
            let tab = viewModel.tabs[idx]
            noteAI = NoteAIApplyInfo(instruction: actionTitle, noteId: tab.id, noteTitle: tab.title, originalContent: tab.content)
        } else {
            // Crear nota nueva: sin nota activa o se pidió explícitamente
            let title = noteAITitleOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            noteAI = NoteAIApplyInfo(instruction: actionTitle, noteId: nil, noteTitle: title.isEmpty ? "Nueva nota IA" : title, originalContent: "", createNew: true)
        }
        messages.append(LocalChatMessage(text: "✍️ Nota · \(actionTitle)", isUser: true, agentCode: nil))
        isGenerating = true
        generationTask = Task {
            switch agent {
            case .local:
                if noteAI.createNew {
                    // Sin contenido de nota: la instrucción (puede incluir material pegado) es la entrada
                    let prompt = "Instrucción: \(instruction)\n\nDevuelve ÚNICAMENTE el texto completo de la nueva nota con el resultado de aplicar la instrucción, sin comentarios ni prefacios."
                    sendLocal(prompt: prompt, context: "", noteAI: noteAI)
                } else {
                    // context no vacío → chatStream salta el RAG y trabaja sobre el texto de la nota
                    let prompt = "Nota activa: \(noteAI.noteTitle)\n\nInstrucción: \(instruction)\n\nDevuelve ÚNICAMENTE el texto completo resultante de aplicar la instrucción al texto en Contexto, sin comentarios ni prefacios."
                    sendLocal(prompt: prompt, context: noteAI.originalContent, noteAI: noteAI)
                }
            case .external(let a):
                let usesTools = a.writeContent && (noteAI.createNew ? !a.workspaces.isEmpty : noteInWorkspace(noteAI.noteId ?? "", a.workspaces))
                let sys = ChatAgentSupport.noteAISystemPrompt(agentName: a.name, usesTools: usesTools, createNew: noteAI.createNew)
                let user = ChatAgentSupport.noteAIUserPrompt(instruction: instruction, originalText: noteAI.originalContent, title: noteAI.noteTitle, createNew: noteAI.createNew)
                await runExternalPlan(sysPrompt: sys, userPrompt: user, agent: a, noteAI: noteAI)
            }
        }
    }

    /// Detecta si la instrucción pide explícitamente crear una nota nueva.
    private func wantsCreateNew(_ instruction: String) -> Bool {
        let l = instruction.lowercased()
        let markers = ["crea una nota", "crear una nota", "crear nota", "crea nota", "nueva nota", "nota nueva", "crea un borrador", "genera una nota", "generar una nota"]
        return markers.contains { l.contains($0) }
    }

    /// Aplica un contenido generado por IA a la nota activa según `applyMode`.
    /// Si `noteID` es nil, crea una nota nueva en el vault con el resultado.
    @MainActor
    private func applyToActiveNote(applyContent: String, instruction: String, noteID: String?) {
        if noteID == nil {
            let title = noteAITitleOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            let header = title.isEmpty ? "" : "# \(title)\n\n"
            let newContent = header + applyContent
            viewModel.createNewNote(locations: workspaceManager.allLocations, content: newContent, skipRename: true)
            // createNewNote abre la pestaña con content vacío → sincronizar la preview con el contenido real
            if let id = viewModel.activeTabId, let idx = viewModel.tabs.firstIndex(where: { $0.id == id }) {
                viewModel.tabs[idx].content = newContent
            }
            messages.append(LocalChatMessage(text: "✓ Nota nueva creada: \(title.isEmpty ? "Nueva nota IA" : title).", isUser: false, agentCode: agent.agentCode))
            return
        }
        guard let idx = activeTabIndex else {
            messages.append(LocalChatMessage(text: "⚠️ No hay nota activa para aplicar.", isUser: false, agentCode: agent.agentCode))
            return
        }
        if let noteID, viewModel.activeTabId != noteID {
            messages.append(LocalChatMessage(text: "⚠️ La nota activa cambió; no se aplicó a '\(viewModel.tabs[idx].title)'.", isUser: false, agentCode: agent.agentCode))
            return
        }
        let tab = viewModel.tabs[idx]
        let newContent: String
        switch applyMode {
        case .insertAtEnd:
            newContent = tab.content + "\n\n---\n### ✨ \(instruction)\n" + applyContent
        case .replaceAll:
            newContent = applyContent
        case .replaceSelection:
            let sel = viewModel.editorSelection
            if sel.length > 0, let range = Range(sel, in: tab.content) {
                newContent = tab.content.replacingCharacters(in: range, with: applyContent)
            } else {
                // Fallback seguro: insertar al final
                newContent = tab.content + "\n\n---\n### ✨ \(instruction)\n" + applyContent
                messages.append(LocalChatMessage(text: "ℹ️ Sin selección activa: se insertó al final.", isUser: false, agentCode: agent.agentCode))
            }
        }
        viewModel.tabs[idx].content = newContent
        viewModel.saveActiveTab(locations: workspaceManager.allLocations)
        messages.append(LocalChatMessage(text: "✓ Aplicado a '\(tab.title)' (\(applyMode.rawValue)).", isUser: false, agentCode: agent.agentCode))
    }

    /// Conecta el botón "Aplicar a la nota" del mensaje con la aplicación real.
    private func handleApplyRequest(messageID: String) {
        guard let msg = messages.first(where: { $0.id.uuidString == messageID }), let content = msg.applyContent else { return }
        applyToActiveNote(applyContent: content, instruction: msg.applyInstruction ?? "IA", noteID: msg.applyNoteId)
    }

    /// Marca el último mensaje como aplicable (botón "Aplicar a la nota") o lo auto-aplica si el toggle está activo.
    @MainActor
    private func finalizeNoteAIMessage(noteAI: NoteAIApplyInfo, content: String, index: Int?, wroteActiveNote: Bool) {
        if wroteActiveNote {
            messages.append(LocalChatMessage(text: "✍️ El agente escribió la nota directamente (\(noteAI.noteTitle)).", isUser: false, agentCode: agent.agentCode))
            return
        }
        let clean = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            messages.append(LocalChatMessage(text: "⚠️ El agente no devolvió contenido editable.", isUser: false, agentCode: agent.agentCode))
            return
        }
        let parsed = ChatAgentSupport.parseNoteAIResult(clean)
        if let i = index, messages.indices.contains(i) {
            messages[i].applyContent = parsed
            messages[i].applyInstruction = noteAI.instruction
            messages[i].applyNoteId = noteAI.noteId
        }
        if noteAIAutoApply {
            applyToActiveNote(applyContent: parsed, instruction: noteAI.instruction, noteID: noteAI.noteId)
            if let i = index, messages.indices.contains(i) { messages[i].applyContent = nil }
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
    var preserveAnchorId: Int64? = nil   // anteponer mensajes sin perder el scroll (ancla = primer visible previo)
    var pendingScrollToId: Int64? = nil  // saltar y resaltar un mensaje (búsqueda)
    var onApplyNote: ((String) -> Void)? = nil
    var onRequestOlder: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "noteAIApply")
        ucc.add(context.coordinator, name: "chatRequestOlder")
        ucc.add(context.coordinator, name: "chatCopy")
        config.userContentController = ucc
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onApplyNote = onApplyNote
        context.coordinator.onRequestOlder = onRequestOlder
        // Clave de contenido: solo recargar el HTML si los mensajes o los anclajes cambiaron.
        // Sin esto, cada re-evaluación del body (p. ej. al teclear en el input) recarga todo
        // el webview y el frame transparente previo queda de "fantasma" detrás del texto nuevo.
        let key = renderKey()
        guard key != context.coordinator.lastRenderKey else { return }
        context.coordinator.lastRenderKey = key
        webView.loadHTMLString(buildHTML(), baseURL: nil)
    }

    private func renderKey() -> String {
        var k = ""
        for msg in messages {
            k += "\(msg.id)|\(msg.isUser)|\(msg.type ?? "")|\(msg.persistedId.map(String.init) ?? "")|\(msg.effectiveDate.timeIntervalSince1970)|\(msg.text)\n"
        }
        k += "anchor=\(preserveAnchorId.map(String.init) ?? "nil")|target=\(pendingScrollToId.map(String.init) ?? "nil")"
        return k
    }

    private func buildHTML() -> String {
        // Umbral de "nueva sesión" tipo WhatsApp: gap > 2h entre mensajes → separador de fecha
        let sessionGap: TimeInterval = 2 * 60 * 60
        let dateFmt: DateFormatter = {
            let f = DateFormatter(); f.dateFormat = "d MMM yyyy, HH:mm"; return f
        }()

        func renderMessage(_ msg: LocalChatMessage) -> String {
            let side = msg.isUser ? "user" : "agent"
            let agentLabel = msg.isUser ? "Tú" : (msg.agentCode ?? "")
            let agentColor = (msg.agentCode == "LC") ? "#34c759" : "#af52de"
            // data-mid = id persistido en DuckDB (ancla de lazy loading y salto de búsqueda)
            let mid = msg.persistedId.map(String.init) ?? ""
            let midAttr = mid.isEmpty ? "" : " data-mid=\"\(mid)\""

            // Mensaje de "pensando…"
            if msg.type == "thinking" {
                return """
                <div class="msg agent thinking"\(midAttr)>
                  <div class="agent-label" style="color:\(agentColor)">\(agentLabel)</div>
                  <div class="bubble thinking-bubble">\(escaped(msg.text))</div>
                </div>
                """
            }

            // Marcador de ancla (sesión iniciada, reset)
            if msg.type == "anchor" {
                return """
                <div class="anchor-marker"><span>\(escaped(msg.text))</span></div>
                """
            }

            // Colapsable de herramientas
            if msg.type == "tools" {
                let toolList = msg.toolNames.map { "<li>\(escaped($0))</li>" }.joined()
                return """
                <div class="msg agent tools-section"\(midAttr)>
                  <div class="agent-label" style="color:\(agentColor)">\(agentLabel)</div>
                  <details class="tools-details">
                    <summary class="tools-summary">\(escaped(msg.text))</summary>
                    <ul class="tools-list">\(toolList)</ul>
                  </details>
                </div>
                <div class="sep"></div>
                """
            }

            // Escapar comillas para atributo data-text
            let safeText = msg.text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")

            // Botón "Aplicar a la nota" (o "Crear nota nueva") para resultados de Opciones IA para notas
            var applyBtn = ""
            if msg.applyContent != nil {
                let applyLabel = msg.applyNoteId == nil ? "Crear nota nueva" : "Aplicar a la nota"
                applyBtn = """
                <button class="apply-btn" onclick="window.webkit.messageHandlers.noteAIApply.postMessage('\(msg.id.uuidString)')">\(applyLabel)</button>
                """
            }

            return """
            <div class="msg \(side)"\(midAttr) data-text="\(safeText)">
              <div class="agent-label" style="color:\(agentColor)">\(agentLabel)</div>
              <div class="bubble">\(escaped(msg.text))</div>
              <div class="msg-actions">
                \(applyBtn)
                <button class="copy-btn" onclick="copyMsg(this, 'plain')" title="Copiar texto">
                  <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
                </button>
                <button class="copy-btn md-copy-btn" onclick="copyMsg(this, 'md')" title="Copiar Markdown">
                  <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>
                </button>
              </div>
            </div>
            <div class="sep"></div>
            """
        }

        var msgsHTML = ""
        for (i, msg) in messages.enumerated() {
            // Separador de sesión cuando hay un salto de tiempo respecto al mensaje anterior
            if i > 0, msg.effectiveDate.timeIntervalSince(messages[i - 1].effectiveDate) > sessionGap {
                msgsHTML += "<div class=\"anchor-marker\"><span>── \(dateFmt.string(from: msg.effectiveDate)) ──</span></div>"
            }
            msgsHTML += renderMessage(msg)
        }

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

          /* Anchor markers (session start, reset) */
          .anchor-marker { text-align: center; margin: 16px 0; }
          .anchor-marker span { font-size: 0.75em; color: rgba(128,128,128,0.6); background: rgba(128,128,128,0.08); padding: 4px 16px; border-radius: 12px; }

          /* Copy button */
          .msg-actions { margin-top: 2px; text-align: right; opacity: 0; transition: opacity 0.15s; }
          .msg:hover .msg-actions, .agent:hover .msg-actions { opacity: 1; }
          .copy-btn { background: none; border: none; cursor: pointer; padding: 2px 4px; color: rgba(128,128,128,0.4); }
          .copy-btn:hover { color: rgba(128,128,128,0.8); }
          .md-copy-btn { margin-left: 2px; padding-left: 5px; border-left: 1px solid rgba(128,128,128,0.15); }
          .apply-btn { background: #34c759; color: #fff; border: none; cursor: pointer; font-size: 11px; font-weight: 600; padding: 4px 10px; border-radius: 6px; margin-right: 6px; }
          .apply-btn:hover { filter: brightness(1.1); }

          /* Resaltado al saltar a un resultado de búsqueda */
          .msg.highlight .bubble { animation: hlFade 2.2s ease-out; }
          @keyframes hlFade { 0% { background: rgba(255,200,0,0.5); box-shadow: 0 0 0 4px rgba(255,200,0,0.3); } 100% { background: transparent; box-shadow: none; } }

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

          // Chat infinito: al llegar arriba, pedir la página anterior.
          // El listener se "arma" con un pequeño retraso tras el loadHTMLString:
          // el reload empieza en scrollY=0 y el scrollToMid del ancla genera un
          // scroll event que, si estuviera armado, dispararía una carga espuria
          // en bucle. Armar luego evita re-pedir mientras se restaura la posición.
          var __loadingOlder = false;
          setTimeout(function() {
            window.addEventListener('scroll', function() {
              if (window.scrollY < 120 && !__loadingOlder) {
                __loadingOlder = true;
                window.webkit.messageHandlers.chatRequestOlder.postMessage('');
              }
            }, { passive: true });
          }, 500);

          function copyMsg(btn, mode) {
            var msg = btn.closest('.msg');
            var text;
            if (mode === 'md') {
              // Copiar markdown original (el atributo data-text se decodifica automáticamente al leerlo)
              text = msg.getAttribute('data-text') || '';
            } else {
              // Copiar texto plano renderizado
              var bubble = msg.querySelector('.bubble');
              text = bubble ? bubble.textContent : '';
            }
            window.webkit.messageHandlers.chatCopy.postMessage(text);
            var origHTML = btn.innerHTML;
            btn.innerHTML = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="20 6 9 17 4 12"/></svg>';
            setTimeout(function() { btn.innerHTML = origHTML; }, 1200);
          }
          function scrollToBottom() { window.scrollTo(0, document.body.scrollHeight); }
          function scrollToMid(id) {
            var el = document.querySelector('[data-mid="' + id + '"]');
            // block:'start' (no 'center'): el ancla era el primer mensaje visible
            // previo; dejarlo arriba es fiel a la posición que el usuario tenía,
            // sin el "salto visual" de centrarlo.
            if (el) el.scrollIntoView({ block: 'start' });
            else scrollToBottom();
          }

          var anchorId = \(preserveAnchorId.map(String.init) ?? "null");
          var targetId = \(pendingScrollToId.map(String.init) ?? "null");
          if (targetId) {
            // Salto desde búsqueda: centrar y resaltar el mensaje
            setTimeout(function() {
              var el = document.querySelector('[data-mid="' + targetId + '"]');
              if (el) {
                el.scrollIntoView({ block: 'center' });
                el.classList.add('highlight');
                setTimeout(function() { el.classList.remove('highlight'); }, 2300);
              } else { scrollToBottom(); }
            }, 0);
          } else if (anchorId) {
            // Anteponer mensajes viejos: anclar al primer mensaje visible previo
            setTimeout(function() { scrollToMid(anchorId); }, 0);
          } else {
            requestAnimationFrame(scrollToBottom);
          }
        </script>
        </body></html>
        """
    }

    class Coordinator: NSObject, WKScriptMessageHandler {
        var onApplyNote: ((String) -> Void)? = nil
        var onRequestOlder: (() -> Void)? = nil
        // Clave del último HTML renderizado: si el contenido no cambió, se evita
        // recargar loadHTMLString (el body de LocalChatView re-evalúa en cada tecla
        // del input y sin esta cache el webview transparente mostraba "textos en el fondo").
        var lastRenderKey: String = ""

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "noteAIApply", let id = message.body as? String {
                onApplyNote?(id)
            } else if message.name == "chatRequestOlder" {
                onRequestOlder?()
            } else if message.name == "chatCopy", let text = message.body as? String, !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}

// MARK: - Permissions Bar

struct PermissionsBar: View {
    let agent: AgentChip
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
                    .lineLimit(1)   // no rompe línea al comprimirse
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
                        .lineLimit(1)   // no rompe línea al comprimirse
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
            .lineLimit(1)   // no rompe línea al comprimirse
    }
}

// MARK: - Resultados de búsqueda (chat infinito)

struct ChatSearchResultsList: View {
    let results: [PersistentMessage]
    var onSelect: (Int64) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(results.count) resultado(s)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)
                ForEach(results, id: \.id) { msg in
                    Button(action: {
                        if let id = msg.id { onSelect(id) }
                    }) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(snippet(msg.content))
                                .font(.caption)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundColor(.primary)
                            Text(String(msg.timestamp.prefix(16)))
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    Divider().opacity(0.25)
                }
            }
        }
    }

    private func snippet(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 90 ? String(flat.prefix(90)) + "…" : flat
    }
}
