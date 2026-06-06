import Foundation
import os

class CloudWorkspacePresenter: NSObject, NSFilePresenter, ObservableObject {
    var presentedItemURL: URL?
    var presentedItemOperationQueue: OperationQueue = .main
    
    private let logger = Logger(subsystem: "com.apple.vault.VaultSystem", category: "CloudSync")

    init(containerURL: URL) {
        self.presentedItemURL = containerURL
        super.init()
        NSFileCoordinator.addFilePresenter(self)
        logger.info("NSFilePresenter initialized for container: \(containerURL.path)")
    }

    deinit {
        NSFileCoordinator.removeFilePresenter(self)
    }

    // Se dispara cuando el SO detecta que un archivo ha cambiado (por ejemplo, desde el iPhone o iCloud Web)
    func presentedItemDidChange() {
        guard let url = presentedItemURL else { return }
        logger.debug("presentedItemDidChange triggered for: \(url.path)")
        self.hydrateAndSyncLocalCache(from: url)
    }

    // Fuerza la descarga de archivos que están en el disco pero "deshidratados" (.icloud)
    func hydrateAndSyncLocalCache(from cloudURL: URL) {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        
        guard let enumerator = fileManager.enumerator(at: cloudURL, includingPropertiesForKeys: keys) else {
            logger.error("No se pudo crear el enumerador para la ruta: \(cloudURL.path)")
            return
        }
        
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: Set(keys)),
               values.isUbiquitousItem == true {
                
                if values.ubiquitousItemDownloadingStatus != .current {
                    logger.info("Hidratando archivo remoto: \(fileURL.lastPathComponent)")
                    do {
                        try fileManager.startDownloadingUbiquitousItem(at: fileURL)
                    } catch {
                        logger.error("Error al forzar descarga de \(fileURL.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        }
        // TODO: Notificar al Rust Core vía FFI que la hidratación ha ocurrido y refrescar cachés.
    }
}
