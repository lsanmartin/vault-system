struct DetailColumn: View {
    @ObservedObject var viewModel: EditorViewModel
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @Binding var isNoteHidden: Bool
    
    var body: some View {
        ZStack {
            if let activeId = viewModel.activeTabId, let index = viewModel.tabs.firstIndex(where: { $0.id == activeId }) {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(viewModel.tabs) { tab in
                                TabHeaderView(tab: tab, isActive: tab.id == activeId, viewModel: viewModel) {
                                    viewModel.activeTabId = tab.id
                                } onClose: {
                                    if let idx = viewModel.tabs.firstIndex(where: { $0.id == tab.id }) { viewModel.closeTab(at: IndexSet(integer: idx)) }
                                }
                            }
                        }
                    }
                    .background(viewModel.macSidebar)
                    
                    EditorAreaView(tab: $viewModel.tabs[index], selectedTheme: viewModel.selectedTheme, viewModel: viewModel)
                    
                    // FASE 5: Cognitive Radar
                    CognitiveRadarView(noteId: viewModel.tabs[index].id)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .padding(.top, 8)
                        .background(viewModel.macBackground)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button(action: {
                            withAnimation { isNoteHidden.toggle() }
                        }) {
                            Label("Ocultar Nota", systemImage: "uiwindow.split.2x1")
                        }
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                        .help("Ocultar Nota (Cmd+Shift+E)")

                        Button(action: {
                            NSApp.keyWindow?.toggleFullScreen(nil)
                        }) {
                            Label("Pantalla Completa", systemImage: "arrow.up.backward.and.arrow.down.forward")
                        }
                        .keyboardShortcut("f", modifiers: [.control, .command])
                        .help("Pantalla Completa Nativa (Ctrl+Cmd+F)")
                        
                        Button(action: { viewModel.saveActiveTab(locations: workspaceManager.allLocations) }) { Label("Save", systemImage: "checkmark.circle") }.keyboardShortcut("s", modifiers: .command)
                        Button(action: { viewModel.togglePreview() }) { Label("Preview", systemImage: "eye") }.keyboardShortcut("r", modifiers: .command)
                    }
                }
            } else {
                ZStack {
                    viewModel.macBackground.ignoresSafeArea()
                    ContentUnavailableView("Selecciona una nota", systemImage: "text.document")
                        .opacity(0.5)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
