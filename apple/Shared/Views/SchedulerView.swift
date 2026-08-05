import SwiftUI

struct SchedulerView: View {
    @State private var tasks: [ScheduledTask] = []
    @State private var showAddSheet = false

    struct ScheduledTask: Identifiable, Codable {
        let id: String
        let name: String
        let cronExpr: String
        let command: String
        var enabled: Bool
        let lastRun: String?
        let lastStatus: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Tareas Programadas", systemImage: "clock.arrow.2.circlepath")
                    .font(.title2).bold()
                Spacer()
                Button(action: { schedulerTick() }) {
                    Label("Ejecutar pending", systemImage: "play.fill")
                }.buttonStyle(.bordered).help("Ejecutar tareas pendientes ahora")

                Button(action: { showAddSheet = true }) {
                    Label("Agregar", systemImage: "plus")
                }.buttonStyle(.borderedProminent)
            }.padding()

            Divider()

            if tasks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.badge.questionmark").font(.system(size: 40)).foregroundColor(.secondary)
                    Text("Sin tareas programadas").font(.headline)
                    Text("Agrega tareas recurrentes (consolidación, reindexación, etc).").foregroundColor(.secondary)
                    Button("Agregar tareas predefinidas") { addBuiltinTasks() }.buttonStyle(.bordered)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(tasks) { task in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.name).font(.headline)
                                Text("\(task.command) · \(task.cronExpr)").font(.caption).foregroundColor(.secondary)
                                if let status = task.lastStatus {
                                    Text(status).font(.caption2).foregroundColor(status.hasPrefix("OK") ? .green : .red)
                                }
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { task.enabled },
                                set: { _ = schedulerToggleTask(id: task.id, enabled: $0); loadTasks() }
                            ))
                            Button(action: { _ = schedulerDeleteTask(id: task.id); loadTasks() }) {
                                Image(systemName: "trash").foregroundColor(.red)
                            }.buttonStyle(.plain)
                        }.padding(.vertical, 4)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddTaskView(isPresented: $showAddSheet, onAdded: loadTasks)
        }
        .onAppear(perform: loadTasks)
        .frame(minWidth: 480, minHeight: 400)
    }

    private func loadTasks() {
        guard let data = schedulerListTasks().data(using: .utf8),
              let list = try? JSONDecoder().decode([ScheduledTask].self, from: data) else { return }
        tasks = list
    }

    private func addBuiltinTasks() {
        _ = schedulerScheduleTask(name: "Mantenimiento DB (dedup+vacuum)", command: "maintenance", cronExpr: "0 3 * * *")
        _ = schedulerScheduleTask(name: "Consolidar bitácoras", command: "consolidate-journals", cronExpr: "0 3 * * *")
        _ = schedulerScheduleTask(name: "Embeddings batch nocturno", command: "embedding-batch", cronExpr: "0 2 * * *")
        _ = schedulerScheduleTask(name: "Git GC semanal", command: "git-gc", cronExpr: "0 4 * * 0")
        _ = schedulerScheduleTask(name: "Reindexar Parquet", command: "reindex-parquet", cronExpr: "0 3 * * *")
        loadTasks()
    }

    private func schedulerTick() {
        _ = schedulerTick()
        loadTasks()
    }
}

struct AddTaskView: View {
    @Binding var isPresented: Bool
    var onAdded: () -> Void

    @State private var name = ""
    @State private var command = ""
    @State private var cronExpr = "0 * * * *"

    let commands = ["maintenance", "consolidate-journals", "embedding-batch", "git-gc", "reindex-parquet"]
    let cronPresets = ["0 * * * *", "0 3 * * *", "0 2 * * *", "0 4 * * 0", "*/30 * * * *"]

    var body: some View {
        VStack(spacing: 16) {
            Text("Nueva Tarea").font(.title3).bold()
            TextField("Nombre", text: $name).textFieldStyle(.roundedBorder)
            Picker("Comando", selection: $command) {
                Text("Seleccionar...").tag("")
                ForEach(commands, id: \.self) { Text($0).tag($0) }
            }
            Picker("Cron", selection: $cronExpr) {
                ForEach(cronPresets, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Button("Cancelar") { isPresented = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Agregar") {
                    _ = schedulerScheduleTask(name: name, command: command, cronExpr: cronExpr)
                    onAdded(); isPresented = false
                }.buttonStyle(.borderedProminent).disabled(name.isEmpty || command.isEmpty)
            }
        }.padding().frame(width: 400)
    }
}
