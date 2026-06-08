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

class EditorViewModel: ObservableObject {
    @Published var tabs: [TabItem] = []
    @Published var activeTabId: String?
    @Published var notes: [NoteRecord] = []
    @Published var searchText: String = ""
    @Published var selectedLocationId: UUID?
    @Published var showSystemFiles: Bool = true 
    @Published var selectedTheme: AppTheme = .system
    
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
            if currentTs > self?.lastSyncTs ?? 0 { self?.lastSyncTs = currentTs }
        }
    }
    
    func refreshNotes(locations: [VaultLocation]) {
        let ignorePatterns = showSystemFiles ? [] : ["_memory.md", "_metadata.md", "agent.md", ".git"]
        let selectedPath = locations.first(where: { $0.id == selectedLocationId })?.path
        self.notes = queryNotes(searchTerm: searchText, pathFilter: selectedPath, ignorePatterns: ignorePatterns)
    }
    
    func syncAll(locations: [VaultLocation]) {
        for location in locations { _ = scanVault(path: location.path, ignorePatterns: []) }
        refreshNotes(locations: locations)
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
