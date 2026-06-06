import Foundation
import SwiftUI

/// Representa una pestaña abierta en el editor
struct TabItem: Identifiable, Hashable {
    let id: String // Path del archivo
    let title: String
    var content: String
    var isPreviewMode: Bool = true
    var isHTML: Bool = false
    
    // Detectar lenguaje para el resaltado
    var language: String {
        if isHTML || id.lowercased().hasSuffix(".html") { return "html" }
        return "markdown"
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: TabItem, rhs: TabItem) -> Bool {
        lhs.id == rhs.id
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "Sistema"
    case light = "Claro"
    case dark = "Oscuro"
    case night = "Noche (IR)"
    
    var id: String { self.rawValue }
}

class EditorViewModel: ObservableObject {
    @Published var tabs: [TabItem] = []
    @Published var activeTabId: String?
    @Published var notes: [NoteRecord] = []
    @Published var searchText: String = ""
    @Published var selectedLocationId: UUID? // Filtrar por workspace
    @Published var showSystemFiles: Bool = true // Meta-memorias activadas por defecto
    @Published var selectedTheme: AppTheme = .system
    
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
                // Refrescar automáticamente si hay cambios en disco
            }
        }
    }
    
    func refreshNotes(locations: [VaultLocation]) {
        let ignorePatterns = showSystemFiles ? [] : [
            "_memory.md", "_metadata.md", "_specs.md", "_lore.md",
            "00-Sistema", "01-Diario", "05-IA-Drafts",
            "agent.md", ".git", ".obsidian"
        ]
        
        let selectedPath = locations.first(where: { $0.id == selectedLocationId })?.path
        
        self.notes = queryNotes(searchTerm: searchText, pathFilter: selectedPath, ignorePatterns: ignorePatterns)
    }
    
    func syncAll(locations: [VaultLocation]) {
        for location in locations {
            _ = scanVault(path: location.path, ignorePatterns: [])
        }
        refreshNotes(locations: locations)
    }
    
    func openNote(_ note: NoteRecord) {
        if !tabs.contains(where: { $0.id == note.id }) {
            let newTab = TabItem(id: note.id, title: note.title, content: note.content)
            tabs.append(newTab)
        }
        activeTabId = note.id
        // addTelemetryEvent(context: "Editor", eventType: "OpenNote", message: "Abierta nota: \(note.title)")
    }
    
    func closeTab(at offsets: IndexSet) {
        tabs.remove(atOffsets: offsets)
        if let last = tabs.last {
            activeTabId = last.id
        } else {
            activeTabId = nil
        }
    }
    
    func togglePreview() {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabId }) else { return }
        tabs[index].isPreviewMode.toggle()
    }
    
    func saveActiveTab(locations: [VaultLocation]) {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabId }) else { return }
        let tab = tabs[index]
        _ = saveNote(path: tab.id, content: tab.content)
        // addTelemetryEvent(context: "Editor", eventType: "SaveNote", message: "Nota guardada: \(tab.title). Resultado: \(result)")
        refreshNotes(locations: locations)
    }
}
