import SwiftUI

struct LogView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.logLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.contains("✗") ? .red : .primary)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .onChange(of: model.logLines.count) { _, count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
        .overlay {
            if model.logLines.isEmpty {
                Text("Nothing logged today.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Log")
        .toolbar {
            ToolbarItem {
                Button { model.openLogFolder() } label: { Label("Show Log Files", systemImage: "folder") }
            }
        }
    }
}
