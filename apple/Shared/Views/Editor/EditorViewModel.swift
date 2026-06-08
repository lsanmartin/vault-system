import Foundation
import SwiftUI

enum RenderMode: String, CaseIterable, Identifiable {
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

class EditorViewModel: ObservableObject {
    @Published var tabs: [TabItem] = []
    @Published var activeTabId: String?
    @Published var notes: [NoteRecord] = []
    @Published var searchText: String = ""
    @Published var selectedLocationId: UUID?
    @Published var showSystemFiles: Bool = true 
    @Published var selectedTheme: AppTheme = .system
    @Published var sortOption: SortOption = .name
    
    @AppStorage("vault_render_mode_v2") var defaultRenderModeStr: String = RenderMode.md.rawValue
    
    var currentDefaultMode: RenderMode {
        RenderMode(rawValue: defaultRenderModeStr) ?? .md
    }
    
    private var lastSyncTs: UInt64 = 0
    private var timer: Timer?

    init() {
        _ = initKnowledgeBase()
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
                // No forzar refresh aquí para no interrumpir escritura, pero se podría
            }
        }
    }
    
    func refreshNotes(locations: [VaultLocation]) {
        let ignorePatterns = showSystemFiles ? [] : ["_memory.md", "_metadata.md", "agent.md", ".git"]
        let selectedPath = locations.first(where: { $0.id == selectedLocationId })?.path
        
        var results = queryNotes(searchTerm: searchText, pathFilter: selectedPath, ignorePatterns: ignorePatterns)
        
        // Aplicar ordenamiento en Swift
        switch sortOption {
        case .name:
            results.sort { $0.title.lowercased() < $1.title.lowercased() }
        case .date:
            // Por ahora query_notes ya ordena por fecha, pero esto asegura consistencia
            break 
        }
        
        self.notes = results
    }
    
    func syncAll(locations: [VaultLocation]) {
        for location in locations { _ = scanVault(path: location.path, ignorePatterns: []) }
        refreshNotes(locations: locations)
    }
    
    func createNewNote(locations: [VaultLocation]) {
        guard let location = locations.first(where: { $0.id == selectedLocationId }) else { return }
        let fileName = "Nueva Nota \(Date().timeIntervalSince1970).md"
        let fullPath = URL(fileURLWithPath: location.path).appendingPathComponent(fileName).path
        if createItem(path: fullPath, isDir: false) {
            syncAll(locations: locations)
            // Abrir automáticamente la nueva nota
            if let newNote = notes.first(where: { $0.path == fullPath }) {
                openNote(newNote)
            }
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
    
    func openNote(_ note: NoteRecord) {
        if !tabs.contains(where: { $0.id == note.id }) {
            // Cargar modo específico de esta nota, si no existe usar el global
            let savedModeStr = UserDefaults.standard.string(forKey: "render_mode_\(note.id)")
            let savedMode = RenderMode(rawValue: savedModeStr ?? "") ?? currentDefaultMode
            
            let newTab = TabItem(id: note.id, title: note.title, content: note.content, renderMode: savedMode)
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
