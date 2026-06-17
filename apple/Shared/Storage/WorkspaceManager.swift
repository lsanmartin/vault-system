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
        return try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
    }
}

/// Administrador central del espacio de trabajo.
/// Gestiona los permisos de acceso seguro (Security-Scoped Bookmarks) requeridos por el App Sandbox de macOS.
class WorkspaceManager: ObservableObject {
    @Published var locations: [VaultLocation] = []
    @Published var systemLocation: VaultLocation?
    @Published var isAuthorized: Bool = false
    
    var allLocations: [VaultLocation] {
        if let sys = systemLocation {
            return locations + [sys]
        }
        return locations
    }
    
    private let logger = Logger(subsystem: "com.apple.vault.VaultSystem", category: "WorkspaceManager")
    private let locationsKey = "com.apple.vault.vaultLocations"
    
    init() {
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
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            let newLocation = VaultLocation(
                id: UUID(),
                name: url.lastPathComponent,
                bookmarkData: bookmarkData,
                path: url.path
            )
            
            DispatchQueue.main.async {
                // Evitar duplicados por ruta
                if !self.locations.contains(where: { $0.path == url.path }) {
                    self.locations.append(newLocation)
                    self.saveToDisk()
                    _ = url.startAccessingSecurityScopedResource()
                    self.isAuthorized = true
                    self.logger.info("Nueva ubicación añadida e hidratada: \(url.path)")
                }
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
                } else {
                    self.logger.error("No se pudo restaurar acceso para: \(url.path)")
                }
            }
        }
    }
    
    /// Fuerza la descarga de iCloud para todos los archivos en todas las ubicaciones.
    func hydrateAll() {
        logger.info("Iniciando hidratación masiva...")
        for location in locations {
            guard let url = location.url else { continue }
            
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            
            while let fileURL = enumerator?.nextObject() as? URL {
                do {
                    let values = try fileURL.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                    if values.isUbiquitousItem ?? false {
                        if values.ubiquitousItemDownloadingStatus != .current {
                            self.logger.info("Hidratando: \(fileURL.lastPathComponent)")
                            try FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
                        }
                    }
                } catch {
                    logger.error("Error al hidratar \(fileURL.path): \(error.localizedDescription)")
                }
            }
        }
        logger.info("Hidratación completada.")
    }
    
    /// Elimina una ubicación y libera su recurso.
    func removeLocation(at offsets: IndexSet) {
        for index in offsets {
            let location = locations[index]
            location.url?.stopAccessingSecurityScopedResource()
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
}
