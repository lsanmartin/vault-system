import SwiftUI

/// Columna del tablero Kanban
enum KanbanColumn: String, CaseIterable {
    case backlog = "Backlog"
    case inProgress = "En Progreso"
    case review = "Revisión"
    case done = "Completado"

    var icon: String {
        switch self {
        case .backlog: return "tray"
        case .inProgress: return "arrow.triangle.2.circlepath"
        case .review: return "eye"
        case .done: return "checkmark.circle"
        }
    }
}

/// Una tarea del Kanban
struct KanbanTask: Identifiable {
    let id = UUID()
    var text: String
    var column: KanbanColumn
    var estimatedHours: Double?
    var dependencies: [String] = []
    var refs: String = ""
}

/// Vista del tablero Kanban visual
struct CPMTaskBoardView: View {
    @State private var columns: [KanbanColumn: [KanbanTask]] = [:]
    @State private var projectPath: String = ""
    @State private var projectName: String = ""
    @State private var showAddTask = false
    @State private var newTaskColumn: KanbanColumn = .backlog

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label(projectName.isEmpty ? "Tablero Kanban" : projectName, systemImage: "list.clipboard")
                    .font(.title2).bold()
                Spacer()
                Button(action: { showAddTask = true; newTaskColumn = .backlog }) {
                    Label("Agregar tarea", systemImage: "plus")
                }.buttonStyle(.borderedProminent)
            }.padding()

            Divider()

            // Selector de proyecto
            HStack {
                Text("Proyecto:").font(.caption).foregroundColor(.secondary)
                TextField("Ruta del KANBAN.md", text: $projectPath)
                    .textFieldStyle(.roundedBorder)
                Button("Cargar") { loadKanban() }
                    .buttonStyle(.bordered)
            }.padding(.horizontal).padding(.bottom, 4)

            // Columnas Kanban
            if columns.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.grid.3x3").font(.system(size: 40)).foregroundColor(.secondary)
                    Text("Carga un KANBAN.md o crea uno nuevo").font(.headline)
                    Text("Formato: /Users/lsanmartin/dev/proyecto/KANBAN.md").foregroundColor(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(KanbanColumn.allCases, id: \.self) { col in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: col.icon)
                                Text(col.rawValue).font(.headline)
                                Spacer()
                                Text("\((columns[col] ?? []).count)")
                                    .font(.caption).foregroundColor(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.1)).clipShape(Capsule())
                                Button(action: { newTaskColumn = col; showAddTask = true }) {
                                    Image(systemName: "plus.circle").font(.caption)
                                }.buttonStyle(.plain)
                            }.padding(.horizontal, 8).padding(.top, 8)

                            Divider()

                            ScrollView {
                                VStack(spacing: 6) {
                                    ForEach(columns[col] ?? []) { task in
                                        KanbanCard(task: task, onMove: { newCol in
                                            moveTask(task, to: newCol)
                                        }).padding(.horizontal, 4)
                                    }
                                }.padding(4)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .background(Color.secondary.opacity(0.03))
                        if col != .done { Divider() }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddTask) {
            AddKanbanTaskView(column: newTaskColumn, isPresented: $showAddTask) { task in
                columns[task.column, default: []].append(task)
                saveKanban()
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
            if let first = findFirstKanban() { projectPath = first; loadKanban() }
        }
    }

    // MARK: - Kanban file operations

    private func findFirstKanban() -> String? {
        // Protocolo: kanban.md (minúsculas). Fallback a KANBAN.md por compatibilidad.
        let paths = [
            "/Users/lsanmartin/dev/vault-system/kanban.md",
            "/Users/lsanmartin/dev/volley51app/kanban.md",
            "/Users/lsanmartin/dev/vault-system/KANBAN.md",
            "/Users/lsanmartin/dev/volley51app/KANBAN.md"
        ]
        return paths.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private func loadKanban() {
        guard !projectPath.isEmpty,
              let content = try? String(contentsOfFile: projectPath, encoding: .utf8) else { return }
        projectName = (projectPath as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
        var result: [KanbanColumn: [KanbanTask]] = [:]
        var currentColumn: KanbanColumn = .backlog

        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("## ") {
                let section = String(t.dropFirst(3))
                if let col = KanbanColumn.allCases.first(where: { section.contains($0.rawValue) }) {
                    currentColumn = col
                }
            } else if t.hasPrefix("- [ ] ") || t.hasPrefix("- [x] ") {
                let taskText = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if !taskText.isEmpty {
                    let isDone = t.hasPrefix("- [x] ")
                    let col = isDone ? .done : currentColumn
                    let task = parseTaskLine(taskText, column: col)
                    result[col, default: []].append(task)
                }
            }
        }
        columns = result
    }

    private func parseTaskLine(_ line: String, column: KanbanColumn) -> KanbanTask {
        var task = KanbanTask(text: line, column: column)
        if let estRange = line.range(of: "est:") {
            let rest = String(line[estRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let h = Double(rest.prefix(while: { "0123456789.".contains($0) })) { task.estimatedHours = h }
        }
        return task
    }

    private func moveTask(_ task: KanbanTask, to column: KanbanColumn) {
        for col in KanbanColumn.allCases {
            columns[col]?.removeAll(where: { $0.id == task.id })
        }
        var moved = task; moved.column = column
        columns[column, default: []].append(moved)
        saveKanban()
    }

    private func saveKanban() {
        var lines: [String] = ["---", "project: \(projectName)", "updated: \(DateFormatter().string(from: Date()))", "---", ""]
        for col in KanbanColumn.allCases {
            lines.append("## \(col.rawValue)")
            lines.append("")
            for task in columns[col] ?? [] {
                let prefix = col == .done ? "- [x]" : "- [ ]"
                lines.append("\(prefix) \(task.text)")
            }
            lines.append("")
        }
        let content = lines.joined(separator: "\n")
        try? content.write(toFile: projectPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - Card

struct KanbanCard: View {
    let task: KanbanTask
    var onMove: (KanbanColumn) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.text).font(.caption).lineLimit(3)
            HStack {
                if let est = task.estimatedHours {
                    Text("\(String(format: "%.1f", est))h").font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(KanbanColumn.allCases, id: \.self) { col in
                        if col != task.column {
                            Button("Mover a \(col.rawValue)") { onMove(col) }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.caption2)
                }.menuStyle(.borderlessButton).frame(width: 16)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.1)))
    }
}

// MARK: - Add Task

struct AddKanbanTaskView: View {
    let column: KanbanColumn
    @Binding var isPresented: Bool
    var onAdd: (KanbanTask) -> Void

    @State private var text = ""
    @State private var estimatedHours = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Nueva tarea en \(column.rawValue)").font(.title3).bold()
            TextField("Descripción de la tarea", text: $text).textFieldStyle(.roundedBorder)
            TextField("Horas estimadas (opcional)", text: $estimatedHours).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancelar") { isPresented = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Agregar") {
                    var task = KanbanTask(text: text, column: column)
                    task.estimatedHours = Double(estimatedHours)
                    onAdd(task); isPresented = false
                }.buttonStyle(.borderedProminent).disabled(text.isEmpty)
            }
        }.padding().frame(width: 400)
    }
}
