import Foundation
import Combine
import MLX
import MLXLMCommon
import MLXLLM
import MLXHuggingFace
import HuggingFace
import Hub
import Tokenizers

public enum ModelStatus: Equatable {
    case notLoaded
    case downloading(progress: Double)
    case loading
    case ready
    case error(String)
}

actor GPUInferenceActor {
    static let shared = GPUInferenceActor()
    private init() {}
    
    func run<T>(_ operation: () async throws -> T) async rethrows -> T {
        return try await operation()
    }
}

/// Orquestador del Cerebro Local Nativo con Descarga Directa Autónoma y Estado Caliente GPU (mlx-swift-lm v3)
public final class LocalBrain: ObservableObject {
    public static let shared = LocalBrain()
    
    @Published public var isProcessing: Bool = false
    @Published public var pendingCount: Int = 0
    @Published public var currentNoteTitle: String = ""
    @Published public var downloadProgress: Double = 0.0
    @Published public var isDownloading: Bool = false
    @Published public var modelStatus: ModelStatus = .notLoaded
    /// Estado de activación del cerebro local. Al desactivarse se libera el modelo de la memoria GPU.
    @Published public var isEnabled: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "cl.nicelio.vault.brain", qos: .background)
    private var downloadTask: Task<Void, Never>? = nil
    private var activeChatTask: Task<Void, Never>? = nil
    private var digestionTask: Task<Void, Never>? = nil
    
    // Contenedor caliente persistente en GPU
    private var activeContainer: ModelContainer? = nil
    
    /// Cancela la descarga del modelo local en ejecucion (delega al Model Manager,
    /// que es el dueño real de las descargas).
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        ModelManager.shared.cancelCurrentDownload()
        DispatchQueue.main.async {
            self.isDownloading = false
            self.downloadProgress = 0.0
        }
    }

    /// Cancela la generación de chat en curso
    public func cancelChat() {
        activeChatTask?.cancel()
        activeChatTask = nil
    }

    /// Pausa la digestión cognitiva para dar prioridad al chat.
    /// La digestión ocupa el GPUInferenceActor (actor serializado) en un bucle de
    /// notas; si no se cancela, el chat espera detrás de N generaciones y parece
    /// "muerto". Cancela el task actual y deja isProcessing en false para que
    /// `startDigestion` pueda reanudarse más tarde con notas nuevas.
    private func pauseDigestionForChat() {
        digestionTask?.cancel()
        digestionTask = nil
        Task { @MainActor in
            self.isProcessing = false
            self.currentNoteTitle = ""
        }
    }

    /// Reanuda la digestión cognitiva tras el chat (si quedan notas pendientes
    /// y el usuario no desactivó el cerebro). Se ejecuta con un pequeño delay
    /// para no competir con el final de la generación del chat.
    private func resumeDigestionAfterChat() {
        guard isEnabled else { return }
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.isEnabled, !self.isProcessing else { return }
            DispatchQueue.main.async {
                self.startDigestion()
            }
        }
    }

    /// Activa o desactiva temporalmente el cerebro local.
    /// Al desactivar se cancela el trabajo en curso, se libera el modelo de la memoria GPU/Metal
    /// y el estado vuelve a `.notLoaded` (se recarga bajo demanda al reactivar).
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "vault_brain_enabled")

        if !enabled {
            Telemetry.shared.log("LocalBrain", eventType: "Status", message: "Cerebro local desactivado por el usuario. Liberando modelo de la memoria GPU.")

            // Cancelar trabajo en curso para liberar memoria de inmediato
            activeChatTask?.cancel()
            activeChatTask = nil
            digestionTask?.cancel()
            digestionTask = nil
            cancelDownload()

            Task { @MainActor in
                self.activeContainer = nil
                MLX.GPU.clearCache()
                self.modelStatus = .notLoaded
                self.isProcessing = false
            }
        } else {
            Telemetry.shared.log("LocalBrain", eventType: "Status", message: "Cerebro local activado por el usuario. Se cargará bajo demanda en la próxima generación.")
        }
    }

    private init() {
        // Limitar cache de reuso de tensores de Metal a 64MB para evitar presion de memoria
        MLX.GPU.set(cacheLimit: 64 * 1024 * 1024)

        // Restaurar estado de activación persistido (default: activado)
        self.isEnabled = UserDefaults.standard.object(forKey: "vault_brain_enabled") as? Bool ?? false

        NotificationCenter.default.publisher(for: NSNotification.Name("VaultScanDidFinish"))
            .sink { [weak self] _ in
                self?.updatePendingCount()
            }
            .store(in: &cancellables)
    }
    
    /// Actualiza el conteo de notas pendientes
    public func updatePendingCount() {
        queue.async {
            let pending = getPendingSummaryNotes(limit: 100)
            DispatchQueue.main.async {
                self.pendingCount = pending.count
            }
        }
    }
    
    /// Inicializa u obtiene el contenedor caliente del modelo local de forma segura.
    /// Resuelve el modelo activo desde `ModelManager` (nunca hardcodeado).
    public func getOrLoadContainer() async throws -> ModelContainer {
        guard isEnabled else {
            throw NSError(domain: "LocalBrain", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "El cerebro local está desactivado temporalmente. Actívalo con el botón de encendido en el panel de chat."
            ])
        }
        if let container = activeContainer {
            return container
        }

        let modelId = ModelManager.shared.activeModelID ?? ModelManager.defaultModelID
        ModelManager.ensureHFEnvironment()

        // 1) Migrar desde el contenedor legacy si aplica (idempotente). Evita
        //    re-descargar 6-7 GB cuando la app sale del sandbox y la ruta de
        //    Documents cambia.
        await ModelManager.shared.ensureMigrated(for: modelId)

        // 2) Resolución de ruta: canónico → cache HF → descarga directa a canónico.
        let canonicalDir = ModelManager.shared.modelDirectory(for: modelId)
        let hasCanonical = FileManager.default.fileExists(atPath: canonicalDir.appendingPathComponent("config.json").path)

        let config: ModelConfiguration
        if hasCanonical {
            // Carga offline instantánea desde la ubicación canónica
            config = ModelConfiguration(directory: canonicalDir)
            Telemetry.shared.log("LocalBrain", eventType: "Status", message: "Modelo local encontrado (\(modelId)). Carga offline sin descarga.")
        } else if ModelManager.shared.modelIsInHubCache(modelId) {
            config = ModelConfiguration(id: modelId)
            Telemetry.shared.log("LocalBrain", eventType: "Status", message: "Modelo encontrado en cache Hugging Face (\(modelId)). Carga offline.")
        } else {
            // No está en disco: descarga directa al directorio canónico. Si el
            // usuario borró el modelo activo y no eligió otro, no re-descargar
            // en silencio.
            guard ModelManager.shared.hasConfiguredModel else {
                throw NSError(domain: "LocalBrain", code: 100, userInfo: [
                    NSLocalizedDescriptionKey: "No hay un modelo local activo. Selecciona uno en el Model Manager (icono de cubos en el chat)."
                ])
            }
            Telemetry.shared.log("LocalBrain", eventType: "Status", message: "Modelo \(modelId) no descargado. Iniciando descarga directa.")
            try await ModelManager.shared.downloadModel(id: modelId)
            config = ModelConfiguration(directory: canonicalDir)
        }

        do {
            await MainActor.run {
                self.modelStatus = .loading
            }
            let container = try await #huggingFaceLoadModelContainer(configuration: config)
            guard self.isEnabled else {
                MLX.GPU.clearCache()
                throw NSError(domain: "LocalBrain", code: 100, userInfo: [NSLocalizedDescriptionKey: "Carga cancelada: el cerebro local fue desactivado durante la carga."])
            }
            self.activeContainer = container
            await MainActor.run {
                self.downloadProgress = 1.0
                self.modelStatus = .ready
            }
            return container
        } catch {
            if isCancelledError(error) {
                // Cancelación: estado limpio, sin error en la UI.
                await MainActor.run {
                    self.isDownloading = false
                    self.modelStatus = .notLoaded
                }
                throw error
            }
            Telemetry.shared.log("LocalBrain", eventType: "Error", message: "Error al cargar el modelo \(modelId): \(error.localizedDescription)")
            await MainActor.run {
                self.modelStatus = .error(error.localizedDescription)
            }
            throw error
        }
    }

    /// Verdadero si `error` representa una cancelación de Task.
    private func isCancelledError(_ error: Error) -> Bool {
        Task.isCancelled || (error as? CancellationError) != nil
    }

    /// Libera el modelo actual de la GPU y deja el cerebro listo para cargar otro.
    /// `modelId` solo se usa para logs; el siguiente `getOrLoadContainer`
    /// resuelve el modelo activo desde `ModelManager`.
    public func switchModel(to modelId: String?) {
        DispatchQueue.main.async {
            self.activeChatTask?.cancel()
            self.activeChatTask = nil
            self.digestionTask?.cancel()
            self.digestionTask = nil
            self.cancelDownload()
            self.activeContainer = nil
            MLX.GPU.clearCache()
            self.modelStatus = .notLoaded
            self.isProcessing = false
            self.currentNoteTitle = ""
            self.downloadProgress = 0.0
        }
        if let modelId {
            Telemetry.shared.log("LocalBrain", eventType: "Status", message: "Cambiando modelo local: \(modelId)")
        }
    }
    
    /// Inicia la precarga/descarga del modelo activo en background
    public func preloadModel() {
        guard isEnabled else { return }
        guard !isProcessing && !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0.0

        let modelId = ModelManager.shared.activeModelID ?? ModelManager.defaultModelID
        Telemetry.shared.log("LocalBrain", eventType: "Status", message: "Iniciando precarga de \(modelId)")

        queue.async {
            self.downloadTask = Task {
                do {
                    _ = try await self.getOrLoadContainer()

                    if Task.isCancelled {
                        Telemetry.shared.log("LocalBrain", eventType: "Status", message: "Precarga cancelada por el usuario.")
                        return
                    }

                    Telemetry.shared.log("LocalBrain", eventType: "Status", message: "¡Modelo \(modelId) listo y caliente en memoria GPU!")

                    DispatchQueue.main.async {
                        self.isDownloading = false
                        self.downloadProgress = 1.0
                        self.downloadTask = nil
                        self.modelStatus = .ready
                    }
                } catch {
                    let cancelled = Task.isCancelled || (error as? CancellationError) != nil
                    if !cancelled {
                        Telemetry.shared.log("LocalBrain", eventType: "Error", message: "Error al precargar el modelo local: \(error.localizedDescription)")
                    }
                    DispatchQueue.main.async {
                        self.isDownloading = false
                        self.downloadTask = nil
                        self.modelStatus = cancelled ? .notLoaded : .error(error.localizedDescription)
                    }
                }
            }
        }
    }
    
    /// Inicia la digestion de notas con inferencia on-device y descarga automatica
    public func startDigestion() {
        guard isEnabled else { return }
        guard !isProcessing else { return }
        isProcessing = true

        let task = Task { [weak self] in
            guard let self = self else { return }

            let pending = getPendingSummaryNotes(limit: 10)

            for note in pending {
                if Task.isCancelled { break }
                await MainActor.run {
                    self.currentNoteTitle = note.title
                }

                let (summary, entities, density) = await self.runLocalInference(content: note.content, title: note.title)
                if Task.isCancelled { break }

                _ = saveNoteSummary(
                    noteId: note.id,
                    syntheticSummary: summary,
                    entities: entities,
                    density: density
                )
            }

            await MainActor.run {
                self.isProcessing = false
                self.currentNoteTitle = ""
                self.updatePendingCount()
            }
        }
        self.digestionTask = task
    }
    
    /// Inicia descarga e inferencia del modelo Gemma de Hugging Face de forma nativa e in-process
    private func runLocalInference(content: String, title: String) async -> (String, [String], Float) {
        Telemetry.shared.log("LocalBrain", eventType: "Status", message: "Iniciando digestion cognitiva local para: \(title)")
        
        var summaryResult = ""
        var entitiesResult: [String] = []
        
        do {
            let (summary, entities) = try await GPUInferenceActor.shared.run { () -> (String, [String]) in
                await MainActor.run {
                    self.isDownloading = true
                    self.downloadProgress = 0.0
                }
                
                let modelContainer = try await self.getOrLoadContainer()
                
                Telemetry.shared.log("LocalBrain", eventType: "Status", message: "Generando sintesis cognitiva...")
                
                await MainActor.run {
                    self.isDownloading = false
                }
                
                let prompt = """
                <bos><start_of_turn>user
                Genera una síntesis densa de una sola oración para la nota "\(title)".
                Extrae hasta 5 entidades clave.
                Devuelve la respuesta estrictamente en este formato JSON:
                {
                  "summary": "tu síntesis aquí",
                  "entities": ["Entidad1", "Entidad2"]
                }
                
                Texto de la nota:
                \(content)<end_of_turn>
                <start_of_turn>model
                """
                
                let userInput = UserInput(prompt: prompt)
                let input = try await modelContainer.prepare(input: userInput)
                let stream = try await modelContainer.generate(input: input, parameters: GenerateParameters(temperature: 0.2))
                
                var generatedText = ""
                for await generation in stream {
                    // Si el usuario usa el chat, la digestión se aborta para
                    // liberar el GPUInferenceActor y dar paso al chat de inmediato.
                    if Task.isCancelled { break }
                    switch generation {
                    case .chunk(let text):
                        generatedText += text
                    default:
                        break
                    }
                }
                
                var sum = ""
                var ent: [String] = []
                if let rawData = generatedText.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] {
                    sum = parsed["summary"] as? String ?? ""
                    ent = parsed["entities"] as? [String] ?? []
                } else {
                    sum = generatedText
                }
                return (sum, ent)
            }
            summaryResult = summary
            entitiesResult = entities
        } catch {
            Telemetry.shared.log("LocalBrain", eventType: "Error", message: "Fallo inferencia local para '\(title)': \(error.localizedDescription)")
            await MainActor.run {
                self.isDownloading = false
            }
        }
        
        MLX.GPU.clearCache()
        
        let wordCount = content.components(separatedBy: .whitespacesAndNewlines).count
        let density = Float(entitiesResult.count) / Float(max(1, wordCount)) * 100.0
        
        return (summaryResult.isEmpty ? "Error al procesar con modelo local nativo." : summaryResult, entitiesResult, density)
    }
    
    /// Realiza inferencia conversacional (Chat) con streaming de tokens
    public func chatStream(prompt: String, context: String = "") async throws -> AsyncStream<String> {
        guard isEnabled else {
            throw NSError(domain: "LocalBrain", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "El cerebro local está desactivado. Actívalo con el botón de encendido en el panel de chat."
            ])
        }
        return AsyncStream { continuation in
            let task = Task {
                var accumulatedText = ""
                do {
                    // El chat tiene PRIORIDAD sobre la digestión cognitiva.
                    // La digestión ocupa el GPUInferenceActor (actor serializado)
                    // en un bucle de notas; sin esto, el chat esperaba detrás
                    // de N generaciones y "no respondía". Cancelamos la digestión
                    // antes de entrar al actor para liberar el GPU de inmediato.
                    self.pauseDigestionForChat()

                    try await GPUInferenceActor.shared.run {
                        let container = try await self.getOrLoadContainer()

                        var finalContext = context
                        if finalContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            // Cargar documentación de autoconsciencia del sistema de forma fija
                            let sysNotes = queryNotes(searchTerm: "instrucciones_chatbot", pathFilter: nil, ignorePatterns: [])
                            let finalSysNotes = sysNotes.isEmpty ? queryNotes(searchTerm: "cerebro-local", pathFilter: nil, ignorePatterns: []) : sysNotes
                            var systemContext = ""
                            if !finalSysNotes.isEmpty {
                                systemContext = finalSysNotes.prefix(2).map { note in
                                    "Documento Sistema (Tus capacidades nativas): \(note.title)\nContenido:\n\(note.content)"
                                }.joined(separator: "\n\n")
                            }
                            
                            // RAG conversacional del usuario
                            let notes = queryNotes(searchTerm: prompt, pathFilter: nil, ignorePatterns: [])
                            var userContext = ""
                            if !notes.isEmpty {
                                userContext = notes.prefix(4).map { note in
                                    "Documento: \(note.title)\nPath: \(note.path)\nContenido:\n\(note.content)"
                                }.joined(separator: "\n\n---\n\n")
                            } else {
                                // Fallback: traer las notas mas recientes del vault si no hay match de termino
                                let allNotes = queryNotes(searchTerm: nil, pathFilter: nil, ignorePatterns: [])
                                if !allNotes.isEmpty {
                                    userContext = allNotes.prefix(2).map { note in
                                        "Documento Reciente: \(note.title)\nPath: \(note.path)\nContenido:\n\(note.content)"
                                    }.joined(separator: "\n\n---\n\n")
                                }
                            }
                            
                            finalContext = [systemContext, userContext]
                                .filter { !$0.isEmpty }
                                .joined(separator: "\n\n---\n\n")
                            
                            Telemetry.shared.log("LocalBrain", eventType: "RAG", message: "Puente RAG con autoconsciencia inyectada.")
                        }
                        
                        let workspacesList = WorkspaceManager.shared.locations.map { "- \($0.name): \($0.path)" }.joined(separator: "\n")
                        let systemPrompt = """
                        Eres el asistente inteligente del vault personal del usuario.
                        Tus respuestas deben ser concisas y basadas exclusivamente en el contexto provisto.
                        Si la informacion no se encuentra en el contexto, indicalo de forma honesta.
                        
                        Si el usuario te pide abrir una nota, crear una nota o cambiar el modo de la interfaz, confirma la accion por chat y añade EXACTAMENTE al final de tu respuesta una unica linea con el comando estructurado correspondiente de la siguiente lista:
                        - [CMD: open_note, path: "ruta_absoluta"]
                        - [CMD: create_note, title: "nombre_archivo", content: "contenido_crudo_markdown"]
                        - [CMD: set_mode, mode: "edit" o "preview"]
                        
                        Workspaces configurados en la aplicacion:
                        \(workspacesList)
                        
                        Contexto del vault:
                        \(finalContext)
                        """
                        
                        let fullPrompt = """
                        <bos><start_of_turn>user
                        \(systemPrompt)
                        
                        Pregunta: \(prompt)<end_of_turn>
                        <start_of_turn>model
                        """
                        
                        let userInput = UserInput(prompt: fullPrompt)
                        let input = try await container.prepare(input: userInput)
                        let stream = try await container.generate(input: input, parameters: GenerateParameters(temperature: 0.3))
                        
                        for await generation in stream {
                            if Task.isCancelled { break }
                            switch generation {
                            case .chunk(let text):
                                let cleanText = self.filterSpecialTokens(text)
                                accumulatedText += cleanText
                                continuation.yield(cleanText)
                            default:
                                break
                            }
                        }
                    }
                } catch {
                    print("❌ Error en streaming del chat: \(error)")
                }
                executeCommandIfPresent(accumulatedText)
                MLX.GPU.clearCache()
                continuation.finish()
                // El chat terminó: reanudar la digestión cognitiva pausada,
                // si aún quedan notas pendientes y el cerebro sigue activado.
                self.resumeDigestionAfterChat()
            }
            self.activeChatTask = task
            continuation.onTermination = { _ in
                task.cancel()
                self.activeChatTask = nil
            }
        }
    }
    
    private func executeCommandIfPresent(_ text: String) {
        // 1. Comando abrir nota
        if let openRange = text.range(of: "\\[CMD: open_note, path: \"([^\"]+)\"\\]", options: .regularExpression) {
            let cmdStr = String(text[openRange])
            if let pathRange = cmdStr.range(of: "(?<=path: \")[^\"]+", options: .regularExpression) {
                let path = String(cmdStr[pathRange])
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("UiOpenNote"), object: nil, userInfo: ["path": path])
                }
            }
        }
        
        // 2. Comando crear nota
        if let createRange = text.range(of: "\\[CMD: create_note, title: \"([^\"]+)\", content: \"([^\"]+)\"\\]", options: .regularExpression) {
            let cmdStr = String(text[createRange])
            if let titleRange = cmdStr.range(of: "(?<=title: \")[^\"]+", options: .regularExpression),
               let contentRange = cmdStr.range(of: "(?<=content: \")[^\"]+", options: .regularExpression) {
                let title = String(cmdStr[titleRange])
                let content = String(cmdStr[contentRange]).replacingOccurrences(of: "\\n", with: "\n")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("UiCreateNote"), object: nil, userInfo: ["title": title, "content": content])
                }
            }
        }
        
        // 3. Comando cambiar modo
        if let modeRange = text.range(of: "\\[CMD: set_mode, mode: \"([^\"]+)\"\\]", options: .regularExpression) {
            let cmdStr = String(text[modeRange])
            if let mRange = cmdStr.range(of: "(?<=mode: \")[^\"]+", options: .regularExpression) {
                let mode = String(cmdStr[mRange])
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("UiSetEditorMode"), object: nil, userInfo: ["mode": mode])
                }
            }
        }
    }
    
    private func filterSpecialTokens(_ text: String) -> String {
        var clean = text
        let specialTokens = ["<image|>", "<bos>", "<eos>", "<start_of_turn>", "<end_of_turn>", "<pad>", "<unk>"]
        for token in specialTokens {
            clean = clean.replacingOccurrences(of: token, with: "")
        }
        return clean
    }
}
