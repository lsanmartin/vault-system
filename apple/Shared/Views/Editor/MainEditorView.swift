import SwiftUI

struct MainEditorView: View {
    @StateObject var viewModel = EditorViewModel()
    @EnvironmentObject var workspaceManager: WorkspaceManager
    
    // Colores para el modo Noche (IR)
    private let nightBg = Color.black
    private let nightText = Color(red: 0.7, green: 0, blue: 0) // Rojo profundo
    private let nightAccent = Color.red
    
    var body: some View {
        NavigationSplitView {
            // COLUMNA 1: Sidebar de Workspaces
            List(selection: $viewModel.selectedLocationId) {
                Section("Workspaces") {
                    ForEach(workspaceManager.locations) { location in
                        NavigationLink(value: location.id) {
                            Label(location.name, systemImage: "folder.fill")
                                .foregroundColor(viewModel.selectedTheme == .night ? nightText : .primary)
                        }
                    }
                    .onDelete(perform: workspaceManager.removeLocation)
                }
                
                Section("Inteligencia") {
                    Toggle(isOn: $viewModel.showSystemFiles) {
                        Label("Meta-Memorias", systemImage: "brain.head.profile")
                            .foregroundColor(viewModel.selectedTheme == .night ? nightText : .primary)
                    }
                    .toggleStyle(.switch)
                    .tint(viewModel.selectedTheme == .night ? .red : .accentColor)
                }
                
                Section("Apariencia") {
                    Picker(selection: $viewModel.selectedTheme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.rawValue).tag(theme)
                                .foregroundColor(viewModel.selectedTheme == .night ? nightText : .primary)
                        }
                    } label: {
                        Label("Tema", systemImage: "paintbrush")
                            .foregroundColor(viewModel.selectedTheme == .night ? nightText : .primary)
                    }
                }
            }
            .navigationTitle("Vault System")
            .accentColor(viewModel.selectedTheme == .night ? .red : .accentColor)
            .scrollContentBackground(viewModel.selectedTheme == .night ? .hidden : .visible)
            .background(viewModel.selectedTheme == .night ? nightBg : Color.clear)
            .listStyle(.sidebar)
            
            .onChange(of: viewModel.selectedLocationId) {
                viewModel.refreshNotes(locations: workspaceManager.locations)
            }
            .onChange(of: viewModel.showSystemFiles) {
                viewModel.refreshNotes(locations: workspaceManager.locations)
            }
            .onChange(of: viewModel.selectedTheme) {
                // Forzar refresco al cambiar tema
                viewModel.refreshNotes(locations: workspaceManager.locations)
            }
        } content: {
            // COLUMNA 2: Lista de Notas filtrada
            VStack(spacing: 0) {
                TextField("Buscar...", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding()
                    .onChange(of: viewModel.searchText) {
                        viewModel.refreshNotes(locations: workspaceManager.locations)
                    }
                
                List(viewModel.notes, id: \.id) { note in
                    VStack(alignment: .leading) {
                        Text(note.title)
                            .font(.headline)
                            .foregroundColor(viewModel.selectedTheme == .night ? nightText : .primary)
                        Text(note.path)
                            .font(.caption2)
                            .foregroundColor(viewModel.selectedTheme == .night ? nightText.opacity(0.7) : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.openNote(note)
                    }
                    .listRowBackground(viewModel.selectedTheme == .night ? nightBg : nil)
                }
                .listStyle(.inset)
                .scrollContentBackground(viewModel.selectedTheme == .night ? .hidden : .visible)
                .background(viewModel.selectedTheme == .night ? nightBg : Color.clear)
            }
            .navigationTitle("Notas")
            
        } detail: {
            // COLUMNA 3: Editor con Pestañas
            if let activeId = viewModel.activeTabId {
                VStack(spacing: 0) {
                    // Tab Bar
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(viewModel.tabs) { tab in
                                TabHeaderView(tab: tab, isActive: tab.id == activeId, selectedTheme: viewModel.selectedTheme) {
                                    viewModel.activeTabId = tab.id
                                } onClose: {
                                    if let index = viewModel.tabs.firstIndex(where: { $0.id == tab.id }) {
                                        viewModel.closeTab(at: IndexSet(integer: index))
                                    }
                                }
                            }
                        }
                    }
                    .background(viewModel.selectedTheme == .night ? Color.black : Color.secondary.opacity(0.1))
                    
                    // Editor Content
                    if let index = viewModel.tabs.firstIndex(where: { $0.id == activeId }) {
                        EditorAreaView(tab: $viewModel.tabs[index], selectedTheme: viewModel.selectedTheme)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .toolbar {
                                ToolbarItemGroup(placement: .primaryAction) {
                                    Button(action: { viewModel.saveActiveTab(locations: workspaceManager.locations) }) {
                                        Label("Save", systemImage: "checkmark.circle")
                                    }
                                    .keyboardShortcut("s", modifiers: .command)
                                    
                                    Button(action: { viewModel.togglePreview() }) {
                                        Label("Preview", systemImage: "eye")
                                    }
                                    .keyboardShortcut("r", modifiers: .command)
                                }
                            }
                    }
                }
                .background(viewModel.selectedTheme == .night ? nightBg : Color.clear)
            } else {
                ContentUnavailableView("Selecciona una nota", systemImage: "text.document", description: Text("Haz clic en una nota para comenzar a editar."))
                    .background(viewModel.selectedTheme == .night ? nightBg : Color.clear)
                    .foregroundColor(viewModel.selectedTheme == .night ? nightText : .secondary)
            }
        }
        .onAppear {
            viewModel.syncAll(locations: workspaceManager.locations)
            let paths = workspaceManager.locations.map { $0.path }
            let ignorePatterns = viewModel.showSystemFiles ? [] : [
                "_memory.md", "_metadata.md", "_specs.md", "_lore.md",
                "00-Sistema", "01-Diario", "05-IA-Drafts",
                "agent.md", ".git", ".obsidian"
            ]
            viewModel.launchWatcher(paths: paths, ignorePatterns: ignorePatterns)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshNotes(locations: workspaceManager.locations)
        }
        .preferredColorScheme(viewModel.selectedTheme == .light ? .light : (viewModel.selectedTheme == .dark || viewModel.selectedTheme == .night ? .dark : nil))
        .background(viewModel.selectedTheme == .night ? nightBg : Color.clear)
    }
}

struct TabHeaderView: View {
    let tab: TabItem
    let isActive: Bool
    let selectedTheme: AppTheme
    let onSelect: () -> Void
    let onClose: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Text(tab.title)
                .font(.subheadline)
                .fontWeight(isActive ? .bold : .regular)
                .foregroundColor(selectedTheme == .night ? (isActive ? .red : Color(red: 0.5, green: 0, blue: 0)) : .primary)
            
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0.5)
            .foregroundColor(selectedTheme == .night ? .red : .primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isActive ? (selectedTheme == .night ? Color(red: 0.1, green: 0, blue: 0) : Color(NSColor.windowBackgroundColor)) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .overlay(Divider().background(selectedTheme == .night ? Color.red.opacity(0.3) : Color.clear).frame(maxWidth: .infinity, maxHeight: 1), alignment: .bottom)
    }
}

struct EditorAreaView: View {
    @Binding var tab: TabItem
    let selectedTheme: AppTheme
    
    // Función mejorada para renderizado Markdown -> HTML con soporte de temas
    private func renderMarkdown(_ content: String, theme: AppTheme) -> String {
        var themeCSS = ""
        
        switch theme {
        case .light:
            themeCSS = ":root { color-scheme: light; --bg: #ffffff; --text: #333; --accent: #2b82d9; --code-bg: #8882; --code-text: #d94181; }"
        case .dark:
            themeCSS = ":root { color-scheme: dark; --bg: #1e1e1e; --text: #e0e0e0; --accent: #58a6ff; --code-bg: #8883; --code-text: #ff79c6; }"
        case .night:
            // Modo Infrarrojo (IR): Negro absoluto y Rojos para preservar visión nocturna
            themeCSS = """
            :root { 
                color-scheme: dark; 
                --bg: #000000; 
                --text: #ff3b30; 
                --accent: #ff453a; 
                --code-bg: #1a0505; 
                --code-text: #ff9f0a; 
            }
            body { background-color: #000 !important; color: #ff3b30 !important; }
            h1, h2, h3, h4 { color: #ff453a !important; border-bottom: 1px solid #ff453a33 !important; }
            pre, code { background-color: #1a0505 !important; color: #ff9f0a !important; }
            blockquote { border-left: 4px solid #ff453a !important; color: #8e0000 !important; }
            a { color: #ff453a !important; }
            """
        case .system:
            themeCSS = """
            :root { 
                color-scheme: light dark; 
                --bg: canvas; 
                --text: canvastext; 
                --accent: #2b82d9; 
                --code-bg: rgba(128, 128, 128, 0.1); 
                --code-text: #d94181; 
            }
            @media (prefers-color-scheme: dark) {
                :root {
                    --bg: #1e1e1e;
                    --text: #e0e0e0;
                    --accent: #58a6ff;
                    --code-bg: rgba(255, 255, 255, 0.1);
                    --code-text: #ff79c6;
                }
                body { background-color: #1e1e1e !important; color: #e0e0e0 !important; }
            }
            """
        }

        let style = """
        <style>
            \(themeCSS)
            body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
                padding: 30px;
                line-height: 1.6;
                color: var(--text);
                background-color: var(--bg);
                max-width: 900px;
                margin: 0 auto;
            }
            h1, h2, h3, h4 {
                border-bottom: 1px solid #7774;
                padding-bottom: 0.3em;
                margin-top: 1.5em;
                color: var(--accent);
            }
            pre {
                background-color: var(--code-bg);
                padding: 16px;
                border-radius: 8px;
                overflow: auto;
                font-family: 'SF Mono', ui-monospace, monospace;
            }
            code {
                font-family: 'SF Mono', ui-monospace, monospace;
                background-color: var(--code-bg);
                padding: 0.2em 0.4em;
                border-radius: 4px;
                color: var(--code-text);
            }
            blockquote {
                border-left: 4px solid var(--accent);
                padding-left: 1em;
                color: #777;
                margin-left: 0;
            }
            a { color: var(--accent); text-decoration: none; }
            a:hover { text-decoration: underline; }
            hr { border: 0; border-top: 1px solid #7774; margin: 2em 0; }
        </style>
        """
        
        let html = content
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "### ", with: "<h3>")
            .replacingOccurrences(of: "## ", with: "<h2>")
            .replacingOccurrences(of: "# ", with: "<h1>")
        
        return "<html><head><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"></head><style>\(style)</style><body>\(html)</body></html>"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                
                Toggle("HTML", isOn: $tab.isHTML)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .foregroundColor(selectedTheme == .night ? .red : .primary)
                    .tint(selectedTheme == .night ? .red : .accentColor)
                
                Button(tab.isPreviewMode ? "Editar" : "Ver") {
                    tab.isPreviewMode.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundColor(selectedTheme == .night ? .red : .primary)
            }
            .padding(8)
            .background(selectedTheme == .night ? Color.black : Color.secondary.opacity(0.05))
            
            if tab.isPreviewMode {
                // Previsualización con WebView (Markdown/HTML)
                WebView(htmlContent: tab.isHTML ? tab.content : renderMarkdown(tab.content, theme: selectedTheme))
                    .id("\(tab.id)-\(selectedTheme.rawValue)") 
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $tab.content)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(selectedTheme == .night ? .hidden : .visible)
                    .background(selectedTheme == .night ? Color.black : Color.clear)
                    .foregroundColor(selectedTheme == .night ? Color(red: 0.8, green: 0, blue: 0) : .primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
