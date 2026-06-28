import Foundation
import SwiftUI
import Combine

// Extender el modelo generado para que SwiftUI pueda identificarlo sin especificar el ID en cada ForEach
extension NoteRecord: Identifiable {}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

enum RenderMode: String, CaseIterable, Identifiable {
    case universal = "Universal"
    case md = "MD"
    case html = "HTML"
    case latex = "LaTeX"
    var id: String { self.rawValue }
}

struct TabItem: Identifiable, Hashable {
    let id: String 
    let title: String
    var content: String
    var isPreviewMode: Bool = true
    var renderMode: RenderMode = .md
    var lastSavedAt: Date? = nil
    
    var language: String {
        if renderMode == .html || id.lowercased().hasSuffix(".html") { return "html" }
        return "markdown"
    }
    
    var lastSavedText: String {
        guard let date = lastSavedAt else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "Guardado: \(formatter.string(from: date))"
    }
    
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: TabItem, rhs: TabItem) -> Bool { lhs.id == rhs.id }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "Sistema", light = "Claro", dark = "Oscuro", night = "Noche (IR)"
    var id: String { self.rawValue }
    
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark, .night: return .dark
        case .system: return nil
        }
    }
}

enum SortOption: String, CaseIterable, Identifiable {
    case name = "Nombre"
    case date = "Fecha"
    var id: String { self.rawValue }
}

enum LayoutMode: String, CaseIterable, Identifiable {
    case list = "Lista"
    case tactical = "Táctico"
    var id: String { self.rawValue }
}

enum TreeMode: String, CaseIterable, Identifiable {
    case hierarchy = "Carpetas"
    case semantic = "Palacio Mental"
    case heatmap  = "Actividad"
    var id: String { self.rawValue }
}

enum ExplorationFilter: String, CaseIterable, Identifiable {
    case all = "Todos"
    case recentCreated = "Recientes Creadas"
    case recentModified = "Recientes Editadas"
    case pinned = "Fijadas"
    var id: String { self.rawValue }
}

func fastParentPath(for path: String) -> String {
    let normalized = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
    guard let lastSlash = normalized.lastIndex(of: "/") else { return "" }
    if lastSlash == normalized.startIndex { return "/" }
    return String(normalized[..<lastSlash])
}

class EditorViewModel: ObservableObject {
    @Published var tabs: [TabItem] = []
    @Published var activeTabId: String? {
        didSet {
            updateShowLineNumbersForActiveTab()
        }
    }
    @Published var treeMode: TreeMode = .hierarchy
    @Published var explorationFilter: ExplorationFilter = .all {
        didSet {
            if let locs = currentLocations {
                refreshNotes(locations: locs)
            }
        }
    }
    @Published var notes: [NoteRecord] = []
    @Published var folders: [NoteRecord] = [] // Carpetas del nivel actual (Grid)
    @Published var allFolders: [NoteRecord] = [] // Todas las carpetas (Árbol Sidebar)
    @Published var allNotes: [NoteRecord] = [] // Todas las notas (para árbol completo)
    @Published var searchText: String = ""
    @Published var debouncedSearchText: String = ""
    private var cancellables = Set<AnyCancellable>()
    @Published var selectedItemIds: Set<String> = []
    @Published var pinnedPaths: Set<String> = []
    
    @Published var showLineNumbers: Bool = false {
        didSet {
            if let tabId = activeTabId {
                UserDefaults.standard.set(showLineNumbers, forKey: "vault_show_line_numbers_\(tabId)")
            }
        }
    }
    
    private func updateShowLineNumbersForActiveTab() {
        guard let tabId = activeTabId else { return }
        let key = "vault_show_line_numbers_\(tabId)"
        if UserDefaults.standard.object(forKey: key) == nil {
            self.showLineNumbers = false
        } else {
            self.showLineNumbers = UserDefaults.standard.bool(forKey: key)
        }
    }
    
    @Published var itemToRename: NoteRecord? = nil
    @Published var newNameForRename: String = ""
    
    func beginRename(for item: NoteRecord) {
        self.newNameForRename = item.title
        self.itemToRename = item
    }
    
    func commitRename(locations: [VaultLocation]) {
        guard let item = itemToRename else { return }
        performRename(item: item, newName: newNameForRename, locations: locations)
        self.itemToRename = nil
    }
    
    func togglePin(for path: String, locations: [VaultLocation]) {
        if pinnedPaths.contains(path) {
            pinnedPaths.remove(path)
        } else {
            pinnedPaths.insert(path)
        }
        UserDefaults.standard.set(Array(pinnedPaths), forKey: "vault_pinned_paths")
        refreshNotes(locations: locations)
    }
    
    func updateAppAppearance() {
        DispatchQueue.main.async {
            switch self.selectedTheme {
            case .light:
                NSApp.appearance = NSAppearance(named: .aqua)
            case .dark, .night:
                NSApp.appearance = NSAppearance(named: .darkAqua)
            case .system:
                NSApp.appearance = nil
            }
        }
    }
    @Published var expandedPaths: Set<String> = []
    @Published var childrenByParent: [String: [NoteRecord]] = [:]
    @Published var deletedPathsThisSession: Set<String> = []
    private var lastSelectedId: String? = nil
    
    @Published var selectedLocationId: UUID? {
        didSet {
            if let id = selectedLocationId {
                UserDefaults.standard.set(id.uuidString, forKey: "vault_last_selected_location")
                // Al cambiar de workspace, ir a la raíz y limpiar selección
                if let location = currentLocations?.first(where: { $0.id == id }) {
                    DispatchQueue.main.async { [weak self] in
                        self?.selectedItemIds.removeAll()
                        let p = location.path
                        self?.currentPath = p.hasSuffix("/") && p.count > 1 ? String(p.dropLast()) : p
                        if let locs = self?.currentLocations {
                            self?.refreshNotes(locations: locs)
                        }
                    }
                }
            }
        }
    }
    @Published var currentPath: String = "" // Ruta que estamos "viendo" actualmente (Finder style)
    @Published var currentLocations: [VaultLocation]? // Referencia temporal para el didSet
    
    @Published var selectedFolderId: String? // Mantenemos para resaltar seleccionadas si es necesario
    @Published var showSystemFiles: Bool = true 
    @Published var selectedTheme: AppTheme = .system {
        didSet {
            UserDefaults.standard.set(selectedTheme.rawValue, forKey: "vault_selected_theme")
            updateAppAppearance()
        }
    }
    @Published var sortOption: SortOption = .name
    
    @AppStorage("vault_layout_mode") var layoutMode: LayoutMode = .list
    @AppStorage("vault_tactical_sidebar_width") var tacticalSidebarWidth: Double = 250.0
    @AppStorage("vault_render_mode_v3") var defaultRenderModeStr: String = RenderMode.universal.rawValue
    
    // --- macOS Finder Palette (Dynamic) ---
    var macBackground: Color { selectedTheme == .night ? .black : Color(nsColor: .windowBackgroundColor) }
    var noteBackgroundColor: Color {
        let isDark = selectedTheme == .dark || (selectedTheme == .system && NSApp.effectiveAppearance.name == .darkAqua)
        if selectedTheme == .night {
            return .black
        } else if isDark {
            return Color(hex: "1E1E1E")
        } else {
            return Color(nsColor: .windowBackgroundColor)
        }
    }
    var macSidebar: Color { selectedTheme == .night ? .black : (selectedTheme == .light ? Color(red: 236/255.0, green: 236/255.0, blue: 236/255.0) : Color(nsColor: .windowBackgroundColor)) }
    var macPrimaryText: Color { selectedTheme == .night ? .red : .primary }
    var macSecondaryText: Color { selectedTheme == .night ? Color.red.opacity(0.7) : .secondary }
    var macControlIcon: Color { selectedTheme == .night ? Color.red.opacity(0.5) : .secondary }
    var macAccent: Color { selectedTheme == .night ? .red : .accentColor }
    
    var currentDefaultMode: RenderMode {
        return .universal // Forzado a Universal como modo único
    }
    
    private var lastSyncTs: UInt64 = 0
    private var timer: Timer?

    @Published var telemetryLogs: [String] = []
    
    init() {
        _ = initKnowledgeBase()
        _ = startIpcServer()
        
        $searchText
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .removeDuplicates()
            .assign(to: \.debouncedSearchText, on: self)
            .store(in: &cancellables)
        
        // Restaurar última ubicación seleccionada
        if let savedId = UserDefaults.standard.string(forKey: "vault_last_selected_location"),
           let uuid = UUID(uuidString: savedId) {
            self.selectedLocationId = uuid
        }
        
        if let savedPinned = UserDefaults.standard.stringArray(forKey: "vault_pinned_paths") {
            self.pinnedPaths = Set(savedPinned)
        }
        
        if let savedThemeRaw = UserDefaults.standard.string(forKey: "vault_selected_theme"),
           let savedTheme = AppTheme(rawValue: savedThemeRaw) {
            self.selectedTheme = savedTheme
        } else {
            updateAppAppearance()
        }
        
        startPolling()
    }
    
    func launchWatcher(paths: [String], ignorePatterns: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            for path in paths {
                _ = scanVault(path: path, ignorePatterns: ignorePatterns)
            }
            _ = startWatcher(paths: paths, ignorePatterns: ignorePatterns)
        }
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // Refrescar notas si hay cambios en el file watcher
            let currentTs = getLastSyncTs()
            if let last = self?.lastSyncTs, currentTs > last {
                if let locs = self?.currentLocations {
                    self?.refreshNotes(locations: locs)
                }
                self?.lastSyncTs = currentTs
            }
            
            // Refrescar logs de telemetría
            let newLogs = pollTelemetryLogs()
            if !newLogs.isEmpty {
                DispatchQueue.main.async {
                    self?.telemetryLogs.append(contentsOf: newLogs)
                    if (self?.telemetryLogs.count ?? 0) > 100 {
                        self?.telemetryLogs.removeFirst((self?.telemetryLogs.count ?? 0) - 100)
                    }
                }
            }
        }
    }
    
    func resetToWorkspaceRoot(locations: [VaultLocation]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let id = self.selectedLocationId,
                  let location = locations.first(where: { $0.id == id }) else { return }
            self.selectedItemIds.removeAll()
            self.explorationFilter = .all
            let p = URL(fileURLWithPath: location.path).resolvingSymlinksInPath().path
            self.currentPath = p.hasSuffix("/") && p.count > 1 ? String(p.dropLast()) : p
            self.refreshNotes(locations: locations)
        }
    }

    func refreshNotes(locations: [VaultLocation]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentLocations = locations
            if self.currentPath.isEmpty {
                if let id = self.selectedLocationId, let loc = locations.first(where: { $0.id == id }) {
                    let p = URL(fileURLWithPath: loc.path).resolvingSymlinksInPath().path
                    self.currentPath = p.hasSuffix("/") && p.count > 1 ? String(p.dropLast()) : p
                } else if let first = locations.first {
                    let p = URL(fileURLWithPath: first.path).resolvingSymlinksInPath().path
                    self.currentPath = p.hasSuffix("/") && p.count > 1 ? String(p.dropLast()) : p
                }
            }
        }

        let ignorePatterns = showSystemFiles ? [] : ["_memory.md", "_metadata.md", "agent.md", ".git"]
        let currentSearchText = debouncedSearchText
        let currentDeletedPaths = deletedPathsThisSession
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var rootWorkspacePath = locations.first(where: { $0.id == self.selectedLocationId })?.path
            if let rwp = rootWorkspacePath, rwp.hasSuffix("/") && rwp.count > 1 {
                rootWorkspacePath = String(rwp.dropLast())
            }
            
            // Obtenemos solo los datos según el filtro activo
            let rawItems: [NoteRecord]
            switch self.explorationFilter {
            case .all:
                rawItems = queryNotes(searchTerm: currentSearchText, pathFilter: rootWorkspacePath, ignorePatterns: ignorePatterns)
            case .recentCreated:
                rawItems = queryRecentCreated(pathFilter: rootWorkspacePath, limit: 50)
            case .recentModified:
                rawItems = queryRecentModified(pathFilter: rootWorkspacePath, limit: 50)
            case .pinned:
                let allRaw = queryNotes(searchTerm: "", pathFilter: rootWorkspacePath, ignorePatterns: ignorePatterns)
                rawItems = allRaw.filter { self.pinnedPaths.contains($0.path) }
            }
            
            // Aplicar filtro de sesión GLOBAL
            let allItems = rawItems.filter { item in
                if currentDeletedPaths.contains(item.path) || 
                   currentDeletedPaths.contains(where: { item.path.hasPrefix("\($0)/") }) { 
                    return false 
                }
                return true
            }
            
            var newFolders: [NoteRecord] = []
            var newNotes: [NoteRecord] = []
            var newExpandedPaths: Set<String> = []
            
            if self.explorationFilter != .all {
                newNotes = allItems.filter { !$0.isDir }
            } else if currentSearchText.isEmpty {
                newFolders = allItems.filter { $0.isDir }
                newNotes = allItems.filter { !$0.isDir }
            } else {
                var validPaths = Set<String>()
                for item in allItems where item.isDir {
                    var current = item.path
                    while current.count > 1 {
                        validPaths.insert(current)
                        let parent = URL(fileURLWithPath: current).deletingLastPathComponent().path
                        if parent == current || parent.isEmpty { break }
                        current = parent
                    }
                }
                
                let allRawFolders = queryNotes(searchTerm: "", pathFilter: rootWorkspacePath, ignorePatterns: ignorePatterns).filter { $0.isDir }
                newFolders = allRawFolders.filter { validPaths.contains($0.path) }
                newNotes = allItems.filter { !$0.isDir }
                
                if validPaths.count < 100 {
                    for path in validPaths {
                        newExpandedPaths.insert(path)
                    }
                }
            }
            let newAllItems = newFolders + newNotes
            var newChildrenMap: [String: [NoteRecord]] = [:]
            for item in newAllItems {
                let parent = fastParentPath(for: item.path)
                newChildrenMap[parent, default: []].append(item)
            }
            
            DispatchQueue.main.async {
                self.allFolders = newFolders
                self.allNotes = newNotes
                print("VaultSystem DEBUG: allFolders count: \(newFolders.count), allNotes count: \(newNotes.count)")
                print("VaultSystem DEBUG: childrenByParent keys count: \(newChildrenMap.keys.count)")
                if let rootPath = rootWorkspacePath {
                    let normalizedRoot = rootPath.hasSuffix("/") && rootPath.count > 1 ? String(rootPath.dropLast()) : rootPath
                    print("VaultSystem DEBUG: rootPath: \(rootPath), normalizedRoot: \(normalizedRoot)")
                    print("VaultSystem DEBUG: children at rootPath: \(newChildrenMap[rootPath]?.count ?? 0)")
                    print("VaultSystem DEBUG: children at normalizedRoot: \(newChildrenMap[normalizedRoot]?.count ?? 0)")
                }
                if !currentSearchText.isEmpty {
                    for path in newExpandedPaths {
                        self.expandedPaths.insert(path)
                    }
                }
                self.childrenByParent = newChildrenMap
                self.updateGridForCurrentPath()
            }
        }
    }
    
    func updateGridForCurrentPath() {
        // Obtenemos la lista plana base desde allFolders y allNotes (que ya están filtrados por la búsqueda)
        let allItems = self.allFolders + self.allNotes
        
        let normalizedCurrentPath = currentPath.hasSuffix("/") && currentPath.count > 1 ? String(currentPath.dropLast()) : currentPath
        
        var results: [NoteRecord] = []
        
        if self.explorationFilter != .all {
            results = self.allNotes
        } else if !debouncedSearchText.isEmpty {
            var uniqueItems = [String: NoteRecord]()
            for item in allItems { uniqueItems[item.path] = item }
            results = Array(uniqueItems.values)
        } else {
            results = self.childrenByParent[normalizedCurrentPath] ?? []
        }
        
        // Aplicar ordenamiento
        if self.explorationFilter == .all {
            switch sortOption {
            case .name:
                results.sort { a, b in
                    let aPinned = self.pinnedPaths.contains(a.path)
                    let bPinned = self.pinnedPaths.contains(b.path)
                    if aPinned != bPinned {
                        return aPinned
                    }
                    if a.isDir != b.isDir { return a.isDir } // Carpetas primero
                    return a.title.lowercased() < b.title.lowercased()
                }
            case .date:
                break 
            }
        }
        
        // Separar carpetas y notas para el layout táctico
        self.folders = results.filter { $0.isDir }
        self.notes = results.filter { !$0.isDir }
    }
    
    func navigateTo(path: String) {
        explorationFilter = .all
        currentPath = path
        // Al navegar, limpiamos selección por defecto para evitar confusiones de contexto
        selectedItemIds = [path] 
        lastSelectedId = nil
        
        // Si estábamos en modo búsqueda y el usuario entra a una carpeta,
        // limpiamos la búsqueda para mostrar el contenido real de la carpeta.
        // El cambio de searchText disparará refreshNotes automáticamente.
        if !debouncedSearchText.isEmpty {
            // Colapsamos todo el árbol para evitar que las carpetas que se 
            // auto-expandieron durante la búsqueda sigan abiertas y saturen la vista.
            expandedPaths.removeAll()
            
            // Expandimos solo el camino hacia la carpeta actual
            var current = path
            while current.count > 1 {
                expandedPaths.insert(current)
                let parent = URL(fileURLWithPath: current).deletingLastPathComponent().path
                if parent == current { break }
                current = parent
            }
            
            clearSearch()
        } else {
            // Pura navegación en memoria sin tocar DuckDB
            updateGridForCurrentPath()
        }
    }
    
    func revealInSidebar(path: String) {
        if !debouncedSearchText.isEmpty {
            clearSearch()
        }
        if explorationFilter != .all {
            explorationFilter = .all
        }
        
        let url = URL(fileURLWithPath: path)
        let parentPath = url.deletingLastPathComponent().path
        
        currentPath = parentPath
        
        var current = parentPath
        while current.count > 1 {
            expandedPaths.insert(current)
            let parent = URL(fileURLWithPath: current).deletingLastPathComponent().path
            if parent == current { break }
            current = parent
        }
        
        selectedItemIds = [path]
        lastSelectedId = path
        
        updateGridForCurrentPath()
    }
    
    func selectItem(_ item: NoteRecord, extend: Bool = false, toggle: Bool = false) {
        let id = item.path
        
        if toggle {
            if selectedItemIds.contains(id) {
                selectedItemIds.remove(id)
            } else {
                selectedItemIds.insert(id)
            }
        } else if extend, let lastId = lastSelectedId, !selectedItemIds.isEmpty {
            let gridItems = self.folders + self.notes
            if let startIdx = gridItems.firstIndex(where: { $0.path == lastId }),
               let endIdx = gridItems.firstIndex(where: { $0.path == id }) {
                let range = startIdx < endIdx ? startIdx...endIdx : endIdx...startIdx
                for i in range {
                    selectedItemIds.insert(gridItems[i].path)
                }
            } else {
                let visibleItems = getFlattenedVisibleItems()
                if let startIdx = visibleItems.firstIndex(where: { $0.path == lastId }),
                   let endIdx = visibleItems.firstIndex(where: { $0.path == id }) {
                    let range = startIdx < endIdx ? startIdx...endIdx : endIdx...startIdx
                    for i in range {
                        selectedItemIds.insert(visibleItems[i].path)
                    }
                } else {
                    selectedItemIds.insert(id)
                }
            }
        } else {
            selectedItemIds = [id]
        }
        
        lastSelectedId = id
        if !item.isDir && !extend && !toggle { openNote(item) }
    }
    
    // Helper para calcular la lista plana de elementos visibles (jerárquico)
    private func getFlattenedVisibleItems() -> [NoteRecord] {
        var flattened: [NoteRecord] = []
        
        // Determinar qué lista usar según el modo
        if layoutMode == .tactical && !debouncedSearchText.isEmpty {
            return folders + notes
        }
        
        if let rootId = selectedLocationId, 
           let root = currentLocations?.first(where: { $0.id == rootId }) {
            appendChildrenFast(of: root.path, childrenByParent: self.childrenByParent, to: &flattened)
        }
        
        return flattened
    }
    
    private func appendChildrenFast(of path: String, childrenByParent: [String: [NoteRecord]], to list: inout [NoteRecord]) {
        let normalizedPath = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard let children = childrenByParent[normalizedPath] else { return }
        
        let sortedChildren = children.sorted { $0.title.lowercased() < $1.title.lowercased() }
        
        for child in sortedChildren {
            list.append(child)
            if child.isDir && expandedPaths.contains(child.path) {
                appendChildrenFast(of: child.path, childrenByParent: childrenByParent, to: &list)
            }
        }
    }
    
    func toggleExpansion(path: String) {
        if expandedPaths.contains(path) {
            expandedPaths.remove(path)
        } else {
            expandedPaths.insert(path)
        }
    }
    func clearSearch() {
        searchText = ""
        debouncedSearchText = ""
    }
    
    func navigateBack() {
        let currentURL = URL(fileURLWithPath: currentPath)
        let parentPath = currentURL.deletingLastPathComponent().path
        
        // No subir más allá de la raíz del workspace
        if let locs = currentLocations, let currentWorkspace = locs.first(where: { $0.id == selectedLocationId }) {
            if currentPath != currentWorkspace.path {
                navigateTo(path: parentPath)
            }
        }
    }
    
    func syncAll(locations: [VaultLocation]) {
        self.currentLocations = locations
        // El scan sincrónico ha sido removido de syncAll para evitar colgar la UI.
        // refreshNotes lee desde DuckDB instantáneamente sin bloquear.
        refreshNotes(locations: locations)
    }
    
    func createNewNote(at specificPath: String? = nil, locations: [VaultLocation]) {
        var targetPath = specificPath ?? currentPath
        
        print("DEBUG createNewNote: specificPath = \(String(describing: specificPath)), currentPath = \(currentPath)")
        if specificPath == nil {
            if let lastId = lastSelectedId ?? selectedItemIds.first {
                let allItems = allFolders + allNotes
                if let selectedItem = allItems.first(where: { $0.path == lastId }) {
                    if selectedItem.isDir {
                        targetPath = selectedItem.path
                    } else {
                        targetPath = URL(fileURLWithPath: selectedItem.path).deletingLastPathComponent().path
                    }
                }
            } else if targetPath.isEmpty, let location = locations.first(where: { $0.id == selectedLocationId }) {
                targetPath = location.path
            }
        }
        
        if targetPath.isEmpty { return }

        let fileName = "Nueva Nota \(Int(Date().timeIntervalSince1970)).md"
        let fullPath = URL(fileURLWithPath: targetPath).appendingPathComponent(fileName).path
        
        if createItem(path: fullPath, isDir: false) {
            UserDefaults.standard.set(RenderMode.md.rawValue, forKey: "render_mode_\(fullPath)")
            syncAll(locations: locations)
            
            let tempNote = NoteRecord(id: fullPath, title: fileName, path: fullPath, content: "", isDir: false)
            self.allNotes.append(tempNote)
            self.childrenByParent[targetPath, default: []].append(tempNote)
            
            if self.currentPath != targetPath {
                self.currentPath = targetPath
            } else {
                self.updateGridForCurrentPath()
            }
            
            openNote(tempNote)
            selectItem(tempNote)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.beginRename(for: tempNote)
            }
        }
    }
    
    func createNewFolder(at specificPath: String? = nil, locations: [VaultLocation]) {
        var targetPath = specificPath ?? currentPath
        
        if specificPath == nil {
            if let lastId = lastSelectedId ?? selectedItemIds.first {
                let allItems = allFolders + allNotes
                if let selectedItem = allItems.first(where: { $0.path == lastId }) {
                    if selectedItem.isDir {
                        targetPath = selectedItem.path
                    } else {
                        targetPath = URL(fileURLWithPath: selectedItem.path).deletingLastPathComponent().path
                    }
                }
            } else if targetPath.isEmpty, let location = locations.first(where: { $0.id == selectedLocationId }) {
                targetPath = location.path
            }
        }
        
        if targetPath.isEmpty { return }

        let folderName = "Nueva Carpeta \(Int(Date().timeIntervalSince1970))"
        let fullPath = URL(fileURLWithPath: targetPath).appendingPathComponent(folderName).path
        
        if createItem(path: fullPath, isDir: true) {
            syncAll(locations: locations)
            
            let tempFolder = NoteRecord(id: fullPath, title: folderName, path: fullPath, content: "", isDir: true)
            self.allFolders.append(tempFolder)
            self.childrenByParent[targetPath, default: []].append(tempFolder)
            
            if self.currentPath != targetPath {
                self.currentPath = targetPath
            } else {
                self.updateGridForCurrentPath()
            }
            
            selectItem(tempFolder)
            self.expandedPaths.insert(targetPath)
            self.expandedPaths.insert(fullPath)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.beginRename(for: tempFolder)
            }
        }
    }
    
    func deleteNote(_ note: NoteRecord, locations: [VaultLocation]) {
        var deletedPhysically = false
        do {
            try FileManager.default.removeItem(atPath: note.path)
            deletedPhysically = true
        } catch {
            print("Error borrando nota: \(error)")
        }
        _ = deleteItem(path: note.path)
        
        if deletedPhysically {
            // Cerrar pestaña si está abierta
            if let index = tabs.firstIndex(where: { $0.id == note.id }) {
                tabs.remove(at: index)
                if activeTabId == note.id { activeTabId = tabs.last?.id }
            }
            syncAll(locations: locations)
        }
    }
    
    func deleteSelectedItems(locations: [VaultLocation]) {
        let itemsToDelete = Array(selectedItemIds)
        var deletedAny = false
        
        for path in itemsToDelete {
            // Borrar físicamente desde Swift (macOS Sandbox compatibility)
            var deletedPhysically = false
            do {
                try FileManager.default.removeItem(atPath: path)
                deletedPhysically = true
            } catch {
                print("Error borrando de disco: \(error)")
            }
            
            // Borrar de la base de datos a través de Rust
            _ = deleteItem(path: path) 
            
            if deletedPhysically {
                deletedAny = true
                deletedAny = true
                // Marcar como borrado en esta sesión para evitar que el scanner lo traiga de vuelta
                deletedPathsThisSession.insert(path)
                
                // Limpiar del estado local (Workaround por fallo de recompilación core)
                notes.removeAll { $0.path == path }
                folders.removeAll { $0.path == path }
                allNotes.removeAll { $0.path == path }
                allFolders.removeAll { $0.path == path }
                
                // Borrar recursivamente si es carpeta
                notes.removeAll { $0.path.hasPrefix("\(path)/") }
                folders.removeAll { $0.path.hasPrefix("\(path)/") }
                allNotes.removeAll { $0.path.hasPrefix("\(path)/") }
                allFolders.removeAll { $0.path.hasPrefix("\(path)/") }

                // Cerrar pestaña si está abierta
                if let index = tabs.firstIndex(where: { $0.id == path }) {
                    tabs.remove(at: index)
                }
            }
        }
        
        if deletedAny {
            selectedItemIds.removeAll()
            if !tabs.contains(where: { $0.id == activeTabId }) {
                activeTabId = tabs.last?.id
            }
            // Ahora que Rust limpia atómicamente y en cascada, podemos forzar un refresco
            refreshNotes(locations: locations)
        }
    }
    
    func performRename(item: NoteRecord, newName: String, locations: [VaultLocation]) {
        let oldURL = URL(fileURLWithPath: item.path)
        let parentURL = oldURL.deletingLastPathComponent()
        var newFileName = newName
        
        // Asegurar extensión .md si es una nota y el usuario no la puso
        if !item.isDir && !newFileName.lowercased().hasSuffix(".md") {
            newFileName += ".md"
        }
        
        let newPath = parentURL.appendingPathComponent(newFileName).path
        
        let success = renameItem(oldPath: item.path, newPath: newPath)
        if success {
            syncAll(locations: locations)
            Telemetry.shared.log("Editor", eventType: "Rename", message: "De \(item.title) a \(newFileName)")
        } else {
            Telemetry.shared.log("Editor", eventType: "Rename", message: "FAILED rename \(item.path) to \(newPath)")
            print("FAILED RENAME: \(item.path) -> \(newPath)")
        }
    }
    
    func openNote(_ note: NoteRecord) {
        if !tabs.contains(where: { $0.id == note.id }) {
            // Modo Universal por defecto para todas las nuevas pestañas
            let initialMode: RenderMode = .universal
            
            var newTab = TabItem(id: note.id, title: note.title, content: note.content, renderMode: initialMode)
            let fileModDate = (try? FileManager.default.attributesOfItem(atPath: note.id)[.modificationDate] as? Date)
            newTab.lastSavedAt = fileModDate
            tabs.append(newTab)
        }
        activeTabId = note.id
        Telemetry.shared.log("Editor", eventType: "OpenNote", message: "Abierta: \(note.title)")
    }
    
    func updateRenderMode(for tabId: String, mode: RenderMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "render_mode_\(tabId)")
        if let index = tabs.firstIndex(where: { $0.id == tabId }) {
            tabs[index].renderMode = mode
        }
    }
    
    func closeTab(at offsets: IndexSet) {
        tabs.remove(atOffsets: offsets)
        activeTabId = tabs.last?.id
    }
    
    func togglePreview() {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabId }) else { return }
        tabs[index].isPreviewMode.toggle()
    }
    
    func saveActiveTab(locations: [VaultLocation]) {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabId }) else { return }
        let tab = tabs[index]
        _ = saveNote(path: tab.id, content: tab.content)
        Telemetry.shared.log("Editor", eventType: "SaveNote", message: "Guardada: \(tab.title)")
        tabs[index].lastSavedAt = Date()
        refreshNotes(locations: locations)
    }
}

public class Telemetry {
    public static let shared = Telemetry()
    public let logFileURL: URL
    public let htmlDumpURL: URL
    private init() {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logFileURL = docDir.appendingPathComponent("vault_telemetry.log")
        htmlDumpURL = docDir.appendingPathComponent("vault_last_render.html")
    }
    public func log(_ context: String, eventType: String, message: String) {
        let logMessage = "[\(Date())] | \(context) | \(eventType) | \(message)\n"
        if let data = logMessage.data(using: .utf8) {
            if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                fileHandle.seekToEndOfFile(); fileHandle.write(data); fileHandle.closeFile()
            } else { try? data.write(to: logFileURL) }
        }
    }
    public func dumpHTML(_ html: String) { try? html.write(to: htmlDumpURL, atomically: true, encoding: .utf8) }
}
