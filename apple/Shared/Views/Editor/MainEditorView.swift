import SwiftUI

struct NoteCard: View {
    let note: NoteRecord
    let isSelected: Bool
    let selectedTheme: AppTheme
    let workspacePath: String?
    let locations: [VaultLocation]
    @ObservedObject var viewModel: EditorViewModel
    
    @State private var isShowingRename = false
    @State private var newName = ""
    
    private var displayPath: String {
        if let root = workspacePath, note.path.hasPrefix(root) {
            let relative = String(note.path.dropFirst(root.count))
            let cleaned = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
            return cleaned
        }
        return note.path
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.text.fill")
                    .foregroundColor(EditorViewModel.macControlIcon)
                    .font(.system(size: 12))
                Spacer()
                Circle().fill(EditorViewModel.macAccent).frame(width: 4, height: 4)
            }
            Text(note.title)
                .font(.headline)
                .lineLimit(2)
                .foregroundColor(EditorViewModel.macPrimaryText)
            
            Spacer(minLength: 4)
            Text(displayPath)
                .font(.system(size: 9, design: .monospaced))
                .lineLimit(1)
                .foregroundColor(EditorViewModel.macSecondaryText)
        }
        .padding(12).frame(height: 110).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "1A1A1A")) 
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? EditorViewModel.macAccent : Color.white.opacity(0.05), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            let extend = NSEvent.modifierFlags.contains(.shift)
            let toggle = NSEvent.modifierFlags.contains(.command)
            viewModel.selectItem(note, extend: extend, toggle: toggle)
        }
        .contextMenu {
            if viewModel.selectedItemIds.count > 1 {
                Button(role: .destructive) {
                    viewModel.deleteSelectedItems(locations: locations)
                } label: { Label("Eliminar \(viewModel.selectedItemIds.count) elementos", systemImage: "trash") }
            } else {
                Button {
                    newName = note.title
                    isShowingRename = true
                } label: { Label("Renombrar", systemImage: "pencil") }
                
                Button(role: .destructive) { 
                    viewModel.selectItem(note)
                    viewModel.deleteSelectedItems(locations: locations) 
                } label: { Label("Eliminar", systemImage: "trash") }
            }
        }
        .alert("Renombrar Nota", isPresented: $isShowingRename) {
            TextField("Nuevo nombre", text: $newName)
            Button("Cancelar", role: .cancel) { }
            Button("Guardar") { viewModel.performRename(item: note, newName: newName, locations: locations) }
        }
    }
}

// MARK: - Main Columns

struct SidebarColumn: View {
    @ObservedObject var viewModel: EditorViewModel
    @EnvironmentObject var workspaceManager: WorkspaceManager
    
    var body: some View {
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
        .background(EditorViewModel.macSidebar)
        .scrollContentBackground(.hidden)
    }
}

struct MainContentColumn: View {
    @ObservedObject var viewModel: EditorViewModel
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var dragWidth: CGFloat = 0
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            if viewModel.layoutMode == .list {
                ScrollView {
                    VaultTreeView(viewModel: viewModel, locations: workspaceManager.locations, showNotes: true)
                        .padding(.vertical, 8)
                }
                .background(EditorViewModel.macBackground)
            } else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Explorar")
                            .font(.caption).bold().opacity(0.5)
                            .foregroundColor(EditorViewModel.macSecondaryText)
                            .padding([.horizontal, .top])
                            .padding(.bottom, 8)
                        
                        ScrollView {
                            VaultTreeView(viewModel: viewModel, locations: workspaceManager.locations, showNotes: false)
                        }
                    }
                    .frame(width: CGFloat(viewModel.tacticalSidebarWidth))
                    .background(EditorViewModel.macBackground)
                    .overlay(
                        Rectangle()
                            .fill(Color.black.opacity(0.2))
                            .frame(width: 1),
                        alignment: .trailing
                    )

                    ZStack {
                        Rectangle().fill(Color.black.opacity(0.3)).frame(width: 1)
                        Rectangle().fill(Color.clear).frame(width: 8)
                            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let newWidth = CGFloat(viewModel.tacticalSidebarWidth) + value.translation.width - dragWidth
                                viewModel.tacticalSidebarWidth = Double(max(140, min(newWidth, 450)))
                                dragWidth = value.translation.width
                            }
                            .onEnded { _ in dragWidth = 0 }
                    )

                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                            ForEach(viewModel.notes, id: \.path) { note in
                                NoteCard(note: note, isSelected: viewModel.selectedItemIds.contains(note.path), selectedTheme: viewModel.selectedTheme, workspacePath: workspaceManager.locations.first?.path, locations: workspaceManager.locations, viewModel: viewModel)
                            }
                        }.padding()
                    }
                    .frame(maxWidth: .infinity)
                    .background(EditorViewModel.macBackground)
                }
            }
        }
        .navigationTitle("Notas")
        .background(EditorViewModel.macBackground)
    }
    
    private var headerView: some View {
        VStack(spacing: 12) {
            HStack {
                if let workspace = workspaceManager.locations.first(where: { $0.id == viewModel.selectedLocationId }) {
                    Button(action: { viewModel.navigateBack() }) { 
                        Image(systemName: "chevron.left")
                            .foregroundColor(EditorViewModel.macControlIcon)
                    }
                    .buttonStyle(.borderless).disabled(viewModel.currentPath == workspace.path)
                    
                    Text(viewModel.currentPath == workspace.path ? workspace.name : URL(fileURLWithPath: viewModel.currentPath).lastPathComponent)
                        .font(.headline)
                        .foregroundColor(EditorViewModel.macPrimaryText)
                        .lineLimit(1)
                }
                Spacer()
                Picker("", selection: $viewModel.layoutMode) {
                    Image(systemName: "list.bullet").tag(LayoutMode.list)
                    Image(systemName: "square.grid.2x2").tag(LayoutMode.tactical)
                }.pickerStyle(.segmented).frame(width: 80)
            }
            HStack {
                TextField("Buscar en el vault...", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                
                Menu {
                    Picker("Ordenar", selection: $viewModel.sortOption) { ForEach(SortOption.allCases) { Text($0.rawValue).tag($0) } }
                } label: { 
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundColor(EditorViewModel.macControlIcon)
                }
                .menuStyle(.borderlessButton).fixedSize()
                
                Button(action: { viewModel.createNewNote(locations: workspaceManager.locations) }) { 
                    Image(systemName: "note.text.badge.plus")
                        .foregroundColor(EditorViewModel.macControlIcon)
                }.buttonStyle(.borderless)
                
                Button(action: { viewModel.createNewFolder(locations: workspaceManager.locations) }) { 
                    Image(systemName: "folder.badge.plus")
                        .foregroundColor(EditorViewModel.macControlIcon)
                }.buttonStyle(.borderless)
                
                if !viewModel.selectedItemIds.isEmpty {
                    Button(role: .destructive, action: { viewModel.deleteSelectedItems(locations: workspaceManager.locations) }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red.opacity(0.8))
                    }.buttonStyle(.borderless)
                }
            }
        }
        .padding()
        .background(EditorViewModel.macBackground)
    }
}

// MARK: - Recursive Tree Components

struct VaultTreeView: View {
    @ObservedObject var viewModel: EditorViewModel
    let locations: [VaultLocation]
    let showNotes: Bool
    
    var rootPath: String {
        locations.first(where: { $0.id == viewModel.selectedLocationId })?.path ?? ""
    }
    
    var rootItems: [NoteRecord] {
        let folders = viewModel.allFolders.filter { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == rootPath }
        let notes = showNotes ? viewModel.allNotes.filter { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == rootPath } : []
        return (folders + notes).sorted { $0.title.lowercased() < $1.title.lowercased() }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if rootPath.isEmpty {
                ContentUnavailableView("No Workspace", systemImage: "folder.badge.questionmark")
            } else {
                ForEach(rootItems, id: \.path) { item in
                    VaultTreeRow(item: item, viewModel: viewModel, locations: locations, showNotes: showNotes)
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

struct VaultTreeRow: View {
    let item: NoteRecord
    @ObservedObject var viewModel: EditorViewModel
    let locations: [VaultLocation]
    let showNotes: Bool
    
    @State private var isShowingRename = false
    @State private var newName = ""
    
    var isExpanded: Bool {
        viewModel.expandedPaths.contains(item.path)
    }
    
    var children: [NoteRecord] {
        guard item.isDir else { return [] }
        let subfolders = viewModel.allFolders.filter { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == item.path }
        let subnotes = showNotes ? viewModel.allNotes.filter { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == item.path } : []
        return (subfolders + subnotes).sorted { $0.title.lowercased() < $1.title.lowercased() }
    }
    
    var isSelected: Bool {
        viewModel.selectedItemIds.contains(item.path)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if item.isDir {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundColor(EditorViewModel.macSecondaryText)
                        .frame(width: 12)
                        .onTapGesture { withAnimation { viewModel.toggleExpansion(path: item.path) } }
                } else {
                    Spacer().frame(width: 12)
                }
                
                HStack(spacing: 8) {
                    Image(systemName: item.isDir ? (isExpanded ? "folder.fill" : "folder") : "doc.text")
                        .foregroundColor(item.isDir ? EditorViewModel.macAccent : EditorViewModel.macSecondaryText)
                        .font(.system(size: 12))
                    
                    Text(item.title)
                        .font(.subheadline)
                        .foregroundColor(isSelected ? EditorViewModel.macPrimaryText : EditorViewModel.macSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Spacer()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .background(isSelected ? EditorViewModel.macAccent.opacity(0.15) : Color.white.opacity(0.03))
                .cornerRadius(4)
                .onTapGesture {
                    let extend = NSEvent.modifierFlags.contains(.shift)
                    let toggle = NSEvent.modifierFlags.contains(.command)
                    
                    if item.isDir {
                        if !extend && !toggle {
                            viewModel.navigateTo(path: item.path)
                            withAnimation { viewModel.toggleExpansion(path: item.path) } 
                        } else {
                            viewModel.selectItem(item, extend: extend, toggle: toggle)
                        }
                    } else {
                        viewModel.selectItem(item, extend: extend, toggle: toggle)
                    }
                }
                .contextMenu {
                    if viewModel.selectedItemIds.count > 1 {
                         Button(role: .destructive) {
                            viewModel.deleteSelectedItems(locations: locations)
                        } label: { Label("Eliminar \(viewModel.selectedItemIds.count) elementos", systemImage: "trash") }
                    } else {
                        if item.isDir {
                            Button { viewModel.navigateTo(path: item.path); viewModel.createNewNote(locations: locations) } label: { Label("Nueva Nota aquí", systemImage: "note.text.badge.plus") }
                            Button { viewModel.navigateTo(path: item.path); viewModel.createNewFolder(locations: locations) } label: { Label("Nueva Carpeta aquí", systemImage: "folder.badge.plus") }
                            Divider()
                        }
                        
                        Button {
                            newName = item.title
                            isShowingRename = true
                        } label: { Label("Renombrar", systemImage: "pencil") }

                        Button(role: .destructive) { 
                            viewModel.selectItem(item)
                            viewModel.deleteSelectedItems(locations: locations) 
                        } label: { Label("Eliminar", systemImage: "trash") }
                    }
                }
            }
            
            if item.isDir && isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(children, id: \.path) { child in
                        VaultTreeRow(item: child, viewModel: viewModel, locations: locations, showNotes: showNotes)
                    }
                }
                .padding(.leading, 12)
            }
        }
        .alert("Renombrar \(item.isDir ? "Carpeta" : "Nota")", isPresented: $isShowingRename) {
            TextField("Nuevo nombre", text: $newName)
            Button("Cancelar", role: .cancel) { }
            Button("Guardar") { viewModel.performRename(item: item, newName: newName, locations: locations) }
        }
    }
}

struct DetailColumn: View {
    @ObservedObject var viewModel: EditorViewModel
    @EnvironmentObject var workspaceManager: WorkspaceManager
    
    var body: some View {
        if let activeId = viewModel.activeTabId, let index = viewModel.tabs.firstIndex(where: { $0.id == activeId }) {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(viewModel.tabs) { tab in
                            TabHeaderView(tab: tab, isActive: tab.id == activeId) {
                                viewModel.activeTabId = tab.id
                            } onClose: {
                                if let idx = viewModel.tabs.firstIndex(where: { $0.id == tab.id }) { viewModel.closeTab(at: IndexSet(integer: idx)) }
                            }
                        }
                    }
                }.background(EditorViewModel.macSidebar)
                EditorAreaView(tab: $viewModel.tabs[index], selectedTheme: viewModel.selectedTheme, viewModel: viewModel)
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button(action: { viewModel.saveActiveTab(locations: workspaceManager.locations) }) { Label("Save", systemImage: "checkmark.circle") }.keyboardShortcut("s", modifiers: .command)
                            Button(action: { viewModel.togglePreview() }) { Label("Preview", systemImage: "eye") }.keyboardShortcut("r", modifiers: .command)
                        }
                    }
            }
        } else {
            ZStack {
                EditorViewModel.macBackground.ignoresSafeArea()
                ContentUnavailableView("Selecciona una nota", systemImage: "text.document")
                    .opacity(0.5)
            }
        }
    }
}

struct MainEditorView: View {
    @StateObject var viewModel = EditorViewModel()
    @EnvironmentObject var workspaceManager: WorkspaceManager
    
    var body: some View {
        NavigationSplitView {
            SidebarColumn(viewModel: viewModel)
        } content: {
            MainContentColumn(viewModel: viewModel)
        } detail: {
            DetailColumn(viewModel: viewModel)
        }
        .onChange(of: viewModel.selectedLocationId) { _, _ in viewModel.refreshNotes(locations: workspaceManager.locations) }
        .onChange(of: viewModel.selectedTheme) { _, _ in viewModel.refreshNotes(locations: workspaceManager.locations) }
        .onChange(of: viewModel.searchText) { _, _ in viewModel.refreshNotes(locations: workspaceManager.locations) }
        .onChange(of: viewModel.sortOption) { _, _ in viewModel.refreshNotes(locations: workspaceManager.locations) }
        .onAppear {
            viewModel.syncAll(locations: workspaceManager.locations)
            if viewModel.selectedLocationId == nil, let first = workspaceManager.locations.first { viewModel.selectedLocationId = first.id }
            viewModel.launchWatcher(paths: workspaceManager.locations.map { $0.path }, ignorePatterns: [])
        }
    }
}

struct FileRowView: View {
    let item: NoteRecord
    @ObservedObject var viewModel: EditorViewModel
    let locations: [VaultLocation]
    
    @State private var isShowingRename = false
    @State private var newName = ""
    
    var body: some View {
        HStack {
            Image(systemName: item.isDir ? "folder.fill" : "doc.text")
                .foregroundColor(item.isDir ? EditorViewModel.macAccent : EditorViewModel.macSecondaryText)
                .font(.system(size: 14))
            
            VStack(alignment: .leading) {
                Text(item.title).font(.headline).foregroundColor(EditorViewModel.macPrimaryText)
                if !viewModel.searchText.isEmpty { 
                    Text(item.path).font(.caption2).lineLimit(1).opacity(0.6).foregroundColor(EditorViewModel.macSecondaryText) 
                }
            }
            if item.isDir { Spacer(); Image(systemName: "chevron.right").font(.system(size: 10)).opacity(0.3) }
        }
        .contentShape(Rectangle())
        .onTapGesture { 
            let extend = NSEvent.modifierFlags.contains(.shift)
            let toggle = NSEvent.modifierFlags.contains(.command)
            
            if item.isDir {
                if !extend && !toggle {
                    viewModel.navigateTo(path: item.path)
                } else {
                    viewModel.selectItem(item, extend: extend, toggle: toggle)
                }
            } else {
                viewModel.selectItem(item, extend: extend, toggle: toggle)
            }
        }
        .contextMenu {
            if viewModel.selectedItemIds.count > 1 {
                Button(role: .destructive) {
                    viewModel.deleteSelectedItems(locations: locations)
                } label: { Label("Eliminar \(viewModel.selectedItemIds.count) elementos", systemImage: "trash") }
            } else {
                if item.isDir {
                    Button { viewModel.navigateTo(path: item.path); viewModel.createNewNote(locations: locations) } label: { Label("Nueva Nota aquí", systemImage: "note.text.badge.plus") }
                    Button { viewModel.navigateTo(path: item.path); viewModel.createNewFolder(locations: locations) } label: { Label("Nueva Carpeta aquí", systemImage: "folder.badge.plus") }
                    Divider()
                }
                
                Button {
                    newName = item.title
                    isShowingRename = true
                } label: { Label("Renombrar", systemImage: "pencil") }

                Button(role: .destructive) { 
                    viewModel.selectItem(item)
                    viewModel.deleteSelectedItems(locations: locations) 
                } label: { Label("Eliminar", systemImage: "trash") }
            }
        }
        .listRowBackground(EditorViewModel.macBackground)
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.05))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

struct TabHeaderView: View {
    let tab: TabItem
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    var body: some View {
        HStack {
            Text(tab.title)
                .font(.subheadline)
                .fontWeight(isActive ? .bold : .regular)
                .foregroundColor(isActive ? EditorViewModel.macPrimaryText : EditorViewModel.macSecondaryText)
            
            Button(action: onClose) { 
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundColor(EditorViewModel.macControlIcon)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(isActive ? EditorViewModel.macBackground : EditorViewModel.macSidebar)
        .onTapGesture(perform: onSelect)
    }
}

struct EditorAreaView: View {
    @Binding var tab: TabItem
    let selectedTheme: AppTheme
    @ObservedObject var viewModel: EditorViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                /* 
                Picker("", selection: $tab.renderMode) { ForEach(RenderMode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).frame(width: 150).labelsHidden()
                .onChange(of: tab.renderMode) { _, newValue in viewModel.updateRenderMode(for: tab.id, mode: newValue) }
                */
                Button(tab.isPreviewMode ? "Editar" : "Ver") { tab.isPreviewMode.toggle() }.buttonStyle(.bordered)
            }.padding(8)
            
            if tab.isPreviewMode {
                WebView(htmlContent: generateSafeHTML(tab.content, theme: selectedTheme, mode: tab.renderMode), baseURL: URL(fileURLWithPath: tab.id).deletingLastPathComponent())
                    .id("\(tab.id)-\(tab.renderMode.rawValue)-\(selectedTheme.rawValue)")
            } else {
                CodeEditor(text: $tab.content, language: tab.language, theme: selectedTheme)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(EditorViewModel.macBackground) 
            }
        }
        .background(EditorViewModel.macBackground)
    }
    
    private func generateSafeHTML(_ content: String, theme: AppTheme, mode: RenderMode) -> String {
        let base64Content = Data(content.utf8).base64EncodedString()
        var themeCSS = ""
        switch theme {
        case .light: themeCSS = ":root { --bg: #fff; --text: #333; --accent: #2b82d9; }"
        case .dark: themeCSS = ":root { --bg: #121212; --text: rgba(240, 240, 240, 0.85); --accent: #58a6ff; }"
        case .night: themeCSS = ":root { --bg: #000; --text: #ff3b30; --accent: #ff453a; } body { background:#000; color:#ff3b30; }"
        case .system: themeCSS = "@media (prefers-color-scheme: dark) { :root { --bg: #121212; --text: rgba(240, 240, 240, 0.85); --accent: #58a6ff; } }"
        }
        
        let renderModeStr = mode.rawValue
        
        return ##"""
        <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css">
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/contrib/auto-render.min.js"></script>
        <style>\##(themeCSS) body { font-family: -apple-system, system-ui, sans-serif; padding: 2rem; line-height: 1.6; color: var(--text); background: var(--bg); max-width: 850px; margin: 0 auto; overflow-wrap: break-word; }
        img { max-width: 100%; height: auto; border-radius: 8px; } pre { background: rgba(128,128,128,0.1); padding: 1rem; border-radius: 8px; overflow: auto; }
        blockquote { border-left: 4px solid var(--accent); margin: 1.5rem 0; padding: 0.5rem 1rem; background: rgba(128,128,128,0.05); font-style: italic; color: var(--text); opacity: 0.9; }
        table { border-collapse: collapse; width: 100%; margin: 1rem 0; } th, td { border: 1px solid rgba(128,128,128,0.3); padding: 8px; text-align: left; }
        .katex { font-size: 1.1em; color: inherit !important; }</style></head><body><div id="content">Cargando...</div><script>
        function decodeUTF8Base64(b){const s=atob(b),y=new Uint8Array(s.length);for(let i=0;i<s.length;i++)y[i]=s.charCodeAt(i);return new TextDecoder('utf-8').decode(y);}
        
        function cleanLaTeX(raw) {
            let content = raw;
            if (content.includes("\\begin{document}")) {
                content = content.split("\\begin{document}")[1];
            }
            if (content.includes("\\end{document}")) {
                content = content.split("\\end{document}")[0];
            }
            content = content.replace(/\\section\{([^}]+)\}/g, "## $1");
            content = content.replace(/\\subsection\{([^}]+)\}/g, "### $1");
            content = content.replace(/\\textbf\{([^}]+)\}/g, "**$1**");
            content = content.replace(/\\textit\{([^}]+)\}/g, "_$1_");
            content = content.replace(/\\texttt\{([^}]+)\}/g, "`$1`");
            return content;
        }

        try { 
            let raw=decodeUTF8Base64("\##(base64Content)");
            const mode = "\##(renderModeStr)";
            let finalHTML=""; 
            
            const isFullHTML = raw.trim().toLowerCase().startsWith("<!doctype") || raw.trim().toLowerCase().startsWith("<html");
            const isFullLaTeX = raw.includes("\\documentclass") || raw.includes("\\begin{document}");
            
            if (mode === "HTML" || (mode === "Universal" && isFullHTML)) {
                document.getElementById('content').innerHTML = raw;
            } 
            else if (mode === "LaTeX" || (mode === "Universal" && isFullLaTeX)) {
                let bodyContent = cleanLaTeX(raw);
                const mathBlocks = [];
                const placeholder = (m) => {
                    const id = "__MATH_BLOCK_" + mathBlocks.length + "__";
                    mathBlocks.push(m);
                    return id;
                };
                
                bodyContent = bodyContent.replace(/\\begin{[^}]+}[\s\S]*?\\end{[^}]+}/g, placeholder);
                bodyContent = bodyContent.replace(/\$\$[\s\S]*?\$\$/g, placeholder);
                bodyContent = bodyContent.replace(/\$[^$]+\$/g, placeholder);
                
                finalHTML = marked.parse(bodyContent);
                
                for (let i = 0; i < mathBlocks.length; i++) {
                    const id = "__MATH_BLOCK_" + i + "__";
                    finalHTML = finalHTML.split(id).join(mathBlocks[i]);
                }
                
                document.getElementById('content').innerHTML = finalHTML;
                renderMathInElement(document.getElementById('content'), {
                    delimiters: [
                        {left: '$$', right: '$$', display: true}, {left: '$', right: '$', display: false},
                        {left: '\\(', right: '\\)', display: false}, {left: '\\[', right: '\\]', display: true},
                        {left: '\\begin{equation}', right: '\\end{equation}', display: true},
                        {left: '\\begin{align}', right: '\\end{align}', display: true},
                        {left: '\\begin{pmatrix}', right: '\\end{pmatrix}', display: true},
                        {left: '\\begin{matrix}', right: '\\end{matrix}', display: true},
                        {left: '\\begin{vmatrix}', right: '\\end{vmatrix}', display: true},
                        {left: '\\begin{cases}', right: '\\end{cases}', display: true},
                        {left: '\\begin{itemize}', right: '\\end{itemize}', display: true},
                        {left: '\\begin{enumerate}', right: '\\end{enumerate}', display: true}
                    ],
                    throwOnError: false
                });
            } else {
                finalHTML=marked.parse(raw);
                document.getElementById('content').innerHTML=finalHTML;
                renderMathInElement(document.body, {
                    delimiters: [
                        {left: '$$', right: '$$', display: true}, {left: '$', right: '$', display: false},
                        {left: '\\(', right: '\\)', display: false}, {left: '\\[', right: '\\]', display: true},
                        {left: '\\begin{equation}', right: '\\end{equation}', display: true},
                        {left: '\\begin{align}', right: '\\end{align}', display: true}
                    ],
                    throwOnError: false
                });
            }
        }catch(e){document.getElementById('content').innerHTML="<div style='color:red'>Error: "+e.message+"</div>";}
        </script></body></html>
        """##
    }
}
