import Foundation

// MARK: - Tipos de resultado del streaming

struct ChatToolCall {
    let id: String
    let name: String
    let args: String
}

struct ChatStreamResult {
    let text: String?
    let toolCalls: [ChatToolCall]?
    let error: String?
}

/// Helpers de API externa (OpenAI-compatible / MCP) agnósticos de agente.
///
/// Viven fuera de las vistas para que las reutilicen tanto las secciones
/// per-agente de `AgentChatSection` como el futuro chat de grupo (que
/// orquestará varios agentes sobre un thread compartido). Ningún método aquí
/// muta estado de UI: el texto en streaming se entrega vía `onDelta`.
enum ChatAgentSupport {

    /// Máximo de caracteres de nota que se envían al modelo (evita exceder límites de tokens).
    static let maxNoteContentForAI = 12_000

    /// Código estable para DB (no cambia aunque el usuario renombre el agente).
    static func agentCode(for agent: ExternalAgentConfig) -> String {
        switch agent.provider {
        case .deepseek: return "DS"
        case .anthropic: return "CL"
        case .openai: return "OP"
        }
    }

    // MARK: - Streaming

    /// Llama al chat completions del proveedor con SSE y acumula texto + tool_calls.
    /// Cada chunk de contenido invoca `onDelta(fullText)` (MainActor) para que el
    /// caller renderice el mensaje en streaming sin que este helper conozca la UI.
    static func streamAPI(
        agent: ExternalAgentConfig,
        key: String,
        apiMessages: [[String: Any]],
        tools: [[String: Any]],
        onDelta: (@MainActor (String) -> Void)? = nil
    ) async -> ChatStreamResult {
        var req = URLRequest(url: URL(string: "\(agent.provider.baseURL)/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = ["model": agent.model, "messages": apiMessages, "stream": true]
        // Si no declaramos herramientas (turno casual), los tool_calls que emita el modelo
        // son alucinaciones (DeepSeek es "agentic" y a veces los inventa igual). Se ignoran.
        let allowTools = !tools.isEmpty
        if allowTools {
            body["tools"] = tools
            body["tool_choice"] = "auto" // DeepSeek: evitar que abandone tool calling
        }

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            return ChatStreamResult(text: nil, toolCalls: nil, error: "Error serializando request")
        }
        req.httpBody = httpBody

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return ChatStreamResult(text: nil, toolCalls: nil, error: "HTTP \( (response as? HTTPURLResponse)?.statusCode ?? 0)")
            }

            var streamedText = ""
            var tcAccum: [Int: (id: String, name: String, args: String)] = [:]
            var finishReason: String? = nil

            for try await line in bytes.lines {
                guard line.hasPrefix("data: "), line != "data: [DONE]" else { continue }
                let jsonStr = String(line.dropFirst(6))
                guard let d = jsonStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let choices = obj["choices"] as? [[String: Any]],
                      let first = choices.first else { continue }

                let delta = first["delta"] as? [String: Any] ?? [:]
                finishReason = first["finish_reason"] as? String

                if let content = delta["content"] as? String, !content.isEmpty {
                    streamedText += content
                    if let onDelta {
                        await onDelta(streamedText)
                    }
                }

                if allowTools, let tcDeltas = delta["tool_calls"] as? [[String: Any]] {
                    for tc in tcDeltas {
                        let idx = tc["index"] as? Int ?? 0
                        var cur = tcAccum[idx] ?? (id: "", name: "", args: "")
                        if let id = tc["id"] as? String { cur.id = id }
                        if let fn = tc["function"] as? [String: Any] {
                            if let n = fn["name"] as? String { cur.name = n }
                            if let a = fn["arguments"] as? String { cur.args += a }
                        }
                        tcAccum[idx] = cur
                    }
                }
            }

            let text = streamedText.isEmpty ? nil : streamedText
            let toolCalls: [ChatToolCall]? = if finishReason == "tool_calls", !tcAccum.isEmpty {
                tcAccum.values.sorted(by: { $0.id < $1.id }).map { ChatToolCall(id: $0.id, name: $0.name, args: $0.args) }
            } else { nil }

            return ChatStreamResult(text: text, toolCalls: toolCalls, error: nil)
        } catch {
            let msg = error.localizedDescription
            if msg.contains("network connection was lost") || msg.contains("timeout") || msg.contains("Network") {
                return ChatStreamResult(text: nil, toolCalls: nil, error: "Conexión perdida con \(agent.provider.rawValue). Reintentá en unos segundos.")
            }
            return ChatStreamResult(text: nil, toolCalls: nil, error: "Red: \(msg)")
        }
    }

    // MARK: - Conversación

    /// Construye el array de conversación para la API desde mensajes persistidos en DB.
    static func buildApiConversation(threadId: String, sys: String, newUserMsg: String) -> [[String: Any]] {
        var conv: [[String: Any]] = [["role": "system", "content": sys]]
        let persisted = ChatThreadManager.shared.loadMessages(threadId: threadId, limit: 20)

        // Agregar historial previo (sin el último mensaje que es el nuevo user msg)
        let previousMsgs = Array(persisted.dropLast())

        // /reset marca un límite de contexto: el modelo solo ve mensajes POSTERIORES
        // a la última marca "── … ──" (tipo anchor). El historial queda en la DB y en
        // el render, pero el AI arranca "limpio" en el reset — como un nuevo chat.
        let startIdx = previousMsgs.lastIndex { m in
            m.content.hasPrefix("── ") && m.content.hasSuffix(" ──")
        }.map { $0 + 1 } ?? 0

        for msg in previousMsgs[startIdx...] {
            switch msg.role {
            case "user":
                conv.append(["role": "user", "content": msg.content])
            case "assistant":
                conv.append(["role": "assistant", "content": msg.content])
            default:
                break
            }
        }

        // Agregar el nuevo mensaje del usuario (no duplicado)
        conv.append(["role": "user", "content": newUserMsg])
        return conv
    }

    /// Sliding window: mantiene system + user messages + últimos tool exchanges.
    static func pruneConversation(_ conv: [[String: Any]]) -> [[String: Any]] {
        let total = conv.reduce(0) { $0 + (($1["content"] as? String)?.count ?? 0) }
        guard total > 200_000, conv.count >= 4 else { return conv }

        // Preservar system + user messages + últimos 4 mensajes
        let systemMsg = conv.first(where: { ($0["role"] as? String) == "system" })
        let userMsgs = conv.filter { ($0["role"] as? String) == "user" }
        let recent = conv.suffix(4)

        var result: [[String: Any]] = []
        if let sys = systemMsg { result.append(sys) }
        result.append(contentsOf: userMsgs.prefix(3)) // últimos 3 mensajes del usuario
        result.append(contentsOf: recent)
        return result
    }

    // MARK: - Tools MCP

    static func convertMcpToolsToOpenAI(_ mcpToolsJson: String) -> [[String: Any]] {
        guard let data = mcpToolsJson.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else { return [] }

        return tools.compactMap { tool -> [String: Any]? in
            guard let name = tool["name"] as? String,
                  var desc = tool["description"] as? String else { return nil }
            if desc.count > 200 { desc = String(desc.prefix(200)) }
            let schema = tool["inputSchema"] as? [String: Any]
            var fn: [String: Any] = ["name": name, "description": desc]
            if let s = schema {
                fn["parameters"] = ["type": "object", "properties": s["properties"] ?? [:], "required": s["required"] ?? []]
            }
            return ["type": "function", "function": fn]
        }
    }

    static func buildMcpRequest(tokenId: String, toolName: String, arguments: String) -> String {
        let parsedArgs: Any
        if let data = arguments.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            parsedArgs = obj
        } else {
            parsedArgs = arguments
        }
        let inner: [String: Any] = [
            "jsonrpc": "2.0", "method": "tools/call",
            "params": ["name": toolName, "arguments": parsedArgs],
            "id": 1, "mcp_client_token": tokenId
        ]
        if let data = try? JSONSerialization.data(withJSONObject: inner),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    // MARK: - Prompts

    static func buildSystemPrompt(agent: ExternalAgentConfig, context: String) -> String {
        var sys = "Eres \(agent.name), un asistente IA con acceso al Vault System.\n"

        // Inyectar directrices-core.md (framework operativo)
        let corePath = NSString(string: "~/.vault_system/system_workspace/directrices-core.md").expandingTildeInPath
        if let core = try? String(contentsOfFile: corePath, encoding: .utf8) {
            sys += "\n## Directrices Operativas\n\(core.prefix(1500))\n"
        }
        // Inyectar conciencia.md (estado global)
        let concienciaPath = NSString(string: "~/.vault_system/system_workspace/00-Sistema/conciencia.md").expandingTildeInPath
        if let conciencia = try? String(contentsOfFile: concienciaPath, encoding: .utf8) {
            sys += "\n## Estado Global del Sistema\n\(conciencia.prefix(2000))\n"
        }
        // Inyectar current_session.md (scratchpad: contexto de la sesión anterior)
        let sessionPath = NSString(string: "~/.vault_system/system_workspace/current_session.md").expandingTildeInPath
        if let session = try? String(contentsOfFile: sessionPath, encoding: .utf8) {
            let trimmed = session.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != "# Sesión Actual" {
                sys += "\n## Sesión Anterior (scratchpad)\n\(session.prefix(1200))\n"
            }
        }

        sys += "Puedes usar herramientas MCP para leer, buscar, escribir y explorar el vault.\n"
        if agent.writeContent || agent.writeMetadata || agent.writeSystem {
            sys += "También puedes crear/modificar notas y metadatos.\n"
        }

        // Cuándo SÍ y cuándo NO usar herramientas: un saludo no amerita auditar el vault.
        sys += "\n## Cuándo usar herramientas\n"
        sys += "- Usa herramientas SOLO si el usuario pide explícitamente explorar, buscar, leer, escribir o hacer algo en el vault.\n"
        sys += "- Para saludos y conversación casual ('hola', 'qué tal'), respondé breve y naturalmente SIN herramientas.\n"
        sys += "- No explores el vault por defecto ni al iniciar una conversación.\n"
        sys += "- Máximo 5 rondas de herramientas en un turno. Sé eficiente.\n"

        sys += "\n⚠️ REGLA CRÍTICA: Después de usar herramientas, NUNCA te presentes ni saludes de nuevo.\n"
        sys += "Resumí brevemente lo que encontraste y proponé siguientes pasos. La conversación continúa.\n"
        sys += "No digas frases como 'listo para ayudarte', 'soy tu asistente', 'herramientas cargadas', etc.\n"

        // Gestión de contexto: scratchpad obligatorio
        sys += "\n## Reglas de Trabajo\n"
        sys += "- Al final de CADA respuesta, actualizá current_session.md con [ACUERDO]/[HITO]/[DESCARTADO].\n"
        sys += "- Solo cargá contexto previo (current_session.md o 01-Diario/) si el usuario lo pide o la tarea lo requiere. NO de forma automática.\n"
        sys += "- NUNCA preguntes '¿en qué te ayudo?' ni frases de bienvenida. La conversación ya empezó.\n"

        if !context.isEmpty { sys += "\nNota activa en el editor (truncada):\n\(context.prefix(1500))\n" }
        return sys
    }

    /// System prompt para redacción de notas: pedir SOLO el texto resultante.
    static func noteAISystemPrompt(agentName: String, usesTools: Bool, createNew: Bool = false) -> String {
        var s = createNew
            ? "Eres un redactor inteligente del vault (\(agentName)). Crearás una nota nueva aplicando la instrucción del usuario.\n"
            : "Eres un redactor inteligente del vault (\(agentName)). Aplicarás la instrucción del usuario sobre la nota activa.\n"
        s += "Devuelve ÚNICAMENTE el texto completo resultante de aplicar la instrucción, sin comentarios, prefacios ni resúmenes.\n"
        if !createNew {
            s += "La nota completa está al final del mensaje del usuario; no la busques con herramientas.\n"
        }
        s += usesTools
            ? "Puedes usar herramientas MCP solo si es estrictamente necesario; lo esperado es devolver el texto editado.\n"
            : "NO uses herramientas MCP. Responde solo con el texto.\n"
        return s
    }

    /// Prompt de usuario para redacción de notas, con el título de la nota y el contenido truncado para límites de tokens.
    static func noteAIUserPrompt(instruction: String, originalText: String, title: String, createNew: Bool) -> String {
        if createNew {
            return "Instrucción: \(instruction)\n\nCrea una nota nueva con el contenido solicitado. Devuelve únicamente el texto completo de la nota nueva."
        }
        var text = originalText
        var truncated = false
        if text.count > maxNoteContentForAI {
            text = String(text.prefix(maxNoteContentForAI))
            truncated = true
        }
        let note = truncated ? "\(text)\n… [nota truncada a \(maxNoteContentForAI) caracteres]" : text
        return "Nota activa: \(title)\n\nInstrucción: \(instruction)\n\nTexto original de la nota:\n---\n\(note)\n---\n\nDevuelve únicamente el texto completo resultante."
    }

    /// Desempaqueta el bloque fenced ``` más grande si el modelo devolvió el texto envuelto en un code fence.
    static func parseNoteAIResult(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fences = text.components(separatedBy: "```")
        if fences.count >= 3 {
            // El bloque de mayor contenido suele ser el texto editable
            var best = fences[1]
            for i in 2..<(fences.count - 1) {
                if fences[i].count > best.count { best = fences[i] }
            }
            text = best.trimmingCharacters(in: .whitespacesAndNewlines)
            // Quitar el lenguaje declarado en la primera línea del fence (p.ej. "md", "markdown")
            let lines = text.components(separatedBy: .newlines)
            if let first = lines.first, !first.contains(" ") && first.count <= 12 && !first.contains("#") {
                text = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    /// True si el mensaje es un saludo o frase casual que NO amerita herramientas MCP.
    /// Mensajes con verbos de acción (buscar, leer, crear, resumir…) se consideran trabajo → herramientas permitidas.
    static func isCasualMessage(_ prompt: String) -> Bool {
        let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let lower = t.lowercased()
        // Si el usuario pide hacer algo en el vault, permitir herramientas.
        let actionHints = ["busca", "buscar", "lee", "leer", "crea", "crear", "escrib", "modifica", "resume",
                           "resum", "analiza", "list", "muestra", "explora", "examina", "revisa", "investiga",
                           "organiza", "archiva", "mueve", "renombra", "ejecuta", "plan", "nota ", "busqued",
                           "sintetiza", "genera", "traduce"]
        if actionHints.contains(where: { lower.contains($0) }) { return false }
        // Corto y sin verbo de acción → saludo/casual.
        return lower.count <= 45
    }
}
