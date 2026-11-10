import AppKit
import PhotoSyncerCore
import SwiftUI

struct AccountsView: View {
    @EnvironmentObject var model: AppModel
    @State private var adding: ServiceKind?
    @State private var googleSetup = false
    @State private var backingUp: Account?
    @State private var renaming: Account?

    var body: some View {
        List {
            if model.config.accounts.isEmpty {
                Text("No accounts yet. Add one with the + button: you sign in inside Photo Syncer, so it can upload for you.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(model.config.accounts) { account in
                AccountRow(account: account,
                           onBackup: { backingUp = account },
                           onRename: { renaming = account })
            }
            Section {
                Button { googleSetup = true } label: {
                    Label(model.hasGoogleClient ? "Google Photos setup (done)" : "Google Photos setup…",
                          systemImage: model.hasGoogleClient ? "checkmark.seal" : "gearshape")
                }
                .buttonStyle(.link)
            } footer: {
                Text("Amazon and Pix-Star sign-ins are kept in Photo Syncer's own browser storage, one per account. Google tokens are kept in a file only you can read, in ~/Library/Application Support/Photo Syncer.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle("Accounts")
        .toolbar {
            ToolbarItem {
                Menu {
                    ForEach(ServiceKind.allCases) { kind in
                        Button { adding = kind } label: { Label(kind.displayName, systemImage: kind.icon) }
                    }
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .help("Add an account or folder")
            }
        }
        .sheet(item: $adding) { kind in
            AddAccountSheet(service: kind) { adding = nil }
        }
        .sheet(isPresented: $googleSetup) {
            GoogleSetupSheet { googleSetup = false }
        }
        .sheet(item: $backingUp) { account in
            BackupSheet(account: account) { backingUp = nil }
        }
        .sheet(item: $renaming) { account in
            RenameSheet(account: account) { renaming = nil }
        }
    }
}

struct AccountRow: View {
    @EnvironmentObject var model: AppModel
    let account: Account
    let onBackup: () -> Void
    let onRename: () -> Void
    @State private var confirmingRemove = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: account.service.icon).font(.title2).foregroundStyle(account.service.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).font(.body.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            Spacer()
            switch account.service {
            case .amazon, .pixstar:
                Button("Sign In…") { model.signingIn = account }
            case .google:
                Button("Sign In…") { Task { await model.signInToGoogle(account) } }
                    .disabled(!model.hasGoogleClient)
            case .folder:
                Button("Show in Finder") {
                    if let path = account.folderPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                }
            }
            Menu {
                Button("Check Sign-In") { Task { await model.verify(account) } }
                Button("Rename…", action: onRename)
                if account.service == .pixstar {
                    Button("Back Up an Album…", action: onBackup)
                }
                Divider()
                Button("Remove Account…", role: .destructive) { confirmingRemove = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
        }
        .padding(.vertical, 4)
        .confirmationDialog("Remove \(account.name)?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { model.removeAccount(account) }
        } message: {
            Text("Its mappings and sign-in are removed from Photo Syncer. Nothing is deleted from \(account.service.displayName).")
        }
    }

    private var detail: String {
        if let message = model.accountMessages[account.id] { return message }
        switch account.service {
        case .folder: return account.folderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "No folder chosen"
        default:
            let who = account.signedInAs.map { "Signed in as \($0)" } ?? account.service.displayName
            if let size = account.maxPixelSize { return who + " · photos downsized to \(size) px" }
            return who
        }
    }
}

struct AddAccountSheet: View {
    @EnvironmentObject var model: AppModel
    let service: ServiceKind
    let onClose: () -> Void
    @State private var name = ""
    @State private var folderPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Add \(service.displayName)", systemImage: service.icon).font(.title2.weight(.semibold))
            TextField("Name", text: $name, prompt: Text(defaultName)).textFieldStyle(.roundedBorder)
            switch service {
            case .amazon:
                Text("Next, sign in to Amazon in the window that opens. Photo Syncer uses the same web API as amazon.com/photos.")
            case .pixstar:
                Text("Next, sign in with the frame's Pix-Star address. To upload to an album managed by a multi-frame account, add that account too and sign in with it.")
            case .google:
                if model.hasGoogleClient {
                    Text("Next, your browser opens to sign in to Google and allow Photo Syncer to add photos to albums it creates.")
                } else {
                    Text("Google needs a one-time setup first (an OAuth client of your own). Add the account now, then use Google Photos setup in Accounts.")
                        .foregroundStyle(.orange)
                }
            case .folder:
                HStack {
                    TextField("Folder", text: $folderPath).textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { folderPath = url.path }
                    }
                }
                Text("Photos are copied into sub-folders of this folder (one per album), for a dashboard or anything else that reads files.")
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button(service.usesWebSession || service == .google ? "Add and Sign In" : "Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(service == .folder && folderPath.isEmpty)
            }
        }
        .font(.callout)
        .padding(20)
        .frame(width: 480)
    }

    private var defaultName: String {
        let existing = model.config.accounts.filter { $0.service == service }.count
        return existing == 0 ? service.displayName : "\(service.displayName) \(existing + 1)"
    }

    private func add() {
        let account = Account(service: service, name: name.isEmpty ? defaultName : name,
                              folderPath: service == .folder ? folderPath : nil)
        model.addAccount(account)
        onClose()
        switch service {
        case .amazon, .pixstar: model.signingIn = account
        case .google: if model.hasGoogleClient { Task { await model.signInToGoogle(account) } }
        case .folder: Task { await model.verify(account) }
        }
    }
}

struct RenameSheet: View {
    @EnvironmentObject var model: AppModel
    let account: Account
    let onClose: () -> Void
    @State private var name = ""
    @State private var downsize = false
    @State private var size = 2048

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Account Settings").font(.title2.weight(.semibold))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            if account.service != .folder {
                Toggle("Downsize photos before uploading", isOn: $downsize)
                if downsize {
                    Stepper("Longest side: \(size) px", value: $size, in: 1024...8192, step: 256)
                }
                Text("Pix-Star keeps small copies anyway, so downsizing makes uploads much faster. Amazon matches photos by their exact bytes, so leave it off there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Save") {
                    var updated = account
                    updated.name = name.isEmpty ? account.name : name
                    updated.maxPixelSize = downsize ? size : nil
                    model.updateAccount(updated)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            name = account.name
            downsize = account.maxPixelSize != nil
            size = account.maxPixelSize ?? 2048
        }
    }
}

struct GoogleSetupSheet: View {
    @EnvironmentObject var model: AppModel
    let onClose: () -> Void
    @State private var clientId = ""
    @State private var secret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Google Photos Setup").font(.title2.weight(.semibold))
            Text("Google only lets apps upload with an OAuth client registered to someone. It takes about five minutes, once:")
            VStack(alignment: .leading, spacing: 6) {
                step(1, "In Google Cloud Console, create a project (any name, such as \"Photo Syncer\").")
                step(2, "APIs & Services › Library: enable the **Photos Library API**.")
                step(3, "Google Auth Platform › Branding: app name, support email and developer contact. Audience: **External**.")
                step(4, "Audience › Test users: add the Google account you'll upload to. (In Testing, Google signs you out every 7 days; publishing needs a homepage and privacy policy on your own domain.)")
                step(5, "Clients › Create client › Application type **Desktop app**. Copy the client ID and secret here; Google shows the secret only once.")
            }
            Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/library/photoslibrary.googleapis.com")!)
            TextField("Client ID", text: $clientId, prompt: Text("…apps.googleusercontent.com")).textFieldStyle(.roundedBorder)
            SecureField("Client secret", text: $secret).textFieldStyle(.roundedBorder)
            Text("When you sign in, Google warns that the app isn't verified: continue past it. It's your own client, used only by this Mac. \"Access blocked\" means the account isn't a test user yet.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.saveGoogleClient(id: clientId, secret: secret)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(clientId.isEmpty || secret.isEmpty)
            }
        }
        .font(.callout)
        .padding(20)
        .frame(width: 560)
        .onAppear { clientId = model.config.google?.clientId ?? "" }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).").monospacedDigit().foregroundStyle(.secondary)
            Text(text)
        }
    }
}

/// Downloads every photo in a Pix-Star album to a folder, and optionally sets aside the
/// ones that aren't in a local folder.
struct BackupSheet: View {
    @EnvironmentObject var model: AppModel
    let account: Account
    let onClose: () -> Void

    @State private var albums: [RemoteAlbum] = []
    @State private var album: DestinationRef?
    @State private var folder = ""
    @State private var compareWith = (("~/Pictures" as NSString).expandingTildeInPath)
    @State private var compare = true
    @State private var progress: (Int, Int)?
    @State private var result: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Back Up a Pix-Star Album").font(.title2.weight(.semibold))
            Text("Downloads every photo in the album (Pix-Star's copies) into a folder on this Mac. Nothing on Pix-Star changes.")
                .foregroundStyle(.secondary)
            Picker("Album", selection: $album) {
                Text(albums.isEmpty ? "Loading…" : "Choose an album").tag(DestinationRef?.none)
                ForEach(albums) { album in
                    Text("\(album.ref.name) (\(album.count ?? 0))").tag(DestinationRef?.some(album.ref))
                }
            }
            .onChange(of: album) { _, new in
                if let new { folder = defaultFolder(for: new) }
            }
            HStack {
                TextField("Save to", text: $folder).textFieldStyle(.roundedBorder)
                Button("Choose…") { pick { folder = $0 } }
            }
            Toggle("Then set aside photos with no match in:", isOn: $compare)
            HStack {
                TextField("Local folder", text: $compareWith).textFieldStyle(.roundedBorder).disabled(!compare)
                Button("Choose…") { pick { compareWith = $0 } }.disabled(!compare)
            }
            Text("They're copied into a \"Not in …\" folder inside the backup, matched by file name.")
                .font(.caption).foregroundStyle(.secondary)

            if let progress {
                ProgressView(value: Double(progress.0), total: Double(max(progress.1, 1)))
                Text("\(progress.0) of \(progress.1)").font(.caption).foregroundStyle(.secondary)
            }
            if let result { Text(result).foregroundStyle(.secondary).textSelection(.enabled) }

            HStack {
                if result != nil {
                    Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
                }
                Spacer()
                Button(task == nil ? "Close" : "Stop") {
                    if let task { task.cancel() } else { onClose() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Back Up", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(album == nil || folder.isEmpty || task != nil)
            }
        }
        .font(.callout)
        .padding(20)
        .frame(width: 560)
        .task {
            do { albums = try await model.makeService(account).albums() } catch { result = error.localizedDescription }
        }
    }

    private func defaultFolder(for album: DestinationRef) -> String {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        return pictures.appendingPathComponent("Photo Syncer Backups/\(account.name)/\(album.name)").path
    }

    private func pick(_ set: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { set(url.path) }
    }

    private func start() {
        guard let album else { return }
        result = nil
        progress = (0, album.name.isEmpty ? 0 : 1)
        let target = URL(fileURLWithPath: folder)
        let local = compare ? URL(fileURLWithPath: compareWith) : nil
        task = Task {
            do {
                let counts = try await model.engine.backup(account: account, album: album, to: target) { done, total in
                    Task { @MainActor in progress = (done, total) }
                }
                var text = "\(counts.saved) downloaded, \(counts.skipped) already in the folder" + (counts.failed > 0 ? ", \(counts.failed) failed (see Log)." : ".")
                if let local {
                    let missing = try model.engine.copyMissing(backup: target, comparedWith: local, service: .pixstar)
                    text += " \(missing) have no match in \(local.lastPathComponent): they're in \"Not in \(local.lastPathComponent)\"."
                }
                result = text
            } catch {
                result = error.localizedDescription
            }
            task = nil
        }
    }
}
