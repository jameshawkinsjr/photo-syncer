import AppKit
import PhotoSyncerCore
import SwiftUI

/// Where the sync data lives, how it's shared with other Macs, and updates.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var pendingFolder: URL?
    @State private var folderHasData = false
    @State private var error: String?
    @State private var cloudStatus: Bool?
    @State private var lockHolder: SyncLock.Holder?

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder") {
                    Text(model.storage.dataPath).textSelection(.enabled)
                }
                HStack {
                    Button("Change…", action: chooseFolder).disabled(model.isSyncing)
                    Button("Show in Finder") { NSWorkspace.shared.open(model.storage.dataRoot) }
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            } header: {
                Text("Sync Data")
            } footer: {
                Text("Your mappings, what each one has synced, and the logs. Put this folder somewhere every Mac can reach (iCloud Drive, Dropbox, a shared drive) and point each Mac's Photo Syncer at it to share one setup. Sign-ins and Google tokens stay on each Mac: sign in once on each.")
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("This Mac") {
                LabeledContent("Name", value: ThisMac.name)
                LabeledContent("Photos across Macs") {
                    switch cloudStatus {
                    case .some(true):
                        Label("Matched through iCloud Photos", systemImage: "checkmark.icloud").foregroundStyle(.green)
                    case .some(false):
                        Label("iCloud Photos isn't on: Photos history only applies to this Mac", systemImage: "icloud.slash")
                            .foregroundStyle(.orange)
                    case .none:
                        Text(PhotosLibrary.isAuthorized ? "Checking…" : "Allow Photos access to check").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Syncing elsewhere") {
                    if let lockHolder {
                        Text("\(lockHolder.mac), since \(lockHolder.started.formatted(date: .omitted, time: .shortened))")
                    } else {
                        Text("No").foregroundStyle(.secondary)
                    }
                }
            }

            UpdatesSection(updater: model.updater, isSyncing: model.isSyncing)
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task {
            lockHolder = model.lock.blocker()
            if PhotosLibrary.isAuthorized {
                cloudStatus = await Task.detached { PhotosLibrary.cloudIdentifiersAvailable() }.value
            }
        }
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { pendingFolder != nil }, set: { if !$0 { pendingFolder = nil } })) {
            if folderHasData {
                Button("Use the Settings There") { apply(moveData: false) }
            } else {
                Button("Move My Data There") { apply(moveData: true) }
            }
        } message: {
            Text(folderHasData
                 ? "This Mac will use the mappings and sync history already in that folder. Your current data stays where it is."
                 : "Your mappings, sync history and logs move to that folder. Sign-ins stay on this Mac.")
        }
    }

    private var dialogTitle: String {
        let name = pendingFolder.map { PortablePath.display($0.path) } ?? ""
        return folderHasData ? "\(name) already has Photo Syncer settings" : "Move sync data to \(name)?"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder for Photo Syncer's sync data, or a folder another Mac already uses."
        panel.directoryURL = model.storage.dataRoot.deletingLastPathComponent()
        guard panel.runModal() == .OK, var folder = panel.url else { return }
        // Picking a general folder (Dropbox, iCloud Drive) puts the data in "Photo Syncer" inside it.
        if !Storage.hasSyncData(at: folder) && folder.lastPathComponent != "Photo Syncer" {
            folder.appendPathComponent("Photo Syncer", isDirectory: true)
        }
        guard folder.standardizedFileURL != model.storage.dataRoot.standardizedFileURL else { return }
        folderHasData = Storage.hasSyncData(at: folder)
        pendingFolder = folder
    }

    private func apply(moveData: Bool) {
        guard let folder = pendingFolder else { return }
        pendingFolder = nil
        do {
            try model.moveDataFolder(to: folder, moveData: moveData)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The release folder, whether a newer build is there, and Install & Restart.
struct UpdatesSection: View {
    @ObservedObject var updater: Updater
    let isSyncing: Bool

    var body: some View {
        Section {
            LabeledContent("This version", value: updater.app?.label ?? "Not a built app")
            LabeledContent("Release folder") {
                if let folder = updater.releaseFolder {
                    Text(PortablePath.display(folder.path)).textSelection(.enabled)
                } else {
                    Text("Not chosen").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Choose…", action: chooseFolder)
                Button("Show in Finder") {
                    if let folder = updater.releaseFolder { NSWorkspace.shared.open(folder) }
                }
                .disabled(updater.releaseFolder == nil)
            }
            Toggle("Check automatically", isOn: Binding(get: { updater.settings.checkAutomatically },
                                                        set: { updater.setCheckAutomatically($0) }))
            LabeledContent("Last checked") {
                Text(updater.settings.lastChecked.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Status") { status }
            if let notes = updater.readyRelease?.notes, !notes.isEmpty {
                LabeledContent("What's new") {
                    Text(notes).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.trailing)
                }
            }
            if let notice = updater.notice {
                Text(notice).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Check Now") { updater.check() }
                    .disabled(updater.app == nil || updater.releaseFolder == nil || updater.isBusy)
                Button("Install & Restart") { updater.install() }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.readyRelease == nil || isSyncing)
                if updater.readyRelease != nil && isSyncing {
                    Text("Wait for the sync to finish.").foregroundStyle(.secondary).font(.callout)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Photo Syncer looks in the release folder for a newer build (published there with scripts/publish.sh), copies it to this Mac and checks it. Nothing is installed until you click Install & Restart. Use a folder only you can change: the app installs what it finds there. After an update, macOS may ask for Photos access again.")
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var status: some View {
        if updater.app == nil {
            Text("Updates need the built app (scripts/build-app.sh)").foregroundStyle(.secondary)
        } else {
            switch updater.status {
            case .notChecked:
                Text(updater.releaseFolder == nil ? "Choose a release folder to check for updates" : "Not checked yet")
                    .foregroundStyle(.secondary)
            case .checking:
                Text("Checking…").foregroundStyle(.secondary)
            case .upToDate:
                Label("Up to date", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .downloading(let release):
                Text("Downloading version \(release.label)…").foregroundStyle(.secondary)
            case .ready(let release):
                Label("Version \(release.label) is ready to install", systemImage: "arrow.down.circle").foregroundStyle(.blue)
            case .installing(let release):
                Text("Installing version \(release.label)…").foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing).textSelection(.enabled)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder builds are published to (the one with latest.json)."
        if let folder = updater.releaseFolder { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        updater.setReleaseFolder(folder)
    }
}
