import SwiftUI

/// Acciones confirmables del Model Manager, unificadas en UN solo `.alert(item:)`.
/// Varios `.alert` encadenados en la misma vista son frágiles en macOS (solo el
/// último suele presentarse) — por eso se centralizan aquí.
private enum ModelAction: Identifiable {
    case switchTo(LocalModel)
    case release(LocalModel)
    case removeFromList(LocalModel)

    var id: String {
        switch self {
        case .switchTo(let m): return "switch-\(m.id)"
        case .release(let m): return "release-\(m.id)"
        case .removeFromList(let m): return "remove-\(m.id)"
        }
    }
}

/// Panel reutilizable de gestión de modelos locales (Cerebro Local MLX).
/// Se usa en la pestaña "Cerebro Local" de MCPAccessView y como sheet desde el chat.
struct ModelManagerView: View {
    @ObservedObject var manager = ModelManager.shared
    @ObservedObject var brain = LocalBrain.shared

    @State private var pendingAction: ModelAction? = nil
    @State private var customRepoID: String = ""
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if manager.pendingLegacyMigration {
                migrationBanner
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(manager.models) { model in
                        ModelRowView(
                            model: model,
                            manager: manager,
                            brain: brain,
                            onUse: { pendingAction = .switchTo(model) },
                            onRelease: { pendingAction = .release(model) },
                            onRemoveFromList: { pendingAction = .removeFromList(model) },
                            onDownload: { runDownload(model) },
                            onCancelDownload: { brain.cancelDownload() }
                        )
                    }
                }
            }

            customAddSection
        }
        .padding(16)
        .alert(item: $pendingAction) { action in
            switch action {
            case .switchTo(let model):
                return Alert(
                    title: Text("Cambiar modelo"),
                    message: Text(messageForSwitch(model)),
                    primaryButton: .default(Text("Cambiar")) {
                        Task {
                            do { try await manager.setActiveModel(id: model.id) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    },
                    secondaryButton: .cancel(Text("Cancelar"))
                )
            case .release(let model):
                return Alert(
                    title: Text("Liberar memoria"),
                    message: Text(messageForRelease(model)),
                    primaryButton: .destructive(Text("Liberar")) {
                        Task {
                            do { try await manager.releaseModel(id: model.id) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    },
                    secondaryButton: .cancel(Text("Cancelar"))
                )
            case .removeFromList(let model):
                return Alert(
                    title: Text("Quitar de la lista"),
                    message: Text(messageForRemove(model)),
                    primaryButton: .destructive(Text("Quitar")) {
                        Task {
                            do { try await manager.removeCustomModel(id: model.id) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    },
                    secondaryButton: .cancel(Text("Cancelar"))
                )
            }
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Entendido", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Modelos locales (MLX)")
                .font(.headline)
            Text("Inferencia on-device sobre Metal/GPU. Cambiar, borrar o agregar un modelo pide confirmación.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var migrationBanner: some View {
        Label("No se pudo migrar automáticamente un modelo desde la versión anterior. Revisa la consola.", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundColor(.orange)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(6)
    }

    private var customAddSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agregar modelo custom")
                .font(.subheadline).bold()
            HStack(spacing: 8) {
                TextField("namespace/nombre (ej. mlx-community/...)", text: $customRepoID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addCustom)
                Button("Agregar", action: addCustom)
                    .disabled(customRepoID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Repo de Hugging Face en formato MLX nativo. No soporta GGUF (llama.cpp).")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
    }

    // MARK: - Acciones

    private func runDownload(_ model: LocalModel) {
        Task {
            do {
                try await manager.downloadModel(id: model.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func addCustom() {
        let ok = manager.addCustomModel(repoID: customRepoID)
        if ok {
            customRepoID = ""
        } else {
            errorMessage = "Repo inválido (formato namespace/nombre) o ya existe en el catálogo."
        }
    }

    // MARK: - Mensajes de confirmación

    private func messageForSwitch(_ model: LocalModel) -> String {
        var msg: String
        if manager.diskSizes[model.id] != nil {
            msg = "El cerebro local pasará a usar '\(model.name)'. Se libera la GPU y se recarga el nuevo modelo."
        } else {
            msg = "'\(model.name)' aún no está descargado. Se descargará primero (~\(formatEstimate(model)))."
        }
        if brain.isProcessing || brain.isDownloading {
            msg += "\n\n⚠️ La generación o descarga en curso se cancelará."
        }
        return msg
    }

    private func messageForRelease(_ model: LocalModel) -> String {
        let size = manager.diskSizes[model.id].map(Self.sizeText) ?? formatEstimate(model)
        var msg = "Se liberarán \(size) del disco y de la memoria. El modelo queda en la lista (verás 'Descargar' para volver a bajarlo)."
        if manager.activeModelID == model.id {
            msg += "\n\n⚠️ Es el modelo activo: el cerebro local quedará sin modelo hasta que elijas otro."
        }
        return msg
    }

    private func messageForRemove(_ model: LocalModel) -> String {
        "Se quitará '\(model.name)' de la lista de modelos y se liberarán sus archivos. No se puede deshacer (habría que re-agregarlo a mano)."
    }

    private func formatEstimate(_ model: LocalModel) -> String {
        model.estimatedSizeGB > 0
            ? String(format: "~%.1f GB", model.estimatedSizeGB)
            : "tamaño desconocido"
    }

    static func sizeText(_ bytes: Int64) -> String {
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }
}

/// Fila de un modelo del catálogo con estado, tamaño y acciones.
private struct ModelRowView: View {
    let model: LocalModel
    let manager: ModelManager
    let brain: LocalBrain
    let onUse: () -> Void
    let onRelease: () -> Void
    let onRemoveFromList: () -> Void
    let onDownload: () -> Void
    let onCancelDownload: () -> Void

    private var isActive: Bool { manager.activeModelID == model.id }
    private var isDownloadingThis: Bool { manager.downloadingModelID == model.id }
    private var isDownloaded: Bool { manager.diskSizes[model.id] != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isActive ? "cpu.fill" : "cpu")
                .font(.title3)
                .foregroundColor(isActive ? .green : .secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.name)
                        .font(.headline)
                    if isActive {
                        badge("Activo", color: .green, bold: true)
                    } else if isDownloaded {
                        badge("Descargado", color: .secondary, bold: false)
                    }
                    if model.isCustom {
                        badge("Custom", color: .purple, bold: true)
                    }
                }
                Text(model.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(model.shortDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Image(systemName: "internaldrive")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(sizeLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if isDownloadingThis {
                    HStack(spacing: 6) {
                        ProgressView(value: manager.downloadProgress[model.id] ?? 0, total: 1.0)
                            .progressViewStyle(.linear)
                        Text(String(format: "%.0f%%", (manager.downloadProgress[model.id] ?? 0) * 100))
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                    .padding(.top, 2)
                }
            }

            Spacer()

            VStack(spacing: 6) {
                if isDownloadingThis {
                    Button(action: onCancelDownload) {
                        Label("Cancelar", systemImage: "xmark.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                } else if !isDownloaded {
                    Button(action: onDownload) {
                        Label("Descargar", systemImage: "arrow.down.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(manager.isDownloading)
                } else if isActive {
                    Button(action: {}) {
                        Label("Activo", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(true)
                } else {
                    Button(action: onUse) {
                        Label("Usar", systemImage: "arrow.right.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(manager.isDownloading)
                }

                // 🗑 Liberar: borra pesos/RAM del disco pero DEJA el modelo en la lista.
                Button(action: onRelease) {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
                .disabled(manager.isDownloading)
                .help("Liberar memoria y espacio en disco (la lista no cambia)")

                // ✕ Quitar de la lista: solo para modelos custom.
                if model.isCustom {
                    Button(action: onRemoveFromList) {
                        Image(systemName: "xmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                    .disabled(manager.isDownloading)
                    .help("Quitar de la lista")
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
    }

    private func badge(_ text: String, color: Color, bold: Bool) -> some View {
        Text(text)
            .font(bold ? .caption.bold() : .caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    private var sizeLabel: String {
        if let bytes = manager.diskSizes[model.id] {
            return ModelManagerView.sizeText(bytes)
        }
        return model.estimatedSizeGB > 0
            ? String(format: "~%.1f GB estimado", model.estimatedSizeGB)
            : "Tamaño desconocido"
    }
}
