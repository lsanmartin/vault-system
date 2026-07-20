import Foundation
import SwiftUI
import os

/// Representa una ubicación autorizada por el usuario (Vault o carpeta externa).
struct VaultLocation: Identifiable, Codable {
    let id: UUID
    let name: String
    let bookmarkData: Data
    let path: String
    
    var url: URL? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else { return nil }
        if isStale {
            // Regenerar bookmark si es posible
            if let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                // Se notificará al manager para persistir el bookmark renovado
                NotificationCenter.default.post(name: Notification.Name("BookmarkBecameStale"), object: nil, userInfo: ["path": url.path, "newBookmark": fresh])
            }
        }
        return url
    }
}

/// Administrador central del espacio de trabajo.
/// Gestiona los permisos de acceso seguro (Security-Scoped Bookmarks) requeridos por el App Sandbox de macOS.
class WorkspaceManager: ObservableObject {
    @Published var locations: [VaultLocation] = []
    @Published var systemLocation: VaultLocation?
    @Published var isAuthorized: Bool = false
    @Published var scanProgress: [String: Double] = [:]
    private var progressTimers: [String: Timer] = [:]
    
    var allLocations: [VaultLocation] {
        if let sys = systemLocation {
            return locations + [sys]
        }
        return locations
    }
    
    private let logger = Logger(subsystem: "cl.nicelio.vault.VaultSystem", category: "WorkspaceManager")
    private let locationsKey = "cl.nicelio.vault.vaultLocations"
    
    init() {
        // Migración de Bundle ID: com.apple.vault → cl.nicelio.vault
        if UserDefaults.standard.data(forKey: locationsKey) == nil,
           let oldData = UserDefaults.standard.data(forKey: "com.apple.vault.vaultLocations") {
            UserDefaults.standard.set(oldData, forKey: locationsKey)
            UserDefaults.standard.removeObject(forKey: "com.apple.vault.vaultLocations")
        }
        restoreLocations()
        initializeSystemWorkspace()
    }
    
    private func initializeSystemWorkspace() {
        let systemVaultURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vault_system/system_workspace")
        
        if !FileManager.default.fileExists(atPath: systemVaultURL.path) {
            try? FileManager.default.createDirectory(at: systemVaultURL, withIntermediateDirectories: true)
                let contextURL = systemVaultURL.appendingPathComponent("Contexto.md")
                let defaultContext = """
                # Sistema Operativo Cognitivo
                
                Taxonomía del VaultSystem (Tres Capas):
                1. Capa de Contenido (Base): Archivos crudos de Markdown.
                2. Capa Semántica (Metadatos): Carpetas '_', archivos _metadata.md y _memory.md. Aquí se almacenan los índices conceptuales.
                3. Capa de Telemetría y Sistema: El sistema ya no se guarda en `00-Sistema/` dentro de los workspaces de contenido. Ahora vive globalmente en su propio entorno aislado (`~/.vault_system/system_workspace`).

                Importante: 
                - Tu alcance como IA a estas capas está restringido por los permisos de tu Token MCP. 
                - Puedes (y debes) invocar la herramienta `vault_list_workspaces` apenas te conectes para descubrir dinámicamente las rutas absolutas autorizadas para ti.
                - Cuando necesites registrar logs de telemetría o configurar al agente, hazlo dentro del workspace de sistema indicado por esa lista.
                """
                try? defaultContext.write(to: contextURL, atomically: true, encoding: .utf8)
            }
            
            let mockBookmark = Data()
            self.systemLocation = VaultLocation(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID(),
                name: "Contexto de Sistema",
                bookmarkData: mockBookmark,
                path: systemVaultURL.path
            )
            initGitRepo(workspacePath: systemVaultURL.path)
    }
    
    /// Presenta el panel nativo de macOS para que el usuario seleccione carpetas adicionales.
    func requestAccess() {
        let panel = NSOpenPanel()
        panel.message = "Selecciona carpetas para añadir a la lista blanca"
        panel.prompt = "Añadir a Vault"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        
        panel.begin { [weak self] response in
            if response == .OK {
                for url in panel.urls {
                    self?.addLocation(for: url)
                }
            }
        }
    }
    
    /// Crea y guarda un bookmark para una nueva URL.
    private func addLocation(for url: URL) {
        do {
            // Symlink dedup: resolver symlinks antes de comparar
            let resolvedURL: URL
            if let canonical = (try? url.resolvingSymlinksInPath()) {
                resolvedURL = canonical
            } else {
                resolvedURL = url
            }

            // Verificar que no exista ya (por ruta resuelta)
            let resolvedPath = resolvedURL.path
            if locations.contains(where: { $0.path == resolvedPath }) {
                logger.info("Ubicación duplicada omitida (symlink resuelto): \(url.path) → \(resolvedPath)")
                return
            }

            let bookmarkData = try resolvedURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            let newLocation = VaultLocation(
                id: UUID(),
                name: resolvedURL.lastPathComponent,
                bookmarkData: bookmarkData,
                path: resolvedPath
            )

            DispatchQueue.main.async {
                self.locations.append(newLocation)
                self.saveToDisk()
                _ = resolvedURL.startAccessingSecurityScopedResource()
                self.isAuthorized = true
                self.logger.info("Nueva ubicación añadida: \(resolvedPath)")
                initGitRepo(workspacePath: resolvedPath)
            }
        } catch {
            logger.error("Error al crear el bookmark para \(url.path): \(error.localizedDescription)")
        }
    }
    
    /// Guarda la lista de ubicaciones en UserDefaults.
    private func saveToDisk() {
        if let encoded = try? JSONEncoder().encode(locations) {
            UserDefaults.standard.set(encoded, forKey: locationsKey)
        }
        exportConfigBackup()
    }
    
    /// Restaura todas las ubicaciones guardadas y activa su acceso seguro.
    private func restoreLocations() {
        guard let data = UserDefaults.standard.data(forKey: locationsKey),
              let decoded = try? JSONDecoder().decode([VaultLocation].self, from: data) else {
            return
        }
        
        self.locations = decoded
        for location in locations {
            if let url = location.url {
                if url.startAccessingSecurityScopedResource() {
                    self.logger.info("Acceso restaurado para: \(url.path)")
                    self.isAuthorized = true
                    initGitRepo(workspacePath: url.path)
                } else {
                    self.logger.error("No se pudo restaurar acceso para: \(url.path)")
                }
            }
        }
    }
    
    /// Fuerza la descarga de iCloud para todos los archivos en lotes throttleados.
    /// Cada lote de 20 archivos, con 0.5s de pausa entre lotes.
    func hydrateAll() {
        logger.info("Iniciando hidratación masiva (throttle: 20 archivos/lote)...")

        let batchSize = 20
        let batchDelay: useconds_t = 500_000 // 0.5s

        for location in locations {
            guard let url = location.url else { continue }

            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )

            var pending: [URL] = []

            while let fileURL = enumerator?.nextObject() as? URL {
                do {
                    let values = try fileURL.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                    if values.isUbiquitousItem ?? false {
                        if values.ubiquitousItemDownloadingStatus != .current {
                            pending.append(fileURL)
                            if pending.count >= batchSize {
                                flushDownloadBatch(pending)
                                pending.removeAll()
                                usleep(batchDelay)
                            }
                        }
                    }
                } catch {
                    logger.error("Error al hidratar \(fileURL.path): \(error.localizedDescription)")
                }
            }

            // Último lote parcial
            if !pending.isEmpty {
                flushDownloadBatch(pending)
            }
        }
        logger.info("Hidratación completada.")
    }

    private func flushDownloadBatch(_ batch: [URL]) {
        for fileURL in batch {
            do {
                logger.debug("Hidratando: \(fileURL.lastPathComponent)")
                try FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
            } catch {
                logger.error("Error hidratando \(fileURL.path): \(error.localizedDescription)")
            }
        }
    }

    /// Escanea después de hidratar, esperando que iCloud complete descargas.
    /// Reduce la probabilidad de indexar stubs vacíos.
    func scanAfterHydration(for path: String) {
        logger.info("Iniciando hidratación + scan postergado para: \(path)")
        hydrateAll()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.logger.info("Hidratación completada, iniciando scan: \(path)")
            self?.triggerScan(for: path)
        }
    }
    
    func triggerScan(for path: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = scanVault(path: path, ignorePatterns: ["/.git", "/.obsidian", "/_documentar", "/05-IA-Drafts/gemini"])
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.scanProgress[path] = 0.0
            self?.progressTimers[path]?.invalidate()
            
            self?.progressTimers[path] = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
                let currentProgress = Double(getScanProgress(path: path))
                DispatchQueue.main.async {
                    self?.scanProgress[path] = currentProgress
                    if currentProgress >= 100.0 {
                        timer.invalidate()
                        self?.progressTimers.removeValue(forKey: path)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self?.scanProgress.removeValue(forKey: path)
                        }
                        NotificationCenter.default.post(name: NSNotification.Name("VaultScanDidFinish"), object: nil)
                    }
                }
            }
        }
    }
    
    func triggerScanAll() {
        for loc in allLocations {
            triggerScan(for: loc.path)
        }
    }

    func abortScan(for path: String) {
        _ = cancelScan(path: path)
        DispatchQueue.main.async { [weak self] in
            self?.scanProgress.removeValue(forKey: path)
            self?.progressTimers[path]?.invalidate()
            self?.progressTimers.removeValue(forKey: path)
        }
    }

    func abortScanAll() {
        for loc in allLocations {
            abortScan(for: loc.path)
        }
    }

    /// Elimina una ubicación y libera su recurso.
    func removeLocation(id: UUID) {
        if let index = locations.firstIndex(where: { $0.id == id }) {
            let location = locations[index]
            location.url?.stopAccessingSecurityScopedResource()
            _ = removeVaultPath(path: location.path)
            NotificationCenter.default.post(name: Notification.Name("WorkspaceRemoved"), object: nil, userInfo: ["path": location.path])
            locations.remove(at: index)
            saveToDisk()
            if locations.isEmpty { isAuthorized = false }
        }
    }
    
    func removeLocation(at offsets: IndexSet) {
        for index in offsets {
            let location = locations[index]
            location.url?.stopAccessingSecurityScopedResource()
            _ = removeVaultPath(path: location.path)
            NotificationCenter.default.post(name: Notification.Name("WorkspaceRemoved"), object: nil, userInfo: ["path": location.path])
        }
        locations.remove(atOffsets: offsets)
        saveToDisk()
        if locations.isEmpty { isAuthorized = false }
    }

    func stopAccess() {
        for location in locations {
            location.url?.stopAccessingSecurityScopedResource()
        }
    }

    /// Exporta la configuración a un archivo JSON de respaldo fuera del sandbox.
    func exportConfigBackup() {
        let backupURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vault_system/config_backup.json")
        
        let backup: [String: Any] = [
            "version": "0.1.0",
            "locations": locations.map { ["name": $0.name, "path": $0.path] },
            "exportDate": ISO8601DateFormatter().string(from: Date())
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: backup, options: .prettyPrinted) {
            try? data.write(to: backupURL)
            logger.info("Config backup exportado a: \(backupURL.path)")
        }
    }
    
    /// Verifica si un archivo pertenece a alguno de los workspaces autorizados
    func verifyAndResolveWorkspace(for fileURL: URL) -> Bool {
        let filePath = fileURL.path
        return allLocations.contains { location in
            filePath.hasPrefix(location.path)
        }
    }
}
