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
    
    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "cl.nicelio.vault.brain", qos: .background)
    private var downloadTask: Task<Void, Never>? = nil
    
    // Contenedor caliente persistente en GPU
    private var activeContainer: ModelContainer? = nil
    
    /// Cancela la descarga del modelo local en ejecucion
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        DispatchQueue.main.async {
            self.isDownloading = false
            self.downloadProgress = 0.0
        }
    }
    
    private init() {
        // Limitar cache de reuso de tensores de Metal a 64MB para evitar presion de memoria
        MLX.GPU.set(cacheLimit: 64 * 1024 * 1024)
        
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
    
    /// Inicializa u obtiene el contenedor caliente de Gemma de forma segura
    public func getOrLoadContainer() async throws -> ModelContainer {
        if let container = activeContainer {
            return container
        }
        
        let modelId = "mlx-community/gemma-4-12B-it-4bit"
        
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tokenURL = home.appendingPathComponent(".cache/huggingface/token")
        
        if let tokenData = try? Data(contentsOf: tokenURL),
           let token = String(data: tokenData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.hasPrefix("hf_oauth_") {
            setenv("HF_TOKEN", token, 1)
            Telemetry.shared.log("LocalBrain", eventType: "Auth", message: "Token de Hugging Face inyectado. Hub usara autenticacion.")
        } else {
            unsetenv("HF_TOKEN")
            Telemetry.shared.log("LocalBrain", eventType: "Auth", message: "Token omitido o invalido. Usando sesion anonima publica.")
        }
        
        // Intentar carga rápida offline nativa
        let config = ModelConfiguration(id: modelId)
        do {
            await MainActor.run {
                self.modelStatus = .loading
            }
            let container = try await #huggingFaceLoadModelContainer(configuration: config)
            self.activeContainer = container
            await MainActor.run {
                self.downloadProgress = 1.0
                self.modelStatus = .ready
            }
            return container
        } catch {
            Telemetry.shared.log("LocalBrain", eventType: "Status", message: "Modelo no disponible localmente. Iniciando descarga: \(error.localizedDescription)")
            
            // Descarga manual de red usando Hub de Hugging Face v3
            let repo = Hub.Repo(id: modelId)
            do {
                _ = try await Hub.snapshot(from: repo) { progress in
                    DispatchQueue.main.async {
                        self.downloadProgress = progress.fractionCompleted
                        self.modelStatus = .downloading(progress: progress.fractionCompleted)
                    }
                }
                
                await MainActor.run {
                    self.modelStatus = .loading
                }
                
                // Cargar modelo tras la descarga exitosa
                let container = try await #huggingFaceLoadModelContainer(configuration: config)
                self.activeContainer = container
                await MainActor.run {
                    self.modelStatus = .ready
                }
                return container
            } catch let downloadErr {
                await MainActor.run {
                    self.modelStatus = .error(downloadErr.localizedDescription)
                }
                throw downloadErr
            }
        }
    }
    
    /// Inicia la precarga/descarga del modelo Gemma en background
    public func preloadModel() {
        guard !isProcessing && !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0.0
        
        Telemetry.shared.log("LocalBrain", eventType: "Status", message: "Iniciando precarga de Gemma 4 (mlx-community/gemma-4-12B-it-4bit)")
        
        queue.async {
            self.downloadTask = Task {
                do {
                    _ = try await self.getOrLoadContainer()
                    
                    if Task.isCancelled {
                        Telemetry.shared.log("LocalBrain", eventType: "Status", message: "Descarga cancelada por el usuario.")
                        return
                    }
                    
                    Telemetry.shared.log("LocalBrain", eventType: "Status", message: "¡Modelo Gemma 4 listo en cache y caliente en memoria GPU!")
                    
                    DispatchQueue.main.async {
                        self.isDownloading = false
                        self.downloadProgress = 1.0
                        self.downloadTask = nil
                        self.modelStatus = .ready
                    }
                } catch {
                    Telemetry.shared.log("LocalBrain", eventType: "Error", message: "Error al precargar el modelo local: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.isDownloading = false
                        self.downloadTask = nil
                        self.modelStatus = .error(error.localizedDescription)
                    }
                }
            }
        }
    }
    
    /// Inicia la digestion de notas con inferencia on-device y descarga automatica
    public func startDigestion() {
        guard !isProcessing else { return }
        isProcessing = true
        
        Task { [weak self] in
            guard let self = self else { return }
            
            let pending = getPendingSummaryNotes(limit: 10)
            
            for note in pending {
                await MainActor.run {
                    self.currentNoteTitle = note.title
                }
                
                let (summary, entities, density) = await self.runLocalInference(content: note.content, title: note.title)
                
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
        return AsyncStream { continuation in
            let task = Task {
                var accumulatedText = ""
                do {
                    try await GPUInferenceActor.shared.run {
                        let container = try await self.getOrLoadContainer()
                        
                        var finalContext = context
                        if finalContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            // Cargar documentación de autoconsciencia del sistema de forma fija
                            let sysNotes = queryNotes(searchTerm: "cerebro-local", pathFilter: nil, ignorePatterns: [])
                            var systemContext = ""
                            if !sysNotes.isEmpty {
                                systemContext = sysNotes.prefix(2).map { note in
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
            }
            continuation.onTermination = { _ in
                task.cancel()
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
