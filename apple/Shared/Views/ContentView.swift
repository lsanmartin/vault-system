import SwiftUI

struct ContentView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var coreMessage: String = "Esperando acción..."
    @State private var dbStatus: String = "DB No inicializada"
    @State private var isHydrating: Bool = false
    @State private var isDBReady: Bool = false
    
    // Patrones del "Anillo de Inteligencia" y "Flujo" a ignorar por defecto
    private let defaultIgnorePatterns = [
        "_memory.md", "_metadata.md", "_specs.md", "_lore.md",
        "00-Sistema", "01-Diario", "05-IA-Drafts",
        "agent.md", ".git", ".obsidian"
    ]

    var body: some View {
        if !workspaceManager.isAuthorized {
            VStack(spacing: 20) {
                HStack {
                    Image(systemName: "brain.head.profile")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                        .foregroundColor(.gray)
                    
                    Text("Vault System")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Spacer()
                }
                
                VStack(spacing: 15) {
                    Text("Privacidad por Diseño")
                        .font(.headline)
                    Text("Vault System requiere acceso explícito a tus carpetas para operar. Todo el procesamiento ocurre de forma local y segura.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 20)
                    
                    Button("Añadir mi primer Vault") {
                        workspaceManager.requestAccess()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(40)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.05)))
            }
            .padding(30)
            .frame(width: 550)
        } else {
            // El Editor principal ocupa todo el espacio disponible
            MainEditorView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(WorkspaceManager())
    }
}
