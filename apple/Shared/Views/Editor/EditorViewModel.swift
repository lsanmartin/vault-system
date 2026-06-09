import Foundation
import SwiftUI

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
    
    var language: String {
        if renderMode == .html || id.lowercased().hasSuffix(".html") { return "html" }
        return "markdown"
    }
    
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: TabItem, rhs: TabItem) -> Bool { lhs.id == rhs.id }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "Sistema", light = "Claro", dark = "Oscuro", night = "Noche (IR)"
    var id: String { self.rawValue }
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

class EditorViewModel: ObservableObject {
    @Published var tabs: [TabItem] = []
    @Published var activeTabId: String?
    @Published var notes: [NoteRecord] = []
    @Published var folders: [NoteRecord] = [] // Carpetas del nivel actual (Grid)
    @Published var allFolders: [NoteRecord] = [] // Todas las carpetas (Árbol Sidebar)
    @Published var allNotes: [NoteRecord] = [] // Todas las notas (para árbol completo)
    @Published var searchText: String = ""
    @Published var selectedLocationId: UUID? {
        didSet {
            if let id = selectedLocationId {
                UserDefaults.standard.set(id.uuidString, forKey: "vault_last_selected_location")
                // Al cambiar de workspace, ir a la raíz
                if let location = currentLocations?.first(where: { $0.id == id }) {
                    currentPath = location.path
                }
            }
        }
    }
    @Published var currentPath: String = "" // Ruta que estamos "viendo" actualmente (Finder style)
    @Published var currentLocations: [VaultLocation]? // Referencia temporal para el didSet
    
    @Published var selectedFolderId: String? // Mantenemos para resaltar seleccionadas si es necesario
    @Published var showSystemFiles: Bool = true 
    @Published var selectedTheme: AppTheme = .system
    @Published var sortOption: SortOption = .name
    
    @AppStorage("vault_layout_mode") var layoutMode: LayoutMode = .list
    @AppStorage("vault_tactical_sidebar_width") var tacticalSidebarWidth: Double = 250.0
    @AppStorage("vault_render_mode_v3") var defaultRenderModeStr: String = RenderMode.universal.rawValue
    
    // --- macOS Finder Palette ---
    static let macBackground = Color(hex: "1E1E1E")
    static let macSidebar = Color(hex: "181818")
    static let macPrimaryText = Color(hex: "F0F0F0")
    static let macSecondaryText = Color(hex: "9A9A9A")
    static let macControlIcon = Color(hex: "888888")
    static let macAccent = Color.accentColor
    
    var currentDefaultMode: RenderMode {
        return .universal // Forzado a Universal como modo único
    }
    
    private var lastSyncTs: UInt64 = 0
    private var timer: Timer?

    init() {
        _ = initKnowledgeBase()
        
        // Restaurar última ubicación seleccionada
        if let savedId = UserDefaults.standard.string(forKey: "vault_last_selected_location"),
           let uuid = UUID(uuidString: savedId) {
            self.selectedLocationId = uuid
        }
        
        startPolling()
    }
    
    func launchWatcher(paths: [String], ignorePatterns: [String]) {
        _ = startWatcher(paths: paths, ignorePatterns: ignorePatterns)
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            let currentTs = getLastSyncTs()
            if currentTs > self?.lastSyncTs ?? 0 { 
                self?.lastSyncTs = currentTs
            }
        }
    }
    
    func refreshNotes(locations: [VaultLocation]) {
        self.currentLocations = locations
        if currentPath.isEmpty, let first = locations.first(where: { $0.id == selectedLocationId }) {
            currentPath = first.path
        }

        let ignorePatterns = showSystemFiles ? [] : ["_memory.md", "_metadata.md", "agent.md", ".git"]
        
        // Obtenemos todo de la DB
        let allItems = queryNotes(searchTerm: searchText, pathFilter: nil, ignorePatterns: ignorePatterns)
        
        // Guardamos todo para el árbol jerárquico
        self.allFolders = allItems.filter { $0.isDir }
        self.allNotes = allItems.filter { !$0.isDir }
        
        // Filtramos para mostrar SOLO lo que está en el currentPath (Finder Style)
        var results = allItems.filter { item in
            let itemURL = URL(fileURLWithPath: item.path)
            let parentPath = itemURL.deletingLastPathComponent().path
            
            // Si hay búsqueda, mostramos todo lo que coincida
            if !searchText.isEmpty { return true }
            
            // Si no hay búsqueda, solo lo que cuelga directamente de currentPath
            return parentPath == currentPath
        }
        
        // Aplicar ordenamiento
        switch sortOption {
        case .name:
            results.sort { a, b in
                if a.isDir != b.isDir { return a.isDir } // Carpetas primero
                return a.title.lowercased() < b.title.lowercased()
            }
        case .date:
            break 
        }
        
        // Separar carpetas y notas para el layout táctico
        self.folders = results.filter { $0.isDir }
        self.notes = results.filter { !$0.isDir }
    }
    
    func navigateTo(path: String) {
        currentPath = path
        if let locs = currentLocations {
            refreshNotes(locations: locs)
        }
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
        for location in locations { _ = scanVault(path: location.path, ignorePatterns: []) }
        refreshNotes(locations: locations)
    }
    
    func createNewNote(locations: [VaultLocation]) {
        if currentPath.isEmpty { return }

        let fileName = "Nueva Nota \(Int(Date().timeIntervalSince1970)).md"
        let fullPath = URL(fileURLWithPath: currentPath).appendingPathComponent(fileName).path
        
        if createItem(path: fullPath, isDir: false) {
            UserDefaults.standard.set(RenderMode.md.rawValue, forKey: "render_mode_\(fullPath)")
            syncAll(locations: locations)
            if let newNote = notes.first(where: { $0.path == fullPath }) {
                openNote(newNote)
            }
        }
    }
    
    func createNewFolder(locations: [VaultLocation]) {
        if currentPath.isEmpty { return }

        let folderName = "Nueva Carpeta \(Int(Date().timeIntervalSince1970))"
        let fullPath = URL(fileURLWithPath: currentPath).appendingPathComponent(folderName).path
        
        if createItem(path: fullPath, isDir: true) {
            syncAll(locations: locations)
        }
    }
    
    func deleteNote(_ note: NoteRecord, locations: [VaultLocation]) {
        if deleteItem(path: note.path) {
            // Cerrar pestaña si está abierta
            if let index = tabs.firstIndex(where: { $0.id == note.id }) {
                tabs.remove(at: index)
                if activeTabId == note.id { activeTabId = tabs.last?.id }
            }
            syncAll(locations: locations)
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
        
        if renameItem(oldPath: item.path, newPath: newPath) {
            syncAll(locations: locations)
            Telemetry.shared.log("Editor", eventType: "Rename", message: "De \(item.title) a \(newFileName)")
        }
    }
    
    func openNote(_ note: NoteRecord) {
        if !tabs.contains(where: { $0.id == note.id }) {
            // Modo Universal por defecto para todas las nuevas pestañas
            let initialMode: RenderMode = .universal
            
            let newTab = TabItem(id: note.id, title: note.title, content: note.content, renderMode: initialMode)
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
