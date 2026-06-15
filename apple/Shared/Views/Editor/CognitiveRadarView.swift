import SwiftUI

struct CognitiveRadarView: View {
    let noteId: String
    
    @State private var noveltyScore: Double = 0.0
    @State private var loadScore: Double = 0.0
    @State private var relatedEntities: Int = 0
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("COGNITIVE RADAR")
                    .font(.caption2)
                    .fontWeight(.heavy)
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: "sensor.tag.radiowaves.forward")
                    .foregroundColor(.accentColor)
                    .font(.caption)
            }
            .padding(.bottom, 4)
            
            HStack(spacing: 15) {
                RadarMetricView(title: "Novedad", value: noveltyScore, color: .purple)
                RadarMetricView(title: "Carga Cognitiva", value: loadScore, color: .orange)
                RadarMetricView(title: "Entidades", value: Double(relatedEntities) / 100.0, displayValue: "\(relatedEntities)", color: .blue)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.windowBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .onAppear {
            analyzeTemporalGraph()
        }
        .onChange(of: noteId) { _ in
            analyzeTemporalGraph()
        }
    }
    
    private func analyzeTemporalGraph() {
        // Obtenemos la vecindad del grafo (Fase 3)
        let edges = getTemporalNeighborhood(noteId: noteId, maxDepth: 2)
        
        // Simulación de heurística
        self.relatedEntities = edges.count
        self.noveltyScore = min(1.0, Double(edges.count) * 0.05 + 0.2)
        self.loadScore = min(1.0, noveltyScore * 0.8 + 0.1)
    }
}

struct RadarMetricView: View {
    let title: String
    let value: Double
    var displayValue: String? = nil
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
            
            HStack {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(color.opacity(0.2))
                            .frame(height: 6)
                        Capsule()
                            .fill(color)
                            .frame(width: geo.size.width * value, height: 6)
                    }
                }
                .frame(height: 6)
                
                if let disp = displayValue {
                    Text(disp)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                } else {
                    Text("\(Int(value * 100))%")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
            }
        }
    }
}
