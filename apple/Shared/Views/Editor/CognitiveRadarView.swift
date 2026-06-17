import SwiftUI

struct CognitiveRadarView: View {
    let noteId: String
    
    @State private var noveltyScore: Double = 0.0
    @State private var loadScore: Double = 0.0
    @State private var relatedEntities: Int = 0
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sensor.tag.radiowaves.forward")
                .foregroundColor(.accentColor)
                .font(.system(size: 10, weight: .bold))
            
            Divider().frame(height: 10)
            
            CompactRadarMetricView(title: "NOV", value: noveltyScore, color: .purple)
            CompactRadarMetricView(title: "CARGA", value: loadScore, color: .orange)
            CompactRadarMetricView(title: "ENT", value: Double(relatedEntities) / 100.0, displayValue: "\(relatedEntities)", color: .blue)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color(.windowBackgroundColor)))
        .overlay(
            Capsule()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .onAppear {
            analyzeTemporalGraph()
        }
        .onChange(of: noteId) {
            analyzeTemporalGraph()
        }
    }
    
    private func analyzeTemporalGraph() {
        // Ejecutar la consulta pesada a DuckDB en background
        DispatchQueue.global(qos: .userInitiated).async {
            let edges = getTemporalNeighborhood(noteId: noteId, maxDepth: 2)
            
            DispatchQueue.main.async {
                // Simulación de heurística
                self.relatedEntities = edges.count
                self.noveltyScore = min(1.0, Double(edges.count) * 0.05 + 0.2)
                self.loadScore = min(1.0, self.noveltyScore * 0.8 + 0.1)
            }
        }
    }
}

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
