import PhotoSyncerCore
import SwiftUI

@main
struct PhotoSyncerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Photo Syncer", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Sync") {
                Button("Sync All") { model.syncAll() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.isSyncing || model.config.mappings.isEmpty)
                Button("Stop") { model.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isSyncing)
                Divider()
                Button("Show Log Files") { model.openLogFolder() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Pane: String, Hashable, CaseIterable {
    case sync, accounts, log

    var title: String {
        switch self {
        case .sync: return "Sync"
        case .accounts: return "Accounts"
        case .log: return "Log"
        }
    }

    var icon: String {
        switch self {
        case .sync: return "arrow.triangle.2.circlepath"
        case .accounts: return "person.2"
        case .log: return "list.bullet.rectangle"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, id: \.self, selection: $model.pane) { pane in
                Label(pane.title, systemImage: pane.icon)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch model.pane ?? .sync {
            case .sync: SyncView()
            case .accounts: AccountsView()
            case .log: LogView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isSyncing {
                    Button { model.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
                        .help("Stop syncing")
                } else {
                    Button { model.syncAll() } label: { Label("Sync All", systemImage: "arrow.triangle.2.circlepath") }
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.config.mappings.filter(\.enabled).isEmpty)
                        .help("Push new photos for every mapping")
                }
            }
        }
        .task { await SnapshotMode.runIfRequested(model) }
        .sheet(item: $model.signingIn) { account in
            SignInView(account: account) { _ in
                model.signingIn = nil
                Task { await model.verify(account) }
            }
        }
    }
}

extension ServiceKind {
    var icon: String {
        switch self {
        case .amazon: return "a.circle.fill"
        case .google: return "g.circle.fill"
        case .pixstar: return "photo.artframe"
        case .folder: return "folder.fill"
        }
    }

    var tint: Color {
        switch self {
        case .amazon: return .orange
        case .google: return .blue
        case .pixstar: return .purple
        case .folder: return .teal
        }
    }
}

extension Date {
    var relative: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
