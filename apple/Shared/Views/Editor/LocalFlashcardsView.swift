import SwiftUI
import MLX
import MLXLMCommon
import MLXLLM

/// Vista premium para la generación de Flashcards / FocoMemoria educativos mediante Gemma 4 local en GPU.
struct LocalFlashcardsView: View {
    @Binding var text: String
    @Binding var isPresented: Bool
    @StateObject private var brain = LocalBrain.shared
    
    @State private var isProcessing: Bool = false
    @State private var progressMessage: String = ""
    
    var body: some View {
        VStack(spacing: 16) {
            // Header Educativo
            HStack {
                Image(systemName: "square.and.pencil.revertion")
                    .font(.title2)
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Generador Flashcards")
                        .font(.headline)
                    Text("Crea preguntas y respuestas de estudio localmente")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
            
            Divider()
            
            Text("Esta herramienta analizará el contenido actual de tu nota y generará automáticamente un set de 5 preguntas de repaso con sus respectivas respuestas de estudio (Flashcards) utilizando el chip Apple Silicon y Metal de tu Mac.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
            
            if isProcessing {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progressMessage)
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                .padding()
            } else {
                Button(action: runGeneration) {
                    HStack {
                        Image(systemName: "bolt.fill")
                        Text("Generar 5 Flashcards")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .frame(width: 380)
    }
    
    private func runGeneration() {
        isProcessing = true
        progressMessage = "Cargando modelo local en GPU Metal..."
        
        let originalText = text
        
        Task {
            do {
                let container = try await brain.getOrLoadContainer()
                
                DispatchQueue.main.async {
                    progressMessage = "Analizando material y redactando preguntas..."
                }
                
                let prompt = """
                <bos><start_of_turn>user
                Analiza el siguiente texto de estudio y extrae exactamente 5 preguntas clave con sus respectivas respuestas concisas para estudiar la materia.
                Usa estrictamente este formato Markdown:
                ### ❓ Preguntas de Repaso (Flashcards)
                
                1. **Pregunta:** ¿...?
                   * **Respuesta:** ...
                   
                2. **Pregunta:** ¿...?
                   * **Respuesta:** ...
                
                Texto de estudio:
                \(originalText)<end_of_turn>
                <start_of_turn>model
                """
                
                let userInput = UserInput(prompt: prompt)
                let input = try await container.prepare(input: userInput)
                let stream = try await container.generate(input: input, parameters: GenerateParameters(temperature: 0.2))
                
                var generatedText = ""
                for await generation in stream {
                    if Task.isCancelled { break }
                    switch generation {
                    case .chunk(let chunk):
                        generatedText += chunk
                    default:
                        break
                    }
                }
                
                DispatchQueue.main.async {
                    if !generatedText.isEmpty {
                        text = originalText + "\n\n---\n" + generatedText
                    }
                    isPresented = false
                }
            } catch {
                DispatchQueue.main.async {
                    progressMessage = "❌ Error: \(error.localizedDescription)"
                    isProcessing = false
                }
            }
        }
    }
}
