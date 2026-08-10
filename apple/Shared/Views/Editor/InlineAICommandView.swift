import SwiftUI
import MLX
import MLXLMCommon
import MLXLLM

/// Popover premium para comandos de redacción inline (notion-style) impulsado por Gemma 4 local en GPU.
struct InlineAICommandView: View {
    @Binding var text: String
    @Binding var isPresented: Bool
    @StateObject private var brain = LocalBrain.shared
    
    @State private var commandInput: String = ""
    @State private var isProcessing: Bool = false
    @State private var statusMessage: String = ""
    
    // Acciones rápidas predefinidas
    let quickActions = [
        ("Resumir Nota", "Genera un resumen analítico denso de tres puntos clave."),
        ("Crear Glosario", "Extrae los términos técnicos y genera definiciones concisas."),
        ("Mejorar Redacción", "Corrige la gramática y el estilo del texto de forma profesional.")
    ]
    
    var body: some View {
        VStack(spacing: 12) {
            // Cabecera
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.purple)
                Text("Redactor Inteligente Local")
                    .font(.headline)
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
            
            // Entrada de texto
            TextField("Pídele a Gemma local que modifique o analice el documento...", text: $commandInput)
                .textFieldStyle(.roundedBorder)
                .disabled(isProcessing)
                .onSubmit(runInlineCommand)
            
            // Acciones Rápidas
            VStack(alignment: .leading, spacing: 6) {
                Text("Acciones Rápidas")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    ForEach(quickActions, id: \.0) { action in
                        Button(action: {
                            commandInput = action.1
                            runInlineCommand()
                        }) {
                            Text(action.0)
                                .font(.system(size: 11))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.12))
                                .foregroundColor(.accentColor)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .disabled(isProcessing)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            if isProcessing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(statusMessage.isEmpty ? "Gemma procesando en GPU Metal..." : statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .frame(width: 460)
    }
    
    private func runInlineCommand() {
        let instruction = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        
        isProcessing = true
        statusMessage = "Cargando pesos del modelo..."
        
        let originalText = text
        
        Task {
            do {
                let container = try await brain.getOrLoadContainer()
                
                DispatchQueue.main.async {
                    statusMessage = "Generando contenido..."
                }
                
                let prompt = """
                <bos><start_of_turn>user
                Eres un redactor inteligente. Modifica o analiza el siguiente texto según la instrucción.
                Devuelve únicamente el texto modificado o la respuesta solicitada, sin introducciones ni comentarios adicionales.
                
                Instrucción:
                \(instruction)
                
                Texto original:
                \(originalText)<end_of_turn>
                <start_of_turn>model
                """
                
                let userInput = UserInput(prompt: prompt)
                let input = try await container.prepare(input: userInput)
                let stream = try await container.generate(input: input, parameters: GenerateParameters(temperature: 0.3))
                
                var generatedText = ""
                for await generation in stream {
                    if Task.isCancelled { break }
                    switch generation {
                    case .chunk(let chunk):
                        generatedText += chunk
                        // Opcional: Podríamos ir anexándolo en tiempo real, pero para estabilidad se concatena al finalizar.
                    default:
                        break
                    }
                }
                
                DispatchQueue.main.async {
                    // Concatenar el resultado de la IA al final de la nota con una separación elegante
                    if !generatedText.isEmpty {
                        text = originalText + "\n\n---\n### ✨ Inferencia Local: \(instruction)\n" + generatedText
                    }
                    isPresented = false
                }
            } catch {
                DispatchQueue.main.async {
                    statusMessage = "❌ Error: \(error.localizedDescription)"
                    isProcessing = false
                }
            }
        }
    }
}
