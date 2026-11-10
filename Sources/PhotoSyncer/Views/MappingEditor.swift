import AppKit
import PhotoSyncerCore
import SwiftUI

/// Choose a source (a Photos album or a folder), an account, and the album there.
struct MappingEditor: View {
    @EnvironmentObject var model: AppModel
    let mapping: Mapping?
    let onClose: () -> Void

    enum SourceKind: String, CaseIterable { case photos = "Photos Album", folder = "Folder" }

    @State private var sourceKind: SourceKind = .photos
    @State private var folderPath = (("~/Pictures" as NSString).expandingTildeInPath)
    @State private var albumTree: [PhotosAlbumNode] = []
    @State private var photosAllowed = PhotosLibrary.isAuthorized
    @State private var selectedAlbum: PhotosAlbumNode?

    @State private var accountId: UUID?
    @State private var destinations: [RemoteAlbum] = []
    @State private var selectedDestination: DestinationRef?
    @State private var loadingDestinations = false
    @State private var destinationError: String?
    @State private var newAlbumName = ""
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(mapping == nil ? "Add Mapping" : "Edit Mapping").font(.title2.weight(.semibold)).padding()
            Divider()
            HStack(alignment: .top, spacing: 0) {
                sourcePane.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                destinationPane.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                if let summary { Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button(mapping == nil ? "Add" : "Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(source == nil || accountId == nil || selectedDestination == nil)
            }
            .padding()
        }
        .frame(width: 860, height: 600)
        .onAppear(perform: load)
    }

    // MARK: Source

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. Photos from").font(.headline)
            Picker("", selection: $sourceKind) {
                ForEach(SourceKind.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if sourceKind == .photos {
                if photosAllowed {
                    List(albumTree, children: \.children, selection: Binding(
                        get: { selectedAlbum?.id },
                        set: { id in selectedAlbum = id.flatMap(find) })) { node in
                        HStack {
                            Image(systemName: node.isFolder ? "folder" : "rectangle.stack")
                                .foregroundStyle(node.isFolder ? Color.secondary : Color.accentColor)
                            Text(node.title)
                            Spacer()
                            if let count = node.count { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
                        }
                        .selectionDisabled(node.isFolder)
                    }
                    .listStyle(.bordered)
                    Text("Photos only; videos are skipped. Edits are included. Add photos to the album in Photos, then Sync.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Photo Syncer needs permission to read your Photos library.")
                        Button("Allow Access to Photos") {
                            Task {
                                photosAllowed = await PhotosLibrary.requestAccess()
                                if photosAllowed { albumTree = PhotosLibrary.albumTree() }
                            }
                        }
                        Text("If nothing happens, allow it in System Settings › Privacy & Security › Photos.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } else {
                HStack {
                    TextField("Folder", text: $folderPath).textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseFolder)
                }
                Text("Every photo in the folder and its sub-folders. Hidden files and videos are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding()
    }

    private func find(_ id: String) -> PhotosAlbumNode? {
        func search(_ nodes: [PhotosAlbumNode]) -> PhotosAlbumNode? {
            for node in nodes {
                if node.id == id { return node.isFolder ? nil : node }
                if let found = search(node.children ?? []) { return found }
            }
            return nil
        }
        return search(albumTree)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: folderPath)
        if panel.runModal() == .OK, let url = panel.url { folderPath = url.path }
    }

    private var source: SourceRef? {
        switch sourceKind {
        case .photos:
            return selectedAlbum.map { .photosAlbum(localIdentifier: $0.id, title: $0.path) }
        case .folder:
            return folderPath.isEmpty ? nil : .folder(path: folderPath)
        }
    }

    // MARK: Destination

    private var account: Account? { accountId.flatMap(model.account) }

    private var destinationPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2. Goes to").font(.headline)
            Picker("Account", selection: $accountId) {
                Text("Choose an account").tag(UUID?.none)
                ForEach(model.config.accounts) { account in
                    Label(account.name, systemImage: account.service.icon).tag(UUID?.some(account.id))
                }
            }
            .onChange(of: accountId) { _, _ in
                selectedDestination = nil
                loadDestinations()
            }

            if account != nil {
                ZStack {
                    List(destinations, selection: Binding(
                        get: { selectedDestination?.id },
                        set: { id in selectedDestination = destinations.first { $0.id == id }?.ref })) { album in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(album.ref.name)
                                Spacer()
                                if let count = album.count { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
                            }
                            if let note = album.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                        }
                        .tag(album.id)
                    }
                    .listStyle(.bordered)
                    if loadingDestinations { ProgressView() }
                }
                if let destinationError {
                    Text(destinationError).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
                HStack {
                    TextField(account?.service == .folder ? "New sub-folder" : "New album name", text: $newAlbumName)
                        .textFieldStyle(.roundedBorder)
                    Button(creating ? "Creating…" : "Create", action: createAlbum)
                        .disabled(newAlbumName.trimmingCharacters(in: .whitespaces).isEmpty || creating)
                }
                if let hint = destinationHint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Spacer()
            }
        }
        .padding()
    }

    private var destinationHint: String? {
        switch account?.service {
        case .google: return "Google only lets apps add to albums they created, so create one here and choose it on your frame."
        case .pixstar: return "A frame syncs at most 3,000 photos per album. When this album is full, Photo Syncer starts \"<name> 2\"; add it to the frame's slideshow."
        case .amazon: return "Folder albums (made by uploading a folder) get photos uploaded into that folder."
        case .folder: return "Photos are copied as files, with an index.json listing them, newest first."
        default: return nil
        }
    }

    private func loadDestinations() {
        guard let account else { destinations = []; return }
        loadingDestinations = true
        destinationError = nil
        Task {
            do {
                destinations = try await model.makeService(account).albums()
                if let current = mapping?.destination, current.id == selectedDestination?.id || selectedDestination == nil,
                   mapping?.accountId == account.id {
                    selectedDestination = destinations.first { $0.id == current.id }?.ref ?? current
                }
            } catch {
                destinations = []
                destinationError = error.localizedDescription
            }
            loadingDestinations = false
        }
    }

    private func createAlbum() {
        guard let account else { return }
        let name = newAlbumName.trimmingCharacters(in: .whitespaces)
        creating = true
        Task {
            do {
                let ref = try await model.makeService(account).createAlbum(named: name)
                destinations.append(RemoteAlbum(ref: ref, count: 0))
                selectedDestination = ref
                newAlbumName = ""
            } catch {
                destinationError = error.localizedDescription
            }
            creating = false
        }
    }

    private var summary: String? {
        guard let source, let account, let selectedDestination else { return nil }
        return "\(source.displayName) → \(account.name) / \(selectedDestination.name)"
    }

    // MARK: Load and save

    private func load() {
        if photosAllowed { albumTree = PhotosLibrary.albumTree() }
        guard let mapping else {
            accountId = model.config.accounts.first?.id
            return
        }
        switch mapping.source {
        case .folder(let path):
            sourceKind = .folder
            folderPath = path
        case .photosAlbum(let id, let title):
            sourceKind = .photos
            selectedAlbum = find(id) ?? PhotosAlbumNode(id: id, title: title, path: title, count: nil, children: nil)
        }
        accountId = mapping.accountId
        selectedDestination = mapping.destination
    }

    private func commit() {
        guard let source, let accountId, let selectedDestination else { return }
        var result = mapping ?? Mapping(source: source, accountId: accountId, destination: selectedDestination)
        let changedTarget = result.accountId != accountId || result.destination.id != selectedDestination.id || result.source != source
        result.source = source
        result.accountId = accountId
        result.destination = selectedDestination
        if changedTarget && mapping != nil {
            // A different source or album: start its history afresh.
            result.overflowDestinations = []
            result.lastSynced = nil
            model.resetHistory(result)
        }
        model.upsertMapping(result)
        onClose()
    }
}
