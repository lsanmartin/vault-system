import SwiftUI

struct NoteCard: View {
    let note: NoteRecord
    let isSelected: Bool
    let selectedTheme: AppTheme
    let workspacePath: String?
    let locations: [VaultLocation]
    @ObservedObject var viewModel: EditorViewModel
    
    
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
                    .foregroundColor(viewModel.macControlIcon)
                    .font(.system(size: 12))
                
                if viewModel.pinnedPaths.contains(note.path) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
                
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(note.title, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(viewModel.macControlIcon.opacity(0.8))
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Copiar título")
            }
            Text(note.title)
                .font(.headline)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundColor(viewModel.macPrimaryText)
            
            Spacer(minLength: 4)
            Text(displayPath)
                .font(.system(size: 9, design: .monospaced))
                .lineLimit(1)
                .foregroundColor(viewModel.macSecondaryText)
        }
        .padding(12).frame(minHeight: 110).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor)) 
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? viewModel.macAccent : Color.primary.opacity(0.1), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
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
                    viewModel.togglePin(for: note.path, locations: locations)
                } label: {
                    let isPinned = viewModel.pinnedPaths.contains(note.path)
                    Label(isPinned ? "Desfijar" : "Fijar", systemImage: isPinned ? "pin.slash" : "pin")
                }
                
                Divider()

                Button {
                    viewModel.beginRename(for: note)
                } label: { Label("Renombrar", systemImage: "pencil") }
                
                Button {
                    NSWorkspace.shared.selectFile(note.path, inFileViewerRootedAtPath: "")
                } label: { Label("Mostrar en Finder", systemImage: "folder") }
                
                Button(role: .destructive) { 
                    viewModel.selectItem(note)
                    viewModel.deleteSelectedItems(locations: locations) 
                } label: { Label("Eliminar", systemImage: "trash") }
            }
        }

    }
}

// MARK: - Main Columns

struct SidebarColumn: View {
    @ObservedObject var viewModel: EditorViewModel
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @State private var workspaceToRemove: VaultLocation?
    
    var body: some View {
        List(selection: Binding(
            get: { viewModel.selectedLocationId },
            set: { 
                if let newId = $0 { 
                    viewModel.selectedLocationId = newId 
                    DispatchQueue.main.async {
                        viewModel.searchText = ""
                        viewModel.debouncedSearchText = ""
                    }
                } 
            }
        )) {
            Section(header: HStack {
                Text("Workspaces")
                Spacer()
                Button(action: { workspaceManager.requestAccess() }) {
                    Image(systemName: "plus.circle")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Añadir nuevo workspace")
                
                if !workspaceManager.scanProgress.isEmpty {
                    Button(action: { workspaceManager.abortScanAll() }) {
                        Image(systemName: "xmark.octagon")
                            .font(.body)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Cancelar escaneo global")
                } else {
                    Button(action: { workspaceManager.triggerScanAll() }) {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Re-indexar todos los workspaces")
                }
            }) {
                if let sysLoc = workspaceManager.systemLocation {
                    NavigationLink(value: sysLoc.id) {
                        Label(sysLoc.name, systemImage: "gearshape.fill")
                            .foregroundColor(.orange)
                            .simultaneousGesture(TapGesture().onEnded {
                                viewModel.selectedLocationId = sysLoc.id
                                viewModel.resetToWorkspaceRoot(locations: workspaceManager.allLocations)
                            })
                    }
                }
                ForEach(workspaceManager.locations) { location in
                    NavigationLink(value: location.id) {
                        HStack {
                            Label(location.name, systemImage: "folder.fill")
                            Spacer()
                            
                            if let progress = workspaceManager.scanProgress[location.path] {
                                Text("\(Int(progress))%")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(viewModel.macSecondaryText)
                                    .frame(width: 24, alignment: .trailing)
                                
                                Button(action: { workspaceManager.abortScan(for: location.path) }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 4)
                                .help("Cancelar escaneo")
                            } else {
                                Button(action: { workspaceManager.triggerScan(for: location.path) }) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 4)
                                .help("Re-indexar este workspace")
                            }
                            
                            Button(action: {
                                NSWorkspace.shared.open(URL(fileURLWithPath: location.path))
                            }) {
                                Image(systemName: "folder")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 4)
                            .help("Abrir en Finder")
                        }
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded {
                            viewModel.selectedLocationId = location.id
                            viewModel.resetToWorkspaceRoot(locations: workspaceManager.allLocations)
                        })
                        .contextMenu {
                            Button(role: .destructive) {
                                workspaceToRemove = location
                            } label: {
                                Label("Desvincular Workspace", systemImage: "xmark.bin")
                            }
                        }
                    }
                }
            }
            
            Section {
                HStack(spacing: 16) {
                    Spacer()
                    
                    Button(action: {
                        viewModel.explorationFilter = .all
                    }) {
                        Image(systemName: "tray.2.fill")
                            .font(.title3)
                            .foregroundColor(viewModel.explorationFilter == .all ? viewModel.macAccent : .secondary)
                            .padding(6)
                            .background(viewModel.explorationFilter == .all ? viewModel.macAccent.opacity(0.15) : Color.clear)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("Todas las notas")
                    
                    Button(action: {
                        viewModel.explorationFilter = .recentCreated
                    }) {
                        Image(systemName: "doc.badge.plus")
                            .font(.title3)
                            .foregroundColor(viewModel.explorationFilter == .recentCreated ? viewModel.macAccent : .secondary)
                            .padding(6)
                            .background(viewModel.explorationFilter == .recentCreated ? viewModel.macAccent.opacity(0.15) : Color.clear)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("Recientes creadas")
                    
                    Button(action: {
                        viewModel.explorationFilter = .recentModified
                    }) {
                        Image(systemName: "clock.arrow.2.circlepath")
                            .font(.title3)
                            .foregroundColor(viewModel.explorationFilter == .recentModified ? viewModel.macAccent : .secondary)
                            .padding(6)
                            .background(viewModel.explorationFilter == .recentModified ? viewModel.macAccent.opacity(0.15) : Color.clear)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("Recientes editadas")
                    
                    Button(action: {
                        viewModel.explorationFilter = .pinned
                    }) {
                        Image(systemName: "pin.fill")
                            .font(.title3)
                            .foregroundColor(viewModel.explorationFilter == .pinned ? viewModel.macAccent : .secondary)
                            .padding(6)
                            .background(viewModel.explorationFilter == .pinned ? viewModel.macAccent.opacity(0.15) : Color.clear)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("Notas fijadas (Pins)")
                    
                    Spacer()
                }
                .padding(.vertical, 4)
                .listRowBackground(viewModel.macSidebar)
            }
            
            Section("Explorar") {
                Picker(selection: $viewModel.treeMode) {
                    ForEach(TreeMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                } label: { Label("Modo", systemImage: "magnifyingglass") }
                .colorMultiply(viewModel.selectedTheme == .night ? .red : .white)
                .listRowBackground(viewModel.macSidebar)

                switch viewModel.treeMode {
                case .hierarchy:
                    VaultTreeView(viewModel: viewModel, locations: workspaceManager.allLocations, showNotes: false)
                case .semantic:
                    SemanticTreeView(viewModel: viewModel)
                case .heatmap:
                    HeatmapView(viewModel: viewModel)
                }
            }
            
            Section("Apariencia") {
                Picker(selection: $viewModel.selectedTheme) {
                    ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0) }
                } label: { Label("Tema", systemImage: "paintbrush") }
                .colorMultiply(viewModel.selectedTheme == .night ? .red : .white)
                .listRowBackground(viewModel.macSidebar)
            }
        }
        .navigationTitle("Vault System")
        .background(reduceTransparency ? AnyView(viewModel.macSidebar) : AnyView(Rectangle().fill(.ultraThinMaterial)))
        .scrollContentBackground(.hidden)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("VaultScanDidFinish"))) { _ in
            viewModel.refreshNotes(locations: workspaceManager.allLocations)
        }
        .alert("Renombrar", isPresented: Binding(
            get: { viewModel.itemToRename != nil },
            set: { if !$0 { viewModel.itemToRename = nil } }
        )) {
            TextField("Nuevo nombre", text: $viewModel.newNameForRename)
                .onSubmit {
                    viewModel.commitRename(locations: workspaceManager.allLocations)
                }
            Button("Cancelar", role: .cancel) { }
            Button("Guardar") { viewModel.commitRename(locations: workspaceManager.allLocations) }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(viewModel.itemToRename?.title ?? "")
        }
        .preferredColorScheme(viewModel.selectedTheme.colorScheme)
        .tint(viewModel.macAccent)
        .foregroundColor(viewModel.macPrimaryText)
        .alert(item: $workspaceToRemove) { loc in
            Alert(
                title: Text("¿Desvincular Workspace?"),
                message: Text("¿Estás seguro de que quieres desvincular '\(loc.name)'? Esto NO borrará los archivos de tu disco duro."),
                primaryButton: .destructive(Text("Desvincular")) {
                    workspaceManager.removeLocation(id: loc.id)
                    // Volver a la raíz del sistema si era el que estaba seleccionado
                    if viewModel.selectedLocationId == loc.id {
                        viewModel.selectedLocationId = workspaceManager.systemLocation?.id
                    }
                },
                secondaryButton: .cancel(Text("Cancelar"))
            )
        }
    }
}

struct MainContentColumn: View {
    @ObservedObject var viewModel: EditorViewModel
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @FocusState private var isSearchFocused: Bool
    @Binding var isNoteHidden: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
                .contentShape(Rectangle())
                .onTapGesture { 
                    isSearchFocused = false
                    NSApp.keyWindow?.makeFirstResponder(nil) 
                }
            
            if viewModel.layoutMode == .list {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(viewModel.notes, id: \.path) { note in
                            FileRowView(item: note, viewModel: viewModel, locations: workspaceManager.allLocations)
                                .padding(.horizontal, 8)
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    if isNoteHidden { withAnimation { isNoteHidden = false } }
                                })
                                .onTapGesture {
                                    isSearchFocused = false
                                    NSApp.keyWindow?.makeFirstResponder(nil)
                                    let extend = NSEvent.modifierFlags.contains(.shift)
                                    let toggle = NSEvent.modifierFlags.contains(.command)
                                    viewModel.selectItem(note, extend: extend, toggle: toggle)
                                }
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .contextMenu {
                    Button {
                        viewModel.createNewNote(locations: workspaceManager.allLocations)
                    } label: {
                        Label("Nueva Nota", systemImage: "note.text.badge.plus")
                    }
                    Button {
                        viewModel.createNewFolder(locations: workspaceManager.allLocations)
                    } label: {
                        Label("Nueva Carpeta", systemImage: "folder.badge.plus")
                    }
                }
                .background(
                    viewModel.macBackground
                        .contentShape(Rectangle())
                        .onTapGesture { 
                            isSearchFocused = false
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            viewModel.selectedItemIds.removeAll()
                        }
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                        ForEach(viewModel.notes, id: \.path) { note in
                            NoteCard(note: note, isSelected: viewModel.selectedItemIds.contains(note.path), selectedTheme: viewModel.selectedTheme, workspacePath: workspaceManager.allLocations.first?.path, locations: workspaceManager.allLocations, viewModel: viewModel)
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    if isNoteHidden { withAnimation { isNoteHidden = false } }
                                })
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity)
                .contextMenu {
                    Button {
                        viewModel.createNewNote(locations: workspaceManager.allLocations)
                    } label: {
                        Label("Nueva Nota", systemImage: "note.text.badge.plus")
                    }
                    Button {
                        viewModel.createNewFolder(locations: workspaceManager.allLocations)
                    } label: {
                        Label("Nueva Carpeta", systemImage: "folder.badge.plus")
                    }
                }
                .background(
                    viewModel.macBackground
                        .contentShape(Rectangle())
                        .onTapGesture { 
                            isSearchFocused = false
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            viewModel.selectedItemIds.removeAll()
                        }
                )
            }
        }
        .navigationTitle("Notas")
        .background(reduceTransparency ? AnyView(viewModel.macBackground) : AnyView(Rectangle().fill(.ultraThinMaterial)))
        .onChange(of: viewModel.selectedItemIds) { 
            DispatchQueue.main.async {
                isSearchFocused = false 
            }
        }
        .onChange(of: viewModel.selectedLocationId) { 
            DispatchQueue.main.async {
                isSearchFocused = false 
            }
        }
        .background(
            Button(action: {
                isSearchFocused = true
            }) { EmptyView() }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
        )
    }
    
    private var headerView: some View {
        VStack(spacing: 12) {
            HStack {
                if let workspace = workspaceManager.allLocations.first(where: { $0.id == viewModel.selectedLocationId }) {
                    Button(action: { viewModel.navigateBack() }) { 
                        Image(systemName: "chevron.left")
                            .foregroundColor(viewModel.macControlIcon)
                    }
                    .buttonStyle(.borderless).disabled(viewModel.currentPath == workspace.path)
                    
                    Text(viewModel.currentPath == workspace.path ? workspace.name : URL(fileURLWithPath: viewModel.currentPath).lastPathComponent)
                        .font(.headline)
                        .foregroundColor(viewModel.macPrimaryText)
                        .lineLimit(1)
                    
                    Button(action: {
                        NSWorkspace.shared.open(URL(fileURLWithPath: viewModel.currentPath))
                    }) {
                        Image(systemName: "folder")
                            .foregroundColor(viewModel.macControlIcon)
                    }
                    .buttonStyle(.borderless)
                    .help("Abrir carpeta en Finder")
                }
                Spacer()
                Picker("", selection: $viewModel.layoutMode) {
                    Image(systemName: "list.bullet").tag(LayoutMode.list)
                    Image(systemName: "square.grid.2x2").tag(LayoutMode.tactical)
                }.pickerStyle(.segmented).frame(width: 80)
            }
            HStack {
                ZStack(alignment: .trailing) {
                    TextField("Buscar en el vault...", text: $viewModel.searchText)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSearchFocused)
                    
                    if !viewModel.searchText.isEmpty {
                        Button(action: { viewModel.clearSearch() }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 8)
                    }
                }
                
                Menu {
                    Picker("Ordenar", selection: $viewModel.sortOption) { ForEach(SortOption.allCases) { Text($0.rawValue).tag($0) } }
                } label: { 
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundColor(viewModel.macControlIcon)
                }
                .menuStyle(.borderlessButton).fixedSize()
                
                Button(action: { viewModel.createNewNote(locations: workspaceManager.allLocations) }) { 
                    Image(systemName: "note.text.badge.plus")
                        .foregroundColor(viewModel.macControlIcon)
                }.buttonStyle(.borderless)
                
                Button(action: { viewModel.createNewFolder(locations: workspaceManager.allLocations) }) { 
                    Image(systemName: "folder.badge.plus")
                        .foregroundColor(viewModel.macControlIcon)
                }.buttonStyle(.borderless)
                
                if !viewModel.selectedItemIds.isEmpty {
                    Button(role: .destructive, action: { viewModel.deleteSelectedItems(locations: workspaceManager.allLocations) }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red.opacity(0.8))
                    }.buttonStyle(.borderless)
                }
            }
        }
        .padding()
        .background(reduceTransparency ? AnyView(viewModel.macBackground) : AnyView(Rectangle().fill(.ultraThinMaterial)))
    }
}

// MARK: - Recursive Tree Components

struct VaultTreeView: View {
    @ObservedObject var viewModel: EditorViewModel
    let locations: [VaultLocation]
    let showNotes: Bool
    
    var rootPath: String {
        let p = locations.first(where: { $0.id == viewModel.selectedLocationId })?.path ?? ""
        return p.hasSuffix("/") && p.count > 1 ? String(p.dropLast()) : p
    }
    
    var rootItems: [NoteRecord] {
        let allRoot = viewModel.childrenByParent[rootPath] ?? []
        let folders = allRoot.filter { $0.isDir }
        let notes = showNotes ? allRoot.filter { !$0.isDir } : []
        let combined = folders + notes
        return combined.sorted { a, b in
            let aPinned = viewModel.pinnedPaths.contains(a.path)
            let bPinned = viewModel.pinnedPaths.contains(b.path)
            if aPinned != bPinned {
                return aPinned
            }
            if a.isDir != b.isDir {
                return a.isDir
            }
            return a.title.lowercased() < b.title.lowercased()
        }
    }
    
    var body: some View {
        Group {
            if rootPath.isEmpty {
                ContentUnavailableView("No Workspace", systemImage: "folder.badge.questionmark")
            } else {
                ForEach(rootItems, id: \.path) { item in
                    VaultTreeRow(item: item, viewModel: viewModel, locations: locations, showNotes: showNotes, depth: 0)
                }
            }
        }
    }
}

struct VaultContextMenu: View {
    let item: NoteRecord
    @ObservedObject var viewModel: EditorViewModel
    let locations: [VaultLocation]
    
    var body: some View {
        if viewModel.selectedItemIds.count > 1 {
            Button(role: .destructive) {
                viewModel.deleteSelectedItems(locations: locations)
            } label: { Label("Eliminar \(viewModel.selectedItemIds.count) elementos", systemImage: "trash") }
        } else {
            Button {
                viewModel.togglePin(for: item.path, locations: locations)
            } label: {
                let isPinned = viewModel.pinnedPaths.contains(item.path)
                Label(isPinned ? "Desfijar" : "Fijar", systemImage: isPinned ? "pin.slash" : "pin")
            }
            
            Divider()

            if item.isDir {
                Button { viewModel.createNewNote(at: item.path, locations: locations) } label: { Label("Nueva Nota aquí", systemImage: "note.text.badge.plus") }
                Button { viewModel.createNewFolder(at: item.path, locations: locations) } label: { Label("Nueva Carpeta aquí", systemImage: "folder.badge.plus") }
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
                } label: { Label("Mostrar en Finder", systemImage: "folder") }
                Divider()
            } else {
                Button {
                    NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                } label: { Label("Mostrar en Finder", systemImage: "folder") }
            }
            
            Button {
                viewModel.beginRename(for: item)
            } label: { Label("Renombrar", systemImage: "pencil") }

            Button(role: .destructive) { 
                viewModel.selectItem(item)
                viewModel.deleteSelectedItems(locations: locations) 
            } label: { Label("Eliminar", systemImage: "trash") }
        }
    }
}

struct VaultTreeRow: View {
    let item: NoteRecord
    @ObservedObject var viewModel: EditorViewModel
    let locations: [VaultLocation]
    let showNotes: Bool
    var depth: Int = 0
    
    
    var isExpanded: Bool {
        viewModel.expandedPaths.contains(item.path)
    }
    
    var children: [NoteRecord] {
        guard item.isDir else { return [] }
        let allChildren = viewModel.childrenByParent[item.path] ?? []
        let subfolders = allChildren.filter { $0.isDir }
        let subnotes = showNotes ? allChildren.filter { !$0.isDir } : []
        let combined = subfolders + subnotes
        return combined.sorted { a, b in
            let aPinned = viewModel.pinnedPaths.contains(a.path)
            let bPinned = viewModel.pinnedPaths.contains(b.path)
            if aPinned != bPinned {
                return aPinned
            }
            if a.isDir != b.isDir {
                return a.isDir
            }
            return a.title.lowercased() < b.title.lowercased()
        }
    }
    
    var isSelected: Bool {
        viewModel.selectedItemIds.contains(item.path)
    }
    
    var body: some View {
        Group {
            HStack(spacing: 4) {
                if item.isDir {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundColor(viewModel.macSecondaryText)
                        .frame(width: 12)
                        .onTapGesture { viewModel.toggleExpansion(path: item.path) }
                } else {
                    Spacer().frame(width: 12)
                }
                
                HStack(spacing: 8) {
                    Image(systemName: item.isDir ? (isExpanded ? "folder.fill" : "folder") : "doc.text")
                        .foregroundColor(item.isDir ? viewModel.macAccent : viewModel.macSecondaryText)
                        .font(.system(size: 12))
                    
                    Text(item.title)
                        .font(.subheadline)
                        .foregroundColor(isSelected ? viewModel.macPrimaryText : viewModel.macSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    if viewModel.pinnedPaths.contains(item.path) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.orange)
                    }
                    
                    Spacer()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .background(isSelected ? viewModel.macAccent.opacity(0.15) : Color.white.opacity(0.03))
                .cornerRadius(4)
                .onTapGesture {
                    let extend = NSEvent.modifierFlags.contains(.shift)
                    let toggle = NSEvent.modifierFlags.contains(.command)
                    if item.isDir {
                        if !extend && !toggle {
                            viewModel.navigateTo(path: item.path)
                            viewModel.toggleExpansion(path: item.path) 
                        } else {
                            viewModel.selectItem(item, extend: extend, toggle: toggle)
                        }
                    } else {
                        viewModel.selectItem(item, extend: extend, toggle: toggle)
                    }
                }
                .contextMenu {
                    VaultContextMenu(item: item, viewModel: viewModel, locations: locations)
                        .id(item.path + "_ctx")
                }
                .id(item.path + "_row")
            }
            .padding(.leading, CGFloat(depth * 16))
            
            if item.isDir && isExpanded {
                ForEach(children, id: \.path) { child in
                    VaultTreeRow(item: child, viewModel: viewModel, locations: locations, showNotes: showNotes, depth: depth + 1)
                }
            }
        }

    }
}

struct DetailColumn: View {
    @ObservedObject var viewModel: EditorViewModel
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @Binding var isNoteHidden: Bool
    
    var body: some View {
        ZStack {
            if let activeId = viewModel.activeTabId, let index = viewModel.tabs.firstIndex(where: { $0.id == activeId }) {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(viewModel.tabs) { tab in
                                TabHeaderView(tab: tab, isActive: tab.id == activeId, viewModel: viewModel) {
                                    viewModel.activeTabId = tab.id
                                } onClose: {
                                    if let idx = viewModel.tabs.firstIndex(where: { $0.id == tab.id }) { viewModel.closeTab(at: IndexSet(integer: idx)) }
                                }
                            }
                        }
                    }
                    .background(viewModel.noteBackgroundColor)
                    
                    EditorAreaView(tab: $viewModel.tabs[index], selectedTheme: viewModel.selectedTheme, viewModel: viewModel)
                    
                    // FASE 5: Cognitive Radar (métricas reales vía Rust/DuckDB)
                    CognitiveRadarView(
                        noteId: viewModel.tabs[index].id,
                        workspacePath: workspaceManager.allLocations.first(where: { $0.id == viewModel.selectedLocationId })?.path ?? ""
                    )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .padding(.top, 8)
                        .background(viewModel.noteBackgroundColor)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button(action: {
                            withAnimation { isNoteHidden.toggle() }
                        }) {
                            Label("Ocultar Nota", systemImage: "uiwindow.split.2x1")
                        }
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                        .help("Ocultar Nota (Cmd+Shift+E)")

                        Button(action: {
                            NSApp.keyWindow?.toggleFullScreen(nil)
                        }) {
                            Label("Pantalla Completa", systemImage: "arrow.up.backward.and.arrow.down.forward")
                        }
                        .keyboardShortcut("f", modifiers: [.control, .command])
                        .help("Pantalla Completa Nativa (Ctrl+Cmd+F)")
                        
                        // Button(action: { viewModel.saveActiveTab(locations: workspaceManager.allLocations) }) { Label("Save", systemImage: "checkmark.circle") }.keyboardShortcut("s", modifiers: .command)
                        // Button(action: { viewModel.togglePreview() }) { Label("Preview", systemImage: "eye") }.keyboardShortcut("r", modifiers: .command)
                    }
                }
            } else {
                ZStack {
                    viewModel.macBackground.ignoresSafeArea()
                    ContentUnavailableView("Selecciona una nota", systemImage: "text.document")
                        .opacity(0.5)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MainEditorView: View {
    @StateObject var viewModel = EditorViewModel()
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var showTelemetry = false
    @State private var isNoteHidden = false
    @State private var isSidebarHidden = false
    @State private var showScratchpad = false
    
    var body: some View {
        ZStack(alignment: .bottom) {
            NavigationStack {
                HSplitView {
                    if !isSidebarHidden {
                        SidebarColumn(viewModel: viewModel)
                            .frame(minWidth: 250, idealWidth: 400, maxWidth: 600)
                        
                        MainContentColumn(viewModel: viewModel, isNoteHidden: $isNoteHidden)
                            .frame(minWidth: 250, idealWidth: 300, maxWidth: .infinity)
                    }
                    
                    if !isNoteHidden {
                        DetailColumn(viewModel: viewModel, isNoteHidden: $isNoteHidden)
                            .frame(minWidth: 300, maxWidth: .infinity)
                            .layoutPriority(1)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button(action: { withAnimation { isSidebarHidden.toggle() } }) {
                            Image(systemName: "sidebar.left")
                        }
                        .keyboardShortcut("f", modifiers: [.command, .shift])
                        .help("Ocultar paneles (Cmd+Shift+F)")
                    }
                    
                    ToolbarItem(placement: .navigation) {
                        Button(action: { withAnimation { showScratchpad.toggle() } }) {
                            Image(systemName: "note.text.badge.plus")
                                .foregroundColor(showScratchpad ? .accentColor : .primary)
                        }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                        .help("Sesión Actual - Scratchpad (Cmd+Shift+S)")
                    }
                    
                    if isNoteHidden {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button(action: {
                                withAnimation { isNoteHidden.toggle() }
                            }) {
                                Label("Mostrar Nota", systemImage: "macwindow")
                            }
                            .keyboardShortcut("e", modifiers: [.command, .shift])
                            .help("Mostrar Nota (Cmd+Shift+E)")

                            Button(action: {
                                NSApp.keyWindow?.toggleFullScreen(nil)
                            }) {
                                Label("Pantalla Completa", systemImage: "arrow.up.backward.and.arrow.down.forward")
                            }
                            .keyboardShortcut("f", modifiers: [.control, .command])
                            .help("Pantalla Completa Nativa (Ctrl+Cmd+F)")
                        }
                    }
                }
            }
            
            // Botón flotante para abrir telemetría
            if !showTelemetry {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            withAnimation { showTelemetry = true }
                        } label: {
                            Image(systemName: "terminal.fill")
                                .padding(12)
                                .background(Color.green)
                                .foregroundColor(.black)
                                .clipShape(Circle())
                                .shadow(radius: 4)
                        }
                        .buttonStyle(.plain)
                        .padding(20)
                    }
                }
            }
            
            if showTelemetry {
                TelemetryView(viewModel: viewModel, isPresented: $showTelemetry)
                    .transition(.move(edge: .bottom))
            }
            
            if showScratchpad {
                BottomSheetScratchpadView(viewModel: viewModel, isPresented: $showScratchpad)
                    .transition(.move(edge: .bottom))
                    .zIndex(50)
            }
        }
        .preferredColorScheme(viewModel.selectedTheme.colorScheme)
        .onChange(of: viewModel.selectedLocationId) { _, _ in
            viewModel.resetToWorkspaceRoot(locations: workspaceManager.allLocations)
        }
        .onChange(of: viewModel.selectedTheme) { _, _ in viewModel.refreshNotes(locations: workspaceManager.allLocations) }
        .onChange(of: viewModel.debouncedSearchText) { _, _ in viewModel.refreshNotes(locations: workspaceManager.allLocations) }
        .onChange(of: viewModel.sortOption) { _, _ in viewModel.refreshNotes(locations: workspaceManager.allLocations) }
        .onAppear {
            DispatchQueue.main.async {
                viewModel.syncAll(locations: workspaceManager.allLocations)
                if viewModel.selectedLocationId == nil, let first = workspaceManager.allLocations.first { viewModel.selectedLocationId = first.id }
                viewModel.launchWatcher(paths: workspaceManager.allLocations.map { $0.path }, ignorePatterns: [])
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenWorkspaceFile"))) { notification in
            if let userInfo = notification.userInfo, let url = userInfo["url"] as? URL {
                viewModel.openNoteFromURL(url)
            }
        }
    }
}

struct FileRowView: View {
    let item: NoteRecord
    @ObservedObject var viewModel: EditorViewModel
    let locations: [VaultLocation]
    
    
    var body: some View {
        HStack {
            Image(systemName: item.isDir ? "folder.fill" : "doc.text")
                .foregroundColor(item.isDir ? viewModel.macAccent : viewModel.macSecondaryText)
                .font(.system(size: 14))
            
            VStack(alignment: .leading) {
                HStack(spacing: 4) {
                    Text(item.title).font(.headline).foregroundColor(viewModel.macPrimaryText)
                    if viewModel.pinnedPaths.contains(item.path) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                }
                if !viewModel.searchText.isEmpty { 
                    Text(item.path).font(.caption2).lineLimit(1).opacity(0.6).foregroundColor(viewModel.macSecondaryText)
                }
            }
            if item.isDir { Spacer(); Image(systemName: "chevron.right").font(.system(size: 10)).opacity(0.3) }
        }
        .contentShape(Rectangle())
        .onTapGesture { 
            NSApp.keyWindow?.makeFirstResponder(nil)
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
            VaultContextMenu(item: item, viewModel: viewModel, locations: locations)
                .id(item.path + "_ctx_grid")
        }
        .id(item.path + "_row_grid")
        .listRowBackground(viewModel.macBackground)
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
    @ObservedObject var viewModel: EditorViewModel
    let onSelect: () -> Void
    let onClose: () -> Void
    var body: some View {
        HStack {
            Text(tab.title)
                .font(.subheadline)
                .fontWeight(isActive ? .bold : .regular)
                .foregroundColor(isActive ? viewModel.macPrimaryText : viewModel.macSecondaryText)
            
            Button(action: onClose) { 
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundColor(viewModel.macControlIcon)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(isActive ? viewModel.macBackground : viewModel.macSidebar)
        .onTapGesture(perform: onSelect)
    }
}

struct EditorAreaView: View {
    @Binding var tab: TabItem
    let selectedTheme: AppTheme
    @ObservedObject var viewModel: EditorViewModel
    @EnvironmentObject var workspaceManager: WorkspaceManager
    
    @State private var isHeatmapActive: Bool = false
    @State private var triggerSearch: Bool = false
    @State private var isHistoryActive: Bool = false
    @State private var showSyntaxHelp: Bool = false
    @State private var isRSVPActive: Bool = false
    @State private var selectedHelpTab: Int = 0
    
    private let syntaxHelp = """
    # Guía de Sintaxis
    
    ## Markdown
    Soporte estándar: **negrita**, *itálica*, [enlaces](url) y tablas.
    
    ## HTML
    Puedes insertar etiquetas HTML directamente:
    `<div style="color: red;">Texto rojo</div>`
    
    ## LaTeX (Matemáticas)
    Usa $ para bloques centrados o $ para inline:
    
    **Ejemplo bloque:**
    $ e^{i\\pi} + 1 = 0 $
    
    **Ejemplo inline:** La fórmula $E = mc^2$ es famosa.
    
    **Matrices:**
    $
    \\begin{pmatrix}
    a & b \\\\
    c & d
    \\end{pmatrix}
    $
    """
    
    private let editorShortcutsHelp = """
    # Atajos de Edición Avanzada
    
    ## Selección y Multi-cursor
    - **Multi-cursor:** `Cmd` + Clic en el texto.
    - **Siguiente Ocurrencia:** `Cmd + D`
    
    ## Manejo de Líneas
    - **Mover línea(s):** `Option + ⬆/⬇`
    - **Duplicar línea(s):** `Shift + Option + ⬆/⬇`
    - **Borrar línea:** `Cmd + Shift + K`
    
    ## Formato y Bloques
    - **Comentar (HTML):** `Cmd + /`
    - **Identación:** `Tab` / `Shift + Tab`
    - **Mayúsculas:** `Cmd + U` / `Cmd + Shift + U`
    
    ## Automatización
    - **Auto-cierre:** Envoltura instantánea de texto al usar `[`, `(`, `"`.
    - **Listas Inteligentes:** Continuación automática de viñetas al presionar Enter.
    """
    
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    if !tab.lastSavedText.isEmpty {
                        Text(tab.lastSavedText)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.leading, 8)
                    }
                    
                    Spacer()
                    
                    Button {
                        viewModel.revealInSidebar(path: tab.id)
                    } label: {
                        Image(systemName: "folder.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .help("Mostrar en primera columna la carpeta contenedora")
                    
                    Button {
                        isHistoryActive.toggle()
                    } label: {
                        Label("Historial", systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(isHistoryActive ? .accentColor : .secondary)
                    
                    Button {
                        showSyntaxHelp.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .help("Ayuda de Sintaxis y Atajos")
                    .popover(isPresented: $showSyntaxHelp) {
                        VStack(spacing: 0) {
                            Picker("", selection: $selectedHelpTab) {
                                Text("Sintaxis").tag(0)
                                Text("Atajos").tag(1)
                            }
                            .pickerStyle(.segmented)
                            .padding()
                            
                            Divider()
                            
                            ScrollView {
                                Text(selectedHelpTab == 0 ? syntaxHelp : editorShortcutsHelp)
                                    .font(.system(.body, design: .monospaced))
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(width: 350, height: 450)
                    }
                    
                    // FASE 5: Semantic Heatmap Toggle
                    Toggle(isOn: $isHeatmapActive) {
                        Label("Heat Map", systemImage: "flame.fill")
                            .font(.caption)
                    }
                    .toggleStyle(.button)
                    .tint(.orange)
                    
                    if !tab.isPreviewMode {
                        Button {
                            viewModel.saveActiveTab(locations: workspaceManager.allLocations)
                        } label: {
                            Label("Guardar", systemImage: "square.and.arrow.down")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut("s", modifiers: .command)
                        .help("Guardar cambios (Cmd+S)")
                        
                        Button {
                            triggerSearch = true
                        } label: {
                            Label("Buscar", systemImage: "magnifyingglass")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    if tab.isPreviewMode {
                        Button {
                            isRSVPActive = true
                        } label: {
                            Label("RSVP", systemImage: "bolt.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .help("Lectura rápida RSVP")
                    }
                    
                    Button(tab.isPreviewMode ? "Editar" : "Ver") { 
                        tab.isPreviewMode.toggle() 
                        if tab.isPreviewMode {
                            viewModel.saveActiveTab(locations: workspaceManager.allLocations)
                        }
                    }.buttonStyle(.bordered)
                }
                .padding(8)
            
            if tab.isPreviewMode {
                WebView(
                    htmlContent: generateSafeHTML(tab.content, theme: selectedTheme, mode: tab.renderMode, isHeatmapActive: isHeatmapActive, noteId: tab.id, searchText: viewModel.debouncedSearchText),
                    baseURL: URL(fileURLWithPath: tab.id).deletingLastPathComponent(),
                    triggerSearch: $triggerSearch,
                    onNavigate: { url in
                        handleNavigation(url)
                    },
                    onCheckboxToggled: { index in
                        viewModel.toggleMarkdownCheckbox(index: index, tabId: tab.id)
                    }
                )
                .id("\(tab.id)-\(tab.renderMode.rawValue)-\(selectedTheme.rawValue)-\(isHeatmapActive)")
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        
                        Button(action: {
                            viewModel.showLineNumbers.toggle()
                        }) {
                            Image(systemName: "list.number")
                                .font(.system(size: 11))
                                .foregroundColor(viewModel.showLineNumbers ? viewModel.macAccent : .secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(viewModel.showLineNumbers ? viewModel.macAccent.opacity(0.1) : Color.clear)
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .help(viewModel.showLineNumbers ? "Ocultar números de línea" : "Mostrar números de línea")
                        .padding(.trailing, 8)
                        .padding(.bottom, 6)

                        Label("Modo Edición", systemImage: "pencil.and.outline")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.orange.opacity(0.8))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                            )
                            .padding(.trailing, 24)
                            .padding(.bottom, 6)
                    }
                    
                    CodeEditor(text: $tab.content, triggerSearch: $triggerSearch, showLineNumbers: $viewModel.showLineNumbers, language: tab.language, theme: selectedTheme)
                        .frame(maxWidth: 850)
                        .cornerRadius(15)
                        .overlay(
                            RoundedRectangle(cornerRadius: 15)
                                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                        )
                        .padding(15)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                        .background(viewModel.noteBackgroundColor)
                }
            }
            }
            .background(viewModel.noteBackgroundColor)
            .background(
                Group {
                    Button("") {
                        if let activeId = viewModel.activeTabId, let index = viewModel.tabs.firstIndex(where: { $0.id == activeId }) {
                            viewModel.tabs[index].isPreviewMode.toggle()
                            if viewModel.tabs[index].isPreviewMode {
                                viewModel.saveActiveTab(locations: workspaceManager.allLocations)
                            }
                        }
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    
                    Button("") {
                        viewModel.saveActiveTab(locations: workspaceManager.allLocations)
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    
                    Button("") {
                        triggerSearch = true
                    }
                    .keyboardShortcut("f", modifiers: .command)
                }
                .opacity(0)
            )
            
            if isHistoryActive {
                Divider()
                GitHistorySidebar(noteId: tab.id, content: $tab.content, isPresented: $isHistoryActive)
                    .transition(.move(edge: .trailing))
            }
        }
        .blur(radius: isRSVPActive ? 3 : 0)
        .opacity(isRSVPActive ? 0.45 : 1.0)
        .overlay(isRSVPActive ? Color.black.opacity(0.3) : Color.clear)
        .sheet(isPresented: $isRSVPActive) {
            FocoMemoriaView(text: tab.content, backgroundColor: viewModel.noteBackgroundColor, isPresented: $isRSVPActive)
        }
    }
    
    private func handleNavigation(_ url: URL) {
        if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
            NSWorkspace.shared.open(url)
            return
        }
        
        if url.isFileURL {
            let path = url.path
            if let note = viewModel.allNotes.first(where: { $0.path == path }) {
                viewModel.openNote(note)
                return
            }
            
            let fileName = url.lastPathComponent
            let decodedName = fileName.removingPercentEncoding ?? fileName
            let titleWithoutExt = decodedName.replacingOccurrences(of: ".md", with: "")
            
            if let matchingNote = viewModel.allNotes.first(where: { $0.title == titleWithoutExt || $0.title == decodedName }) {
                viewModel.openNote(matchingNote)
            } else {
                print("VaultSystem: Note not found for path \(path) or title \(decodedName)")
            }
        }
    }
    
    private func generateSafeHTML(_ content: String, theme: AppTheme, mode: RenderMode, isHeatmapActive: Bool, noteId: String, searchText: String) -> String {
        let base64Content = Data(content.utf8).base64EncodedString()
        var themeCSS = ""
        switch theme {
        case .light: themeCSS = ":root { --bg: transparent; --text: #333; --accent: #2b82d9; } body { background: transparent; }"
        case .dark: themeCSS = ":root { --bg: transparent; --text: rgba(240, 240, 240, 0.85); --accent: #58a6ff; } body { background: transparent; }"
        case .night: themeCSS = ":root { --bg: #000; --text: #ff3b30; --accent: #ff453a; } body { background:#000; color:#ff3b30; }"
        case .system: themeCSS = ":root { --bg: transparent; --text: #333; --accent: #2b82d9; } @media (prefers-color-scheme: dark) { :root { --bg: transparent; --text: rgba(240, 240, 240, 0.85); --accent: #58a6ff; } } body { background: transparent; }"
        }
        
        // Extraer entidades reales del Exocórtex si el Heatmap está activo
        var entitiesScript = "const strongEntities = []; const weakEntities = [];"
        if isHeatmapActive {
            // Fase 5: Obtenemos el grafo temporal real de esta nota
            let edges = getTemporalNeighborhood(noteId: noteId, maxDepth: 1)
            var strong = [String]()
            var weak = [String]()
            
            // Simulación: los targets son conceptos, si el peso es alto es 'strong'
            for edge in edges {
                let concept = edge.target.replacingOccurrences(of: "'", with: "\\'")
                if edge.weight > 0.6 {
                    strong.append("'\(concept)'")
                } else {
                    weak.append("'\(concept)'")
                }
            }
            // Si no hay grafos reales aún, inyectamos heurística dummy basada en palabras comunes de markdown
            if strong.isEmpty { strong = ["'arquitectura'", "'sistema'", "'modelo'", "'IA'"] }
            if weak.isEmpty { weak = ["'idea'", "'concepto'", "'borrador'"] }
            
            entitiesScript = """
            const strongEntities = [\(strong.joined(separator: ","))];
            const weakEntities = [\(weak.joined(separator: ","))];
            """
        }
        
        let renderModeStr = mode.rawValue
        
        return ##"""
        <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css">
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/contrib/auto-render.min.js"></script>
        <script src="https://cdnjs.cloudflare.com/ajax/libs/mark.js/8.11.1/mark.min.js"></script>
        <style>\##(themeCSS) body { font-family: -apple-system, system-ui, sans-serif; padding: 5.125rem; line-height: 1.6; color: var(--text); background: var(--bg); max-width: 850px; margin: 0 auto; overflow-wrap: break-word; } a, a:visited { color: var(--accent); text-decoration: none; } a:hover { text-decoration: underline; }
        img { max-width: 100%; height: auto; border-radius: 8px; } pre { background: rgba(128,128,128,0.1); padding: 1rem; border-radius: 8px; overflow: auto; }
        mark.search-highlight { background-color: rgba(255, 215, 0, 0.4); color: inherit; border-radius: 2px; padding: 0 2px; box-shadow: 0 0 4px rgba(255,215,0,0.5); }
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
            
            // Habilitar checkboxes e inyectar mensaje Swift
            const checkboxes = document.querySelectorAll('input[type="checkbox"]');
            checkboxes.forEach((cb, index) => {
                cb.removeAttribute('disabled');
                cb.style.cursor = 'pointer';
                cb.addEventListener('change', () => {
                    window.webkit.messageHandlers.toggleCheckbox.postMessage({ index: index });
                });
            });
            
            // FASE 5: Inject Semantic Heatmap overlay
            \##(entitiesScript)
            if (typeof strongEntities !== 'undefined' && (strongEntities.length > 0 || weakEntities.length > 0)) {
                let html = document.getElementById('content').innerHTML;
                
                strongEntities.forEach(entity => {
                    if (entity.trim().length > 3) {
                        const regex = new RegExp(`(?![^<]*>)(\\\\b${entity}\\\\b)`, 'gi');
                        html = html.replace(regex, `<span style='background-color: rgba(255, 165, 0, 0.4); border-bottom: 2px solid orange; padding: 0 2px; border-radius: 3px;' title='Concepto Validado'>$1</span>`);
                    }

                });
                
                weakEntities.forEach(entity => {
                    if (entity.trim().length > 3) {
                        const regex = new RegExp(`(?![^<]*>)(\\\\b${entity}\\\\b)`, 'gi');
                        html = html.replace(regex, `<span style='background-color: rgba(128, 128, 128, 0.3); border-bottom: 1px dotted gray; padding: 0 2px; border-radius: 3px;' title='Gap Cognitivo (Dark Matter)'>$1</span>`);
                    }
                });
                
                document.getElementById('content').innerHTML = html;
            }
            
            const searchStr = "\##(searchText)";
            if (searchStr.trim().length > 0) {
                const terms = searchStr.split(" ").filter(t => t.trim().length > 0);
                const instance = new Mark(document.getElementById('content'));
                instance.mark(terms, {
                    "element": "mark",
                    "className": "search-highlight",
                    "accuracy": "partially",
                    "diacritics": true,
                    "caseSensitive": false
                });
            }
            
        }catch(e){document.getElementById('content').innerHTML="<div style='color:red'>Error: "+e.message+"</div>";}
        </script></body></html>
        """##
    }
}

// FASE 5: Memory Palace / Árbol Semántico Mejorado
struct SemanticTreeView: View {
    @ObservedObject var viewModel: EditorViewModel
    @EnvironmentObject var workspaceManager: WorkspaceManager

    @State private var semanticClusters: [(String, [NoteRecord])] = []
    @State private var isLoading: Bool = false
    @State private var activeNoteTitle: String = ""

    // Workspace activo seleccionado por el usuario
    private var currentWorkspace: VaultLocation? {
        workspaceManager.allLocations.first(where: { $0.id == viewModel.selectedLocationId })
    }

    // Notas del workspace actual únicamente (fix de aislamiento)
    private var workspaceNotes: [NoteRecord] {
        guard let wsPath = currentWorkspace?.path else { return [] }
        return viewModel.allNotes.filter { $0.path.hasPrefix(wsPath) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Header contextual
            if !activeNoteTitle.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.purple.opacity(0.8))
                    Text("Vecindad: \(activeNoteTitle)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.55)
                    Text("Calculando vecindad semántica…")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else if semanticClusters.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Palacio Mental", systemImage: "brain.head.profile")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("Abre una nota del workspace para ver su vecindad semántica real.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else {
                ForEach(semanticClusters, id: \.0) { cluster in
                    if !cluster.1.isEmpty {
                        SemanticClusterRow(title: cluster.0, notes: cluster.1, viewModel: viewModel)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .onChange(of: viewModel.activeTabId) { _, newId in
            loadSemanticNeighbors(for: newId)
        }
        .onChange(of: viewModel.selectedLocationId) { _, _ in
            DispatchQueue.main.async {
                // Al cambiar workspace, resetear y recargar para la nota activa
                semanticClusters = []
                activeNoteTitle = ""
                loadSemanticNeighbors(for: viewModel.activeTabId)
            }
        }
        .onAppear {
            loadSemanticNeighbors(for: viewModel.activeTabId)
        }
    }

    private func loadSemanticNeighbors(for noteId: String?) {
        DispatchQueue.main.async {
            guard let noteId = noteId, !noteId.isEmpty,
                  let wsPath = self.currentWorkspace?.path else {
                self.semanticClusters = []
                self.activeNoteTitle = ""
                return
            }

            // Verificar que la nota pertenece al workspace actual
            guard noteId.hasPrefix(wsPath) else {
                self.semanticClusters = []
                self.activeNoteTitle = ""
                return
            }

            self.isLoading = true
            self.activeNoteTitle = URL(fileURLWithPath: noteId).deletingPathExtension().lastPathComponent

            // Snapshot del índice de notas antes de entrar al hilo de background
            let noteIndex = Dictionary(uniqueKeysWithValues: self.workspaceNotes.map { ($0.path, $0) })

            DispatchQueue.global(qos: .userInitiated).async {
                let neighbors = getSemanticNeighbors(noteId: noteId, workspacePath: wsPath, limit: 40)

                // Agrupar en 3 anillos de proximidad semántica
                var nucleus: [NoteRecord] = []   // score > 0.80 — hablan de lo mismo
                var resonance: [NoteRecord] = [] // score 0.65–0.80 — relacionados
                var periphery: [NoteRecord] = [] // score 0.45–0.65 — conectados tangencialmente

                for neighbor in neighbors {
                    guard let record = noteIndex[neighbor.path] else { continue }
                    if neighbor.score > 0.80 {
                        nucleus.append(record)
                    } else if neighbor.score > 0.65 {
                        resonance.append(record)
                    } else {
                        periphery.append(record)
                    }
                }

                // Fallback si el embedding aún no existe: agrupar workspace por carpeta
                let hasSemantic = !nucleus.isEmpty || !resonance.isEmpty || !periphery.isEmpty
                var clusters: [(String, [NoteRecord])]

                if hasSemantic {
                    clusters = [
                        ("🔗 Núcleo Semántico  >80%", nucleus),
                        ("🌐 Zona de Resonancia  65–80%", resonance),
                        ("🌌 Periferia  45–65%", periphery),
                    ].filter { !$0.1.isEmpty }
                } else {
                    // Sin embeddings: fallback con todas las notas del workspace
                    let allWsNotes = Array(noteIndex.values).sorted { $0.title < $1.title }
                    clusters = allWsNotes.isEmpty ? [] : [("📁 Workspace (sin embeddings)", allWsNotes)]
                }

                DispatchQueue.main.async {
                    self.semanticClusters = clusters
                    self.isLoading = false
                }
            }
        }
    }
}

struct SemanticClusterRow: View {
    let title: String
    let notes: [NoteRecord]
    @ObservedObject var viewModel: EditorViewModel
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header del cluster
            HStack {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(viewModel.macSecondaryText)
                    .frame(width: 12, height: 12)

                Text(title)
                    .font(.subheadline)
                    .foregroundColor(viewModel.macPrimaryText)

                Spacer()
                Text("\(notes.count)")
                    .font(.caption2)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.75))
                    .cornerRadius(8)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(Color.white.opacity(0.001))
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(notes, id: \.path) { note in
                        VaultTreeRow(item: note, viewModel: viewModel, locations: [], showNotes: true)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }
}



struct GitHistorySidebar: View {
    let noteId: String
    @Binding var content: String
    @Binding var isPresented: Bool
    
    @State private var commits: [GitCommit] = []
    @State private var previewCommit: GitCommit?
    @State private var previewContent: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("HISTORIAL DE CAMBIOS")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Divider()
            
            if commits.isEmpty {
                VStack(spacing: 12) {
                    Text("Sin historial de cambios")
                        .font(.headline)
                    Text("El historial se genera automáticamente al guardar cambios (Cmd+R o botón Ver).")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                    
                    Button("Refrescar") {
                        commits = getFileHistory(path: noteId)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            } else {
                List(commits, id: \.hash) { commit in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(commit.date)
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                        
                        Text(commit.message)
                            .font(.subheadline)
                            .lineLimit(2)
                        
                        HStack {
                            Text(String(commit.hash.prefix(7)))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Button("Restaurar") {
                                let oldContent = getFileContentAtCommit(path: noteId, commitHash: commit.hash)
                                if !oldContent.isEmpty {
                                    content = oldContent
                                    _ = saveNote(path: noteId, content: content)
                                    isPresented = false
                                }
                            }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let oldContent = getFileContentAtCommit(path: noteId, commitHash: commit.hash)
                        previewContent = oldContent
                        previewCommit = commit
                    }
                }
            }
        }
        .frame(width: 300)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            loadHistory()
        }
        .onChange(of: noteId) {
            loadHistory()
        }
        .sheet(item: $previewCommit) { commit in
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Previsualización de Versión")
                            .font(.headline)
                        Text("Commit: \(commit.hash.prefix(7)) — \(commit.date)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Cerrar") {
                        previewCommit = nil
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                
                Divider()
                
                ScrollView {
                    Text(previewContent.isEmpty ? "(Nota vacía)" : previewContent)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
                .padding(.horizontal)
                
                HStack {
                    Spacer()
                    Button("Restaurar esta versión") {
                        content = previewContent
                        _ = saveNote(path: noteId, content: content)
                        previewCommit = nil
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                }
            }
            .frame(minWidth: 950, minHeight: 650)
            .background(Rectangle().fill(.ultraThinMaterial))
        }
    }
    
    private func loadHistory() {
        let path = noteId
        DispatchQueue.global(qos: .userInitiated).async {
            let history = getFileHistory(path: path)
            DispatchQueue.main.async {
                self.commits = history
            }
        }
    }
}


struct BottomSheetScratchpadView: View {
    @ObservedObject var viewModel: EditorViewModel
    @Binding var isPresented: Bool
    
    @State private var scratchpadText: String = ""
    @State private var consoleMessage: String = ""
    @State private var height: CGFloat = 300
    @GestureState private var dragOffset: CGFloat = 0
    
    private let minHeight: CGFloat = 200
    private let midHeight: CGFloat = 400
    
    private var currentSessionURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".vault_system/system_workspace/current_session.md")
    }
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Capsule()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 40, height: 5)
                    .padding(.top, 8)
                
                HStack {
                    Image(systemName: "square.and.pencil")
                        .foregroundColor(.accentColor)
                    
                    Text("Sesión Actual (Scratchpad)")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    if !consoleMessage.isEmpty {
                        Text(consoleMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .background(Color.black.opacity(0.05))
                            .cornerRadius(4)
                            .transition(.opacity)
                    }
                    
                    Button(action: consolidate) {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            Text("Consolidar Sesión")
                        }
                        .fontWeight(.bold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .background(Color(NSColor.windowBackgroundColor))
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation.height
                    }
                    .onEnded { value in
                        let newHeight = height - value.translation.height
                        let screenHeight: CGFloat = 800
                        
                        if newHeight < (minHeight + midHeight) / 2 {
                            height = minHeight
                        } else if newHeight > (midHeight + screenHeight) / 2 {
                            height = screenHeight - 100
                        } else {
                            height = midHeight
                        }
                    }
            )
            
            Divider()
            
            TextEditor(text: $scratchpadText)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: scratchpadText) { _, newText in
                    saveContent(newText)
                }
        }
        .frame(height: max(minHeight, height - dragOffset))
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedCornerTop(radius: 32))
        .shadow(color: .black.opacity(0.3), radius: 15, x: 0, y: -5)
        .onAppear {
            loadContent()
        }
    }
    
    private func loadContent() {
        let dir = currentSessionURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        if FileManager.default.fileExists(atPath: currentSessionURL.path) {
            if let content = try? String(contentsOf: currentSessionURL, encoding: .utf8) {
                scratchpadText = content
            }
        } else {
            let defaultContent = "# Sesión Actual\n\n- [HITO] \n- [ACUERDO] \n"
            try? defaultContent.write(to: currentSessionURL, atomically: true, encoding: .utf8)
            scratchpadText = defaultContent
        }
    }
    
    private func saveContent(_ text: String) {
        try? text.write(to: currentSessionURL, atomically: true, encoding: .utf8)
    }
    
    private func consolidate() {
        let activePath = viewModel.activeTabId ?? ""
        if activePath.isEmpty {
            withAnimation {
                consoleMessage = "Abre una nota del proyecto antes de consolidar."
            }
            return
        }
        
        _ = consolidateSession(activePath: activePath)
        withAnimation {
            consoleMessage = "Consolidación terminada con éxito."
            scratchpadText = "# Sesión Actual\n\n- [HITO] \n- [ACUERDO] \n"
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            withAnimation {
                consoleMessage = ""
            }
        }
    }
}

struct RoundedCornerTop: Shape {
    var radius: CGFloat
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.size.width
        let height = rect.size.height
        
        path.move(to: CGPoint(x: 0, y: height))
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addArc(center: CGPoint(x: radius, y: radius), radius: radius, startAngle: Angle(degrees: 180), endAngle: Angle(degrees: 270), clockwise: false)
        
        path.addLine(to: CGPoint(x: width - radius, y: 0))
        path.addArc(center: CGPoint(x: width - radius, y: radius), radius: radius, startAngle: Angle(degrees: 270), endAngle: Angle(degrees: 0), clockwise: false)
        
        path.addLine(to: CGPoint(x: width, y: height))
        path.closeSubpath()
        
        return path
    }
}

struct FocoMemoriaView: View {
    let text: String
    let backgroundColor: Color
    @Binding var isPresented: Bool
    
    @State private var words: [String] = []
    @State private var currentIndex = 0
    @State private var isPlaying = false
    @State private var wpm = 350
    @State private var timer: Timer? = nil
    
    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Text("RSVP — LECTURA RÁPIDA")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Cerrar") {
                    pause()
                    isPresented = false
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.top)
            
            Spacer()
            
            if words.isEmpty {
                Text("Sin texto para procesar")
                    .font(.title)
                    .foregroundColor(.secondary)
            } else {
                Text(words[currentIndex])
                    .font(.system(size: 64, weight: .black, design: .default))
                    .foregroundColor(.orange).opacity(0.85)
                    .frame(maxWidth: .infinity)
                    .frame(height: 140)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        togglePlay()
                    }
            }
            
            Spacer()
            
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    Button(action: togglePlay) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    
                    if !words.isEmpty {
                        Slider(value: Binding(
                            get: { Double(currentIndex) },
                            set: { currentIndex = Int($0) }
                        ), in: 0...Double(words.count - 1), step: 1)
                        
                        Text("\(currentIndex + 1) / \(words.count)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                }
                
                HStack {
                    Button(action: { wpm = max(100, wpm - 50) }) {
                        Image(systemName: "minus.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    
                    Text("\(wpm) PPM")
                        .font(.headline)
                        .frame(width: 120)
                    
                    Button(action: { wpm = min(1000, wpm + 50) }) {
                        Image(systemName: "plus.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom)
            }
            .padding(.horizontal)
        }
        .frame(width: 750, height: 480)
        .presentationBackground(Color(red: 30/255.0, green: 30/255.0, blue: 30/255.0))
        .background(Color(red: 30/255.0, green: 30/255.0, blue: 30/255.0))
        .onAppear {
            words = cleanMarkdownForSpeedReading(text)
        }
        .onDisappear {
            stopTimer()
        }
        .onChange(of: wpm) {
            if isPlaying {
                startTimer()
            }
        }
        .background(
            Button(action: togglePlay) { EmptyView() }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
        )
    }
    
    private func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    private func play() {
        guard !words.isEmpty else { return }
        if currentIndex >= words.count - 1 {
            currentIndex = 0
        }
        isPlaying = true
        startTimer()
    }
    
    private func pause() {
        isPlaying = false
        stopTimer()
    }
    
    private func startTimer() {
        stopTimer()
        let interval = 60.0 / Double(wpm)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            if currentIndex < words.count - 1 {
                currentIndex += 1
            } else {
                pause()
            }
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func cleanMarkdownForSpeedReading(_ text: String) -> [String] {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^\\)]+\\)", with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "^#+\\s+", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\n#+\\s+", with: "\n", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\*\\*|\\*|_|~~", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "`", with: "")
        cleaned = cleaned.replacingOccurrences(of: "```[a-zA-Z]*\\n[\\s\\S]*?\\n```", with: "", options: .regularExpression)
        return cleaned.components(separatedBy: .whitespacesAndNewlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

extension GitCommit: Identifiable {
    public var id: String { hash }
}
