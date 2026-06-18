import SwiftUI

struct CognitiveRadarView: View {
    let noteId: String
    let workspacePath: String

    @State private var entityCount: Int = 0
    @State private var noveltyScore: Double = 0.0
    @State private var loadScore: Double = 0.0
    @State private var isComputing: Bool = false

    // Color de CARGA: verde (bajo) → amarillo (medio) → rojo (alto)
    private var loadColor: Color {
        switch loadScore {
        case 0..<0.35: return .green
        case 0.35..<0.65: return .yellow
        default: return .red
        }
    }

    // Interpretación textual de la carga
    private var loadLabel: String {
        switch loadScore {
        case 0..<0.35: return "Foco"
        case 0.35..<0.65: return "Mixto"
        default: return "Disperso"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Icono + estado de cómputo
            ZStack {
                Image(systemName: "sensor.tag.radiowaves.forward")
                    .foregroundColor(loadColor)
                    .font(.system(size: 10, weight: .bold))
                if isComputing {
                    ProgressView()
                        .scaleEffect(0.4)
                        .offset(x: 10, y: -8)
                }
            }

            Divider().frame(height: 10)

            // NOV — Novedad semántica: qué tan nueva/aislada es la nota
            CompactRadarMetricView(
                title: "NOV",
                value: noveltyScore,
                color: noveltyScore > 0.7 ? .purple : .blue
            )
            .help("Novedad: qué tan aislada está esta nota del resto del workspace.\n1 = tema nuevo sin conexiones, 0 = bien integrada.")

            // CARGA — Context-switching: cuántos proyectos distintos toca su grafo
            CompactRadarMetricView(
                title: "CARGA",
                value: loadScore,
                displayValue: loadLabel,
                color: loadColor
            )
            .help("Carga Cognitiva: diversidad de proyectos en el grafo de esta nota.\nAlta = estás saltando entre muchos contextos distintos.")

            // ENT — Entidades conectadas (grafo de links real)
            CompactRadarMetricView(
                title: "ENT",
                value: min(1.0, Double(entityCount) / 50.0),
                displayValue: "\(entityCount)",
                color: .blue
            )
            .help("Entidades: nodos conectados a esta nota en el grafo de links.\n(links en tabla DuckDB, profundidad 1)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color(.windowBackgroundColor)))
        .overlay(
            Capsule()
                .stroke(loadColor.opacity(0.25), lineWidth: 1)
        )
        .onAppear {
            computeMetrics()
        }
        .onChange(of: noteId) {
            computeMetrics()
        }
    }

    private func computeMetrics() {
        guard !noteId.isEmpty, !workspacePath.isEmpty else { return }
        isComputing = true

        DispatchQueue.global(qos: .userInitiated).async {
            let metrics = getCognitiveMetrics(noteId: noteId, workspacePath: workspacePath)

            DispatchQueue.main.async {
                self.entityCount   = Int(metrics.entityCount)
                self.noveltyScore  = Double(metrics.noveltyScore)
                self.loadScore     = Double(metrics.loadScore)
                self.isComputing   = false
            }
        }
    }
}

// MARK: - Barra de métrica compacta (sin cambios de interfaz)

struct CompactRadarMetricView: View {
    let title: String
    let value: Double
    var displayValue: String? = nil
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .heavy))
                .foregroundColor(.secondary)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(color.opacity(0.2))
                    .frame(width: 32, height: 4)
                Capsule()
                    .fill(color)
                    .frame(width: 32 * value, height: 4)
                    .animation(.easeOut(duration: 0.4), value: value)
            }

            if let disp = displayValue {
                Text(disp)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
            } else {
                Text("\(Int(value * 100))%")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
            }
        }
    }
}
