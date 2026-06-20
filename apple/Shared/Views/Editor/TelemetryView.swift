import SwiftUI

struct TelemetryView: View {
    @ObservedObject var viewModel: EditorViewModel
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "terminal.fill")
                    .foregroundColor(.green)
                Text("MCP Telemetry Console")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button {
                    withAnimation { isPresented = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.black)
            
            // Console
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if viewModel.telemetryLogs.isEmpty {
                            Text("Esperando eventos MCP...")
                                .foregroundColor(.gray)
                                .font(.system(.caption, design: .monospaced))
                        } else {
                            ForEach(Array(viewModel.telemetryLogs.enumerated()), id: \.offset) { index, log in
                                Text(log)
                                    .foregroundColor(colorForLog(log))
                                    .font(.system(.caption, design: .monospaced))
                                    .id(index)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: viewModel.telemetryLogs.count) { _, _ in
                    if viewModel.telemetryLogs.count > 0 {
                        withAnimation {
                            proxy.scrollTo(viewModel.telemetryLogs.count - 1, anchor: .bottom)
                        }
                    }
                }
            }
            .background(Color(white: 0.1))
        }
        .frame(height: 250)
        .overlay(Rectangle().stroke(Color.gray.opacity(0.3), lineWidth: 1))
        .shadow(radius: 10)
    }
    
    private func colorForLog(_ log: String) -> Color {
        if log.contains("(humano)") {
            return .blue
        } else if log.contains("(agente)") {
            return .green
        } else if log.hasPrefix("MCP") {
            return .purple
        } else {
            return .gray
        }
    }
}
