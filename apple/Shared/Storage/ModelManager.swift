import Foundation
import Combine
import HuggingFace
import Hub

/// Error del Model Manager con mensajes legibles para la UI.
public enum ModelManagerError: LocalizedError {
    case invalidRepoID(String)
    case alreadyDownloading
    case noActiveModel
    case customAlreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRepoID(let id):
            return "Repo id inválido: \(id). Formato esperado: 'namespace/nombre'."
        case .alreadyDownloading:
            return "Ya hay una descarga de modelo en curso. Cancela o espera a que termine."
        case .noActiveModel:
            return "No hay un modelo local activo. Selecciona uno en el Model Manager."
        case .customAlreadyExists(let id):
            return "El modelo '\(id)' ya está en el catálogo."
        }
    }
}

/// Modelo local MLX del Cerebro Local. `id` es el repo id de Hugging Face
/// (ej. "mlx-community/gemma-4-12B-it-4bit"). `isCustom` distingue los repos
/// que el usuario agregó a mano de los del catálogo oficial.
public struct LocalModel: Identifiable, Codable, Hashable {
    public var id: String
    public var name: String
    /// Tamaño estimado en GB (del catálogo / verificado en HF). El tamaño real
    /// en disco se calcula en `ModelManager.diskSizes`.
    public var estimatedSizeGB: Double
    public var shortDescription: String
    public var isCustom: Bool
    public var isDefault: Bool

    public init(id: String, name: String, estimatedSizeGB: Double, shortDescription: String, isCustom: Bool, isDefault: Bool) {
        self.id = id
        self.name = name
        self.estimatedSizeGB = estimatedSizeGB
        self.shortDescription = shortDescription
        self.isCustom = isCustom
        self.isDefault = isDefault
    }
}

/// Gestor de modelos locales del Cerebro Local (MLX).
///
/// Responsabilidades:
/// - Catálogo oficial embebido + modelos custom persistidos en UserDefaults.
/// - Ubicación canónica `~/.vault_system/models/<repoId>/`.
/// - Migración automática (idempotente) desde el contenedor legacy
///   (`Documents/huggingface/models/`) sin re-descargar pesos.
/// - Descarga directa al directorio canónico con progreso (bridge a
///   `LocalBrain` para el overlay de ContentView).
/// - Cambio / borrado / agregado de modelos.
public final class ModelManager: ObservableObject {
    public static let shared = ModelManager()

    /// Catálogo oficial (formato MLX nativo — NO GGUF). Tamaños estimados
    /// verificados contra la Hugging Face API (2026-08-15).
    public static let catalog: [LocalModel] = [
        LocalModel(
            id: "mlx-community/gemma-4-12B-it-4bit",
            name: "Gemma 4 12B",
            estimatedSizeGB: 6.7,
            shortDescription: "Modelo completo 12B cuantizado 4-bit. Máxima calidad; ocupa más memoria y disco.",
            isCustom: false,
            isDefault: true
        ),
        LocalModel(
            id: "mlx-community/gemma-4-e2b-it-4bit",
            name: "Gemma 4 E2B",
            estimatedSizeGB: 3.6,
            shortDescription: "E2B 4-bit. Rápido y ligero, ideal para uso diario.",
            isCustom: false,
            isDefault: false
        ),
        LocalModel(
            id: "mlx-community/gemma-4-E2B-it-qat-4bit",
            name: "Gemma 4 E2B QAT",
            estimatedSizeGB: 4.4,
            shortDescription: "QAT (quantization-aware training). Mejor fidelidad de pesos cuantizados.",
            isCustom: false,
            isDefault: false
        ),
        LocalModel(
            id: "mlx-community/gemma-4-e2b-it-OptiQ-4bit",
            name: "Gemma 4 E2B OptiQ",
            estimatedSizeGB: 4.3,
            shortDescription: "Mixed-precision con cuantización optimizada. Mejor calidad por peso.",
            isCustom: false,
            isDefault: false
        ),
    ]

    public static let defaultModelID = "mlx-community/gemma-4-12B-it-4bit"

    private static let activeModelKey = "vault_brain_model_id"
    private static let modelInitializedKey = "vault_brain_model_initialized"
    private static let customModelsKey = "vault_custom_models"

    // MARK: - Estado observable

    /// Modelos disponibles (catálogo + custom).
    @Published public var models: [LocalModel] = []
    /// Modelo activo. `nil` = el usuario borró el activo y no eligió otro
    /// (NO re-descarga el default en silencio).
    @Published public var activeModelID: String? = nil
    /// Tamaño real en disco por repo id (bytes), tras `scanModels()`.
    @Published public var diskSizes: [String: Int64] = [:]
    /// Progreso por repo id (0.0–1.0).
    @Published public var downloadProgress: [String: Double] = [:]
    /// Hay una descarga de modelo en curso.
    @Published public var isDownloading: Bool = false
    /// Repo id del modelo en descarga (para la UI y el overlay de ContentView).
    @Published public var downloadingModelID: String? = nil
    /// Falló la migración desde el contenedor legacy (el usuario debe intervenir).
    @Published public var pendingLegacyMigration: Bool = false

    // MARK: - Estado interno

    private var customModels: [LocalModel] = []
    private var downloadTask: Task<Void, Error>? = nil
    private let queue = DispatchQueue(label: "cl.nicelio.vault.modelmanager", qos: .utility)

    // MARK: - Init

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.customModelsKey),
           let decoded = try? JSONDecoder().decode([LocalModel].self, from: data) {
            customModels = decoded
        }
        models = Self.catalog + customModels

        if UserDefaults.standard.bool(forKey: Self.modelInitializedKey) {
            activeModelID = UserDefaults.standard.string(forKey: Self.activeModelKey)
        } else {
            // Primer arranque: activar el modelo por defecto del catálogo.
            activeModelID = Self.defaultModelID
            UserDefaults.standard.set(Self.defaultModelID, forKey: Self.activeModelKey)
            UserDefaults.standard.set(true, forKey: Self.modelInitializedKey)
        }

        // Escaneo en background + migración legacy (no bloquea el arranque).
        queue.async { [weak self] in
            self?.scanModels()
            self?.migrateLegacyModels()
        }
    }

    // MARK: - Rutas

    func canonicalModelsDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vault_system/models", isDirectory: true)
    }

    func modelDirectory(for id: String) -> URL {
        canonicalModelsDir().appendingPathComponent(id, isDirectory: true)
    }

    /// Devuelve la ubicación legacy que contiene `config.json` (contenedor de la
    /// app o Documents real), o nil si no existe.
    func legacyModelDirectory(for id: String) -> URL? {
        let bundleID = Bundle.main.bundleIdentifier ?? "cl.nicelio.vault.VaultSystem"
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/\(bundleID)/Data/Documents/huggingface/models/\(id)", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/huggingface/models/\(id)", isDirectory: true),
        ]
        for dir in candidates {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path) {
                return dir
            }
        }
        return nil
    }

    private func hubCacheDirectory(for id: String) -> URL {
        let cacheName = "models--" + id.replacingOccurrences(of: "/", with: "--")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/\(cacheName)", isDirectory: true)
    }

    // MARK: - Estado del modelo

    func modelIsDownloaded(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: modelDirectory(for: id).appendingPathComponent("config.json").path)
    }

    func modelIsInHubCache(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: hubCacheDirectory(for: id).path)
    }

    /// Verdadero cuando hay un modelo elegible para cargar: o bien hay uno
    /// activo seleccionado, o bien el default sigue descargado. Evita que
    /// `getOrLoadContainer` re-descargue en silencio un modelo que el usuario
    /// borró a propósito.
    var hasConfiguredModel: Bool {
        activeModelID != nil || modelIsDownloaded(Self.defaultModelID)
    }

    private func setActiveModelID(_ id: String?) {
        DispatchQueue.main.async {
            self.activeModelID = id
            if let id {
                UserDefaults.standard.set(id, forKey: Self.activeModelKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activeModelKey)
            }
        }
    }

    /// Escanea el disco y actualiza `diskSizes` con los tamaños reales.
    func scanModels() {
        var sizes: [String: Int64] = [:]
        for model in models {
            let dir = modelDirectory(for: model.id)
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path) {
                sizes[model.id] = sizeOnDisk(at: dir)
            }
        }
        DispatchQueue.main.async {
            self.diskSizes = sizes
        }
    }

    func sizeOnDisk(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    // MARK: - Migración legacy → canónico

    /// Migra el modelo `id` desde la ubicación legacy al directorio canónico si
    /// aplica. Idempotente: si el canónico ya tiene `config.json`, no hace nada.
    /// Rename atómico en el mismo volumen (instantáneo, no re-descarga).
    /// Devuelve true si el canónico quedó con el modelo (ya estaba, migrado o
    /// copiado), false si falló (deja `pendingLegacyMigration = true`).
    @discardableResult
    func ensureMigrated(for id: String) async -> Bool {
        let fm = FileManager.default
        let canonical = modelDirectory(for: id)
        if fm.fileExists(atPath: canonical.appendingPathComponent("config.json").path) {
            return true
        }
        guard let legacy = legacyModelDirectory(for: id) else { return true }

        // Directorio canónico parcial (descarga abortada) → descartarlo.
        if fm.fileExists(atPath: canonical.path) {
            try? fm.removeItem(at: canonical)
        }
        // IMPORTANTE: `moveItem`/`copyItem` NO crean directorios intermedios.
        // El repo id incluye `mlx-community/`, así que hay que crear el padre
        // (`~/.vault_system/models/mlx-community/`) antes de mover.
        let parent = canonical.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try fm.moveItem(at: legacy, to: canonical)
            scanModels()
            return true
        } catch {
            // Fallback: copia + borrado (otro volumen o move falló).
            do {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                try fm.copyItem(at: legacy, to: canonical)
                try fm.removeItem(at: legacy)
                scanModels()
                return true
            } catch {
                DispatchQueue.main.async {
                    self.pendingLegacyMigration = true
                }
                return false
            }
        }
    }

    /// Migra todos los modelos del catálogo que existan en el legacy. Se ejecuta
    /// en background al arrancar; si alguno falla queda `pendingLegacyMigration`
    /// en true (la UI muestra el banner de migración pendiente).
    func migrateLegacyModels() {
        let ids = models.map(\.id)
        Task {
            var anyFailed = false
            for id in ids {
                if await ensureMigrated(for: id) == false {
                    anyFailed = true
                }
            }
            if !anyFailed {
                await MainActor.run {
                    self.pendingLegacyMigration = false
                }
            }
        }
    }

    // MARK: - Descarga

    /// Cliente HF SIN autenticación para descargas.
    ///
    /// Los modelos del catálogo son repositorios públicos. `HubClient.default`
    /// usa `tokenProvider: .environment`, que además de `HF_TOKEN` lee el archivo
    /// `~/.cache/huggingface/token` — donde el CLI de HF guarda un JWT OAuth
    /// (`hf_oauth_…`). Si ese token expira/revoca, cada descarga recibe 401
    /// (`HTTPClientError.errorCode` 1) y falla. Con `tokenProvider: .none` nunca
    /// se envía `Authorization`, así las descargas públicas siempre funcionan.
    private static let publicHubClient = HubClient(
        host: HubClient.defaultHost,
        tokenProvider: .none
    )

    /// Descarga el snapshot MLX de `id` directo al directorio canónico con
    /// progreso. Serializado: una sola descarga a la vez.
    func downloadModel(id: String) async throws {
        // Serialización con `downloadTask` (no solo `isDownloading`, que se setea
        // async vía bridge): dos callers simultáneos (click "Usar" + generación)
        // no deben crear dos tareas — el que llega segundo espera la misma.
        if isDownloading || downloadTask != nil {
            if let current = downloadingModelID, current == id, let task = downloadTask {
                try await task.value
                return
            }
            throw ModelManagerError.alreadyDownloading
        }
        guard let repo = Repo.ID(rawValue: id) else {
            throw ModelManagerError.invalidRepoID(id)
        }

        let destination = modelDirectory(for: id)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Marcar la descarga ANTES de crear la tarea: el guard reconoce la
        // descarga en curso aunque `bridgeDownload` aún no haya corrido.
        self.downloadingModelID = id

        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            do {
                self.bridgeDownload(started: true, progress: 0, modelID: id)
                _ = try await Self.publicHubClient.downloadSnapshot(
                    of: repo,
                    kind: .model,
                    to: destination,
                    progressHandler: { [weak self] progress in
                        self?.bridgeDownload(started: true, progress: progress.fractionCompleted, modelID: id)
                    }
                )
                if Task.isCancelled { throw CancellationError() }
                self.scanModels()
                self.bridgeDownload(started: false, progress: 1.0, modelID: nil)
            } catch {
                self.cleanupPartialDownload(id: id)
                if Task.isCancelled || (error as? CancellationError) != nil {
                    self.bridgeDownload(started: false, progress: 0, modelID: nil)
                } else {
                    self.bridgeDownloadError(error, modelID: id)
                }
                throw error
            }
        }
        downloadTask = task
        do {
            try await task.value
        } catch {
            downloadTask = nil
            throw error
        }
        downloadTask = nil
    }

    func cancelCurrentDownload() {
        downloadTask?.cancel()
    }

    private func cleanupPartialDownload(id: String) {
        try? FileManager.default.removeItem(at: modelDirectory(for: id))
        DispatchQueue.main.async {
            self.downloadProgress.removeValue(forKey: id)
        }
    }

    // MARK: - Bridge a LocalBrain (overlay de ContentView)

    private func bridgeDownload(started: Bool, progress: Double, modelID: String?) {
        DispatchQueue.main.async {
            let brain = LocalBrain.shared
            brain.isDownloading = started
            brain.downloadProgress = progress
            if started {
                brain.modelStatus = .downloading(progress: progress)
            } else if progress >= 1.0 {
                brain.modelStatus = .ready
            } else {
                brain.modelStatus = .notLoaded
            }
            self.isDownloading = started
            self.downloadingModelID = modelID
            if let id = modelID {
                self.downloadProgress[id] = progress
            }
        }
    }

    private func bridgeDownloadError(_ error: Error, modelID: String) {
        DispatchQueue.main.async {
            let brain = LocalBrain.shared
            brain.isDownloading = false
            brain.downloadProgress = 0
            brain.modelStatus = .error(error.localizedDescription)
            self.isDownloading = false
            self.downloadingModelID = nil
            self.downloadProgress.removeValue(forKey: modelID)
        }
    }

    // MARK: - CRUD

    /// Cambia el modelo activo. Si `id == activo`, no hace nada. Libera la GPU
    /// del modelo anterior y marca el nuevo como activo de inmediato.
    ///
    /// Si el modelo no está en disco, "Usar" NO se bloquea esperando la descarga:
    /// se marca activo al instante y la descarga corre en background (con progreso
    /// en el overlay). Si se corta (p.ej. la app se cierra), el modelo sigue activo
    /// y `getOrLoadContainer` la retoma al generar. Antes esto dejaba al usuario
    /// atrapado en "descargando modelo" y el modelo nunca llegaba a activarse.
    func setActiveModel(id: String) async throws {
        guard let model = models.first(where: { $0.id == id }) else {
            throw ModelManagerError.invalidRepoID(id)
        }
        if activeModelID == id { return }

        // Liberar el modelo anterior de la GPU (el nuevo se carga bajo demanda).
        LocalBrain.shared.switchModel(to: nil)
        setActiveModelID(id)

        let available = modelIsDownloaded(id) || modelIsInHubCache(id)
        if available {
            if LocalBrain.shared.isEnabled {
                LocalBrain.shared.preloadModel()
            }
        } else {
            // Descarga en background, sin bloquear la UI. Los errores se reportan
            // vía `bridgeDownloadError` (overlay + telemetría).
            Task {
                try? await downloadModel(id: id)
            }
        }
        _ = model
    }

    /// Libera el modelo del disco (canónico + cache HF) y de la memoria si es el
    /// activo, PERO lo DEJA en la lista: la entrada sigue visible y vuelve a
    /// mostrar "Descargar". Es el botón 🗑 del Model Manager — solo limpia
    /// pesos/RAM/espacio, nunca toca la lista.
    func releaseModel(id: String) async throws {
        if isDownloading, downloadingModelID == id {
            cancelCurrentDownload()
            if let task = downloadTask {
                _ = try? await task.value
            }
        }
        let fm = FileManager.default
        let dir = modelDirectory(for: id)
        if fm.fileExists(atPath: dir.path) {
            try? fm.removeItem(at: dir)
        }
        try? fm.removeItem(at: hubCacheDirectory(for: id))

        if activeModelID == id {
            LocalBrain.shared.switchModel(to: nil)
            setActiveModelID(nil)
        }
        scanModels()
    }

    /// Quita un modelo CUSTOM de la lista (y libera sus archivos). No aplica a
    /// modelos del catálogo oficial — esos no se pueden quitar de la lista.
    /// Devuelve false si el id no es un modelo custom.
    @discardableResult
    func removeCustomModel(id: String) async throws -> Bool {
        guard let idx = models.firstIndex(where: { $0.id == id }), models[idx].isCustom else {
            return false
        }
        customModels.removeAll { $0.id == id }
        persistCustomModels()
        models = Self.catalog + customModels
        try await releaseModel(id: id)
        return true
    }

    /// Agrega un modelo custom validando el formato `namespace/nombre`.
    /// Devuelve false si el repo es inválido o ya existe en el catálogo.
    @discardableResult
    func addCustomModel(repoID: String) -> Bool {
        let trimmed = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Repo.ID(rawValue: trimmed) != nil else { return false }
        guard !models.contains(where: { $0.id == trimmed }) else { return false }

        let name = trimmed.components(separatedBy: "/").last?
            .replacingOccurrences(of: "-", with: " ")
            .capitalized ?? trimmed
        let model = LocalModel(
            id: trimmed,
            name: name,
            estimatedSizeGB: 0,
            shortDescription: "Modelo custom (repositorio externo)",
            isCustom: true,
            isDefault: false
        )
        customModels.append(model)
        persistCustomModels()
        models = Self.catalog + customModels
        scanModels()
        return true
    }

    private func persistCustomModels() {
        if let data = try? JSONEncoder().encode(customModels) {
            UserDefaults.standard.set(data, forKey: Self.customModelsKey)
        }
    }

    // MARK: - Entorno

    /// Inyecta `HF_TOKEN` desde `~/.cache/huggingface/token` (si es válido) o lo
    /// limpia. `HubClient.default` usa `tokenProvider: .environment`.
    static func ensureHFEnvironment() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tokenURL = home.appendingPathComponent(".cache/huggingface/token")
        if let tokenData = try? Data(contentsOf: tokenURL),
           let token = String(data: tokenData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.hasPrefix("hf_oauth_") {
            setenv("HF_TOKEN", token, 1)
        } else {
            unsetenv("HF_TOKEN")
        }
    }
}
