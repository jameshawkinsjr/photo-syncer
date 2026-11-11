import PhotoSyncerCore
import SwiftUI

/// Every mapping, grouped by source, with its status and a Sync button.
struct SyncView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Mapping?
    @State private var adding = false

    private var groups: [(key: String, source: SourceRef, mappings: [Mapping])] {
        var order: [String] = []
        var bySource: [String: [Mapping]] = [:]
        for mapping in model.config.mappings {
            let key = mapping.source.groupKey
            if bySource[key] == nil { order.append(key) }
            bySource[key, default: []].append(mapping)
        }
        return order.map { ($0, bySource[$0]![0].source, bySource[$0]!) }
    }

    var body: some View {
        Group {
            if model.config.mappings.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(groups, id: \.key) { group in
                        Section {
                            ForEach(group.mappings) { mapping in
                                MappingRow(mapping: mapping, onEdit: { editing = mapping })
                            }
                        } header: {
                            Label(group.source.displayName, systemImage: sourceIcon(group.source))
                                .font(.headline)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }
        }
        .navigationTitle("Sync")
        .toolbar {
            ToolbarItem {
                Button { adding = true } label: { Label("Add Mapping", systemImage: "plus") }
                    .help("Choose a source and the album it goes to")
                    .disabled(model.config.accounts.isEmpty)
            }
        }
        .sheet(isPresented: $adding) {
            MappingEditor(mapping: nil) { adding = false }
        }
        .sheet(item: $editing) { mapping in
            MappingEditor(mapping: mapping) { editing = nil }
        }
    }

    private func sourceIcon(_ source: SourceRef) -> String {
        if case .photosAlbum = source { return "photo.on.rectangle" }
        return "folder"
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Nothing to sync yet").font(.title2.weight(.semibold))
            Text(model.config.accounts.isEmpty
                 ? "Start in Accounts: sign in to Amazon Photos, Google Photos or Pix-Star, or add a folder."
                 : "Add a mapping: a Photos album or folder, and the album it should go to.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if !model.config.accounts.isEmpty {
                Button("Add Mapping…") { adding = true }.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MappingRow: View {
    @EnvironmentObject var model: AppModel
    let mapping: Mapping
    let onEdit: () -> Void
    @State private var confirmingUpload = false

    private var status: MappingStatus { model.statuses[mapping.id] ?? MappingStatus() }
    private var account: Account? { model.account(mapping.accountId) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: account?.service.icon ?? "questionmark.circle")
                .font(.title2)
                .foregroundStyle(account?.service.tint ?? .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(mapping.allDestinations.map(\.name).joined(separator: " + ")).font(.body.weight(.semibold))
                    Text("on \(account?.name ?? "missing account")").foregroundStyle(.secondary)
                    if !mapping.enabled {
                        Text("Paused").font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                statusLine
                if let progress = status.progress {
                    VStack(alignment: .leading, spacing: 2) {
                        if progress.total > 0 {
                            ProgressView(value: Double(progress.done), total: Double(progress.total))
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                        Text(progress.total > 0 ? "\(progress.phase) \(progress.done) of \(progress.total)" + (progress.failed > 0 ? ", \(progress.failed) failed" : "") : progress.phase)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if case .needsReview(let plan) = status.outcome {
                    reviewBox(plan)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Button("Sync") { model.sync(mapping) }
                    .disabled(model.isSyncing || !mapping.enabled)
                Menu {
                    Button("Edit…", action: onEdit)
                    Button(mapping.enabled ? "Pause" : "Resume") {
                        var updated = mapping
                        updated.enabled.toggle()
                        model.upsertMapping(updated)
                    }
                    Divider()
                    Button("Mark Everything as Already Synced") { model.markAllSynced(mapping) }
                    Button("Forget Sync History") { model.resetHistory(mapping) }
                    Divider()
                    Button("Delete Mapping", role: .destructive) { model.removeMapping(mapping) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
                .disabled(model.isSyncing)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var statusLine: some View {
        let synced = status.syncedCount
        if let outcome = status.outcome {
            switch outcome {
            case .finished:
                Label(outcome.summary, systemImage: "checkmark.circle").foregroundStyle(.green).font(.callout)
            case .needsReview:
                Label("Waiting for you to choose how to start", systemImage: "hand.raised").foregroundStyle(.orange).font(.callout)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    .lineLimit(3).textSelection(.enabled)
            }
        } else if let last = mapping.lastSynced {
            Text("\(synced) photos synced · last sync \(last.relative)").font(.callout).foregroundStyle(.secondary)
        } else {
            Text("Never synced").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func reviewBox(_ plan: SyncPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("First sync: \(plan.sourceCount) photos in the source, \(plan.matched.count) found already in \(mapping.destination.name), **\(plan.toUpload.count) not found**.")
            Text(account?.service == .google
                 ? "Google Photos only lets Photo Syncer fill albums it created, so a new album starts empty: upload them."
                 : "If the destination already has them (under other names, or exported differently), mark them as synced and only new photos will go up from now on.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Upload \(plan.toUpload.count) Photos") { confirmingUpload = true }
                Button("They're Already There") { model.markAllSynced(mapping) }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .confirmationDialog("Upload \(plan.toUpload.count) photos to \(mapping.destination.name)?", isPresented: $confirmingUpload) {
            Button("Upload \(plan.toUpload.count) Photos") { model.sync(mapping, confirmed: true) }
        } message: {
            Text("This can take a while. You can stop it and pick up later; photos already uploaded aren't sent twice.")
        }
    }
}
