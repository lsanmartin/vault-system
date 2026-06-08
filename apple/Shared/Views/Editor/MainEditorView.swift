import SwiftUI

struct MainEditorView: View {
    @StateObject var viewModel = EditorViewModel()
    @EnvironmentObject var workspaceManager: WorkspaceManager
    
    var body: some View {
        NavigationSplitView {
            List(selection: $viewModel.selectedLocationId) {
                Section("Workspaces") {
                    ForEach(workspaceManager.locations) { location in
                        NavigationLink(value: location.id) {
                            Label(location.name, systemImage: "folder.fill")
                        }
                    }
                }
                Section("Apariencia") {
                    Picker(selection: $viewModel.selectedTheme) {
                        ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0) }
                    } label: { Label("Tema", systemImage: "paintbrush") }
                }
            }
            .navigationTitle("Vault System")
            .onChange(of: viewModel.selectedLocationId) { _, _ in viewModel.refreshNotes(locations: workspaceManager.locations) }
            .onChange(of: viewModel.selectedTheme) { _, _ in viewModel.refreshNotes(locations: workspaceManager.locations) }
        } content: {
            VStack(spacing: 0) {
                // Barra de herramientas de Notas
                HStack {
                    TextField("Buscar...", text: $viewModel.searchText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: viewModel.searchText) { _, _ in viewModel.refreshNotes(locations: workspaceManager.locations) }
                    
                    Menu {
                        Picker("Ordenar por", selection: $viewModel.sortOption) {
                            ForEach(SortOption.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 14))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .onChange(of: viewModel.sortOption) { _, _ in viewModel.refreshNotes(locations: workspaceManager.locations) }

                    Button(action: { viewModel.createNewNote(locations: workspaceManager.locations) }) {
                        Image(systemName: "plus").font(.system(size: 14))
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.selectedLocationId == nil)
                }
                .padding(.horizontal)
                .padding(.top, 8)

                List(viewModel.notes, id: \.id) { note in
                    VStack(alignment: .leading) {
                        Text(note.title).font(.headline)
                        Text(note.path).font(.caption2).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.openNote(note) }
                    .contextMenu {
                        Button(role: .destructive) {
                            viewModel.deleteNote(note, locations: workspaceManager.locations)
                        } label: {
                            Label("Eliminar", systemImage: "trash")
                        }
                    }
                }.listStyle(.inset)
            }.navigationTitle("Notas")
        } detail: {
            if let activeId = viewModel.activeTabId, let index = viewModel.tabs.firstIndex(where: { $0.id == activeId }) {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(viewModel.tabs) { tab in
                                TabHeaderView(tab: tab, isActive: tab.id == activeId) {
                                    viewModel.activeTabId = tab.id
                                } onClose: {
                                    if let idx = viewModel.tabs.firstIndex(where: { $0.id == tab.id }) {
                                        viewModel.closeTab(at: IndexSet(integer: idx))
                                    }
                                }
                            }
                        }
                    }.background(Color.secondary.opacity(0.1))
                    
                    EditorAreaView(tab: $viewModel.tabs[index], selectedTheme: viewModel.selectedTheme, viewModel: viewModel)
                        .toolbar {
                            ToolbarItemGroup(placement: .primaryAction) {
                                Button(action: { viewModel.saveActiveTab(locations: workspaceManager.locations) }) {
                                    Label("Save", systemImage: "checkmark.circle")
                                }.keyboardShortcut("s", modifiers: .command)
                                Button(action: { viewModel.togglePreview() }) {
                                    Label("Preview", systemImage: "eye")
                                }.keyboardShortcut("r", modifiers: .command)
                            }
                        }
                }
            } else {
                ContentUnavailableView("Selecciona una nota", systemImage: "text.document")
            }
        }
        .onAppear {
            viewModel.syncAll(locations: workspaceManager.locations)
            viewModel.launchWatcher(paths: workspaceManager.locations.map { $0.path }, ignorePatterns: [])
        }
    }
}

struct TabHeaderView: View {
    let tab: TabItem
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    var body: some View {
        HStack {
            Text(tab.title).font(.subheadline).fontWeight(isActive ? .bold : .regular)
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(isActive ? Color(NSColor.windowBackgroundColor) : Color.clear)
        .onTapGesture(perform: onSelect)
    }
}

struct EditorAreaView: View {
    @Binding var tab: TabItem
    let selectedTheme: AppTheme
    @ObservedObject var viewModel: EditorViewModel
    
    private func generateSafeHTML(_ content: String, theme: AppTheme, mode: RenderMode) -> String {
        let base64Content = Data(content.utf8).base64EncodedString()
        
        var themeCSS = ""
        switch theme {
        case .light: themeCSS = ":root { --bg: #fff; --text: #333; --accent: #2b82d9; }"
        case .dark: themeCSS = ":root { --bg: #1e1e1e; --text: #e0e0e0; --accent: #58a6ff; }"
        case .night: themeCSS = ":root { --bg: #000; --text: #ff3b30; --accent: #ff453a; } body { background:#000; color:#ff3b30; }"
        case .system: themeCSS = "@media (prefers-color-scheme: dark) { :root { --bg: #1e1e1e; --text: #e0e0e0; --accent: #58a6ff; } }"
        }

        let isHTML = mode == .html
        let enableMath = mode == .latex

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
            <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css">
            <script src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js"></script>
            <script src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/contrib/auto-render.min.js"></script>
            <style>
                \(themeCSS)
                body { font-family: -apple-system, system-ui, sans-serif; padding: 2rem; line-height: 1.6; color: var(--text); background: var(--bg); max-width: 850px; margin: 0 auto; overflow-wrap: break-word; }
                img { max-width: 100%; height: auto; border-radius: 8px; }
                pre { background: rgba(128,128,128,0.1); padding: 1rem; border-radius: 8px; overflow: auto; }
                blockquote { border-left: 4px solid var(--accent); margin: 1.5rem 0; padding: 0.5rem 1rem; background: rgba(128,128,128,0.05); font-style: italic; color: var(--text); opacity: 0.9; }
                table { border-collapse: collapse; width: 100%; margin: 1rem 0; }
                th, td { border: 1px solid rgba(128,128,128,0.3); padding: 8px; text-align: left; }
                .katex { font-size: 1.1em; color: inherit !important; }
            </style>
        </head>
        <body>
            <div id="content">Cargando...</div>
            <script>
                function decodeUTF8Base64(base64) {
                    const binaryString = atob(base64);
                    const bytes = new Uint8Array(binaryString.length);
                    for (let i = 0; i < binaryString.length; i++) {
                        bytes[i] = binaryString.charCodeAt(i);
                    }
                    return new TextDecoder('utf-8').decode(bytes);
                }

                try {
                    const raw = decodeUTF8Base64("\(base64Content)");
                    const isHTML = \(isHTML);
                    const enableMath = \(enableMath);
                    
                    let finalHTML = "";
                    if (isHTML) {
                        finalHTML = raw;
                    } else {
                        // Usar Marked.js para un Markdown completo (incluye >, tablas, etc)
                        finalHTML = marked.parse(raw);
                    }
                    
                    document.getElementById('content').innerHTML = finalHTML;

                    if (enableMath) {
                        renderMathInElement(document.body, {
                            delimiters: [
                                {left: '$$', right: '$$', display: true},
                                {left: '$', right: '$', display: false},
                                {left: '\\\\(', right: '\\\\)', display: false},
                                {left: '\\\\[', right: '\\\\]', display: true}
                            ],
                            throwOnError: false
                        });
                    }
                    console.log("Renderizado completado con éxito");
                } catch (e) {
                    document.getElementById('content').innerHTML = "<div style='color:red'>Error de Renderizado: " + e.message + "</div>";
                    console.error(e);
                }
            </script>
        </body>
        </html>
        """
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Picker("", selection: $tab.renderMode) {
                    ForEach(RenderMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 150).labelsHidden()
                .onChange(of: tab.renderMode) { _, newValue in
                    viewModel.updateRenderMode(for: tab.id, mode: newValue)
                }
                Button(tab.isPreviewMode ? "Editar" : "Ver") { tab.isPreviewMode.toggle() }.buttonStyle(.bordered)
            }.padding(8)
            
            if tab.isPreviewMode {
                WebView(htmlContent: generateSafeHTML(tab.content, theme: selectedTheme, mode: tab.renderMode))
                    .id("\(tab.id)-\(tab.renderMode.rawValue)-\(selectedTheme.rawValue)")
            } else {
                CodeEditor(text: $tab.content, language: tab.language, theme: selectedTheme)
            }
        }
    }
}
