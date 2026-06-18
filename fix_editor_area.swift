struct EditorAreaView: View {
    @Binding var tab: TabItem
    let selectedTheme: AppTheme
    @ObservedObject var viewModel: EditorViewModel
    
    @State private var isHeatmapActive: Bool = false
    @State private var triggerSearch: Bool = false
    @State private var isHistoryActive: Bool = false
    
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    
                    Button {
                        isHistoryActive.toggle()
                    } label: {
                        Label("Historial", systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(isHistoryActive ? .accentColor : .secondary)
                    
                    // FASE 5: Semantic Heatmap Toggle
                    Toggle(isOn: $isHeatmapActive) {
                        Label("Heat Map", systemImage: "flame.fill")
                            .font(.caption)
                    }
                    .toggleStyle(.button)
                    .tint(.orange)
                    
                    if !tab.isPreviewMode {
                    Button {
                        triggerSearch = true
                    } label: {
                        Label("Buscar", systemImage: "magnifyingglass")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("f", modifiers: .command)
                    }
                }
                
                Button(tab.isPreviewMode ? "Editar" : "Ver") { 
                    tab.isPreviewMode.toggle() 
                    if tab.isPreviewMode {
                        _ = saveNote(path: tab.id, content: tab.content)
                        Telemetry.shared.log("Editor", eventType: "AutoSave", message: "Guardada: \(tab.title)")
                        if let locations = viewModel.currentLocations {
                            viewModel.refreshNotes(locations: locations)
                        }
                    }
                }.buttonStyle(.bordered)
            }.padding(8)
            
            if tab.isPreviewMode {
                WebView(
                    htmlContent: generateSafeHTML(tab.content, theme: selectedTheme, mode: tab.renderMode, isHeatmapActive: isHeatmapActive, noteId: tab.id, searchText: viewModel.searchText),
                    baseURL: URL(fileURLWithPath: tab.id).deletingLastPathComponent(),
                    triggerSearch: $triggerSearch,
                    onNavigate: { url in
                        handleNavigation(url)
                    }
                )
                .id("\(tab.id)-\(tab.renderMode.rawValue)-\(selectedTheme.rawValue)-\(isHeatmapActive)")
            } else {
                CodeEditor(text: $tab.content, triggerSearch: $triggerSearch, language: tab.language, theme: selectedTheme)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(viewModel.macBackground) 
            }
        }
        .background(viewModel.macBackground)
        
        if isHistoryActive {
            Divider()
            GitHistorySidebar(noteId: tab.id, content: $tab.content, isPresented: $isHistoryActive)
                .transition(.move(edge: .trailing))
        }
    }
    
    private func handleNavigation(_ url: URL) {
        if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
            NSWorkspace.shared.open(url)
            return
        }
        
        if url.isFileURL {
            let path = url.path
            // Busqueda exacta
            if let note = viewModel.allNotes.first(where: { $0.path == path }) {
                viewModel.openNote(note)
                return
            }
            
            // Búsqueda por nombre de archivo o título si fue un wikilink convertido a link local pero en otra carpeta
            let fileName = url.lastPathComponent
            let decodedName = fileName.removingPercentEncoding ?? fileName
            let titleWithoutExt = decodedName.replacingOccurrences(of: ".md", with: "")
            
            if let matchingNote = viewModel.allNotes.first(where: { $0.title == titleWithoutExt || $0.title == decodedName }) {
                viewModel.openNote(matchingNote)
            } else {
                print("Nota no encontrada para la ruta: \(path) o nombre \(decodedName)")
            }
        }
    }
