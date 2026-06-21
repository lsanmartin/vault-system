import SwiftUI

// MARK: - HeatmapView
// Panel de actividad temporal del workspace activo.
// Muestra las notas modificadas en los últimos N días, agrupadas por día,
// con intensidad de color proporcional a la recencia (heat).

struct HeatmapView: View {
    @ObservedObject var viewModel: EditorViewModel
    @EnvironmentObject var workspaceManager: WorkspaceManager

    @State private var activityByDay: [(label: String, date: String, notes: [NoteActivity])] = []
    @State private var isLoading: Bool = false
    @State private var totalCount: Int = 0

    private let daysBack: UInt32 = 7

    private var currentWorkspacePath: String? {
        workspaceManager.allLocations.first(where: { $0.id == viewModel.selectedLocationId })?.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──────────────────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.orange)
                Text("Últimos 7 días · \(totalCount) notas")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    loadActivity()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refrescar actividad")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().opacity(0.4)

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.55)
                    Text("Leyendo actividad…")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            } else if activityByDay.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sin actividad reciente")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Edita notas en este workspace para ver el mapa de actividad.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(activityByDay, id: \.date) { dayGroup in
                            HeatmapDaySection(
                                label: dayGroup.label,
                                notes: dayGroup.notes,
                                viewModel: viewModel
                            )
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .onChange(of: viewModel.selectedLocationId) { _, _ in loadActivity() }
        .onAppear { loadActivity() }
    }

    private func loadActivity() {
        DispatchQueue.main.async {
            guard let wsPath = self.currentWorkspacePath else {
                self.activityByDay = []
                return
            }
            self.isLoading = true

            DispatchQueue.global(qos: .userInitiated).async {
                let items = getWorkspaceActivity(workspacePath: wsPath, daysBack: self.daysBack)

                // Agrupar por days_ago
                var grouped: [UInt32: [NoteActivity]] = [:]
                for item in items {
                    grouped[item.daysAgo, default: []].append(item)
                }

                let calendar = Calendar.current
                let today = Date()
                let dateFormatter = DateFormatter()
                dateFormatter.locale = Locale(identifier: "es_CL")

                var sections: [(label: String, date: String, notes: [NoteActivity])] = []

                for day in 0..<self.daysBack {
                    guard let notes = grouped[day], !notes.isEmpty else { continue }
                    guard let date = calendar.date(byAdding: .day, value: -Int(day), to: today) else { continue }

                    let label: String
                    switch day {
                    case 0: label = "Hoy"
                    case 1: label = "Ayer"
                    default:
                        dateFormatter.dateFormat = "EEEE d"
                        label = dateFormatter.string(from: date).capitalized
                    }

                    dateFormatter.dateFormat = "yyyy-MM-dd"
                    let dateKey = dateFormatter.string(from: date)

                    sections.append((label: label, date: dateKey, notes: notes))
                }

                let total = items.count

                DispatchQueue.main.async {
                    self.activityByDay = sections
                    self.totalCount    = total
                    self.isLoading     = false
                }
            }
        }
    }
}

// MARK: - Sección diaria

struct HeatmapDaySection: View {
    let label: String
    let notes: [NoteActivity]
    @ObservedObject var viewModel: EditorViewModel

    @State private var isExpanded: Bool = true

    // Calor máximo del día (para normalizar la barra dentro del día)
    private var maxHeat: Float { notes.map(\.heat).max() ?? 1.0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header de día
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)

                Text(label)
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(label == "Hoy" ? .orange : .secondary)

                Spacer()

                Text("\(notes.count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(label == "Hoy" ? Color.orange : Color.secondary.opacity(0.5))
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(notes, id: \.path) { note in
                        HeatmapNoteRow(note: note, maxHeat: maxHeat, viewModel: viewModel)
                    }
                }
                .padding(.leading, 16)
                .padding(.bottom, 4)
            }
        }
    }
}

// MARK: - Fila de nota individual con barra de calor

struct HeatmapNoteRow: View {
    let note: NoteActivity
    let maxHeat: Float
    @ObservedObject var viewModel: EditorViewModel

    // Opacidad base del color según recencia absoluta
    private var heatOpacity: Double { Double(note.heat) * 0.85 + 0.15 }

    // Ancho relativo de la barra (relativo al máximo del día)
    private var relativeWidth: Double {
        maxHeat > 0 ? Double(note.heat / maxHeat) : 0
    }

    // Hora de modificación legible
    private var modifiedTime: String {
        let date = Date(timeIntervalSince1970: TimeInterval(note.modifiedSecs))
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Barra de calor vertical
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.orange.opacity(heatOpacity))
                .frame(width: 3, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                // Mini barra de heat relativa al día
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.orange.opacity(0.12))
                            .frame(height: 2)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.orange.opacity(heatOpacity))
                            .frame(width: geo.size.width * relativeWidth, height: 2)
                    }
                }
                .frame(height: 2)
            }

            Spacer()

            Text(modifiedTime)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.001))
        .contentShape(Rectangle())
        .onTapGesture {
            // Abrir la nota en el editor
            if let record = viewModel.allNotes.first(where: { $0.path == note.path }) {
                viewModel.selectItem(record, extend: false, toggle: false)
            }
        }
        .help(note.path)
    }
}
