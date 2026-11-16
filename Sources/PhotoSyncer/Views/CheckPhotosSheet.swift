import PhotoSyncerCore
import SwiftUI

/// Check Photos: for photos a frame shows wrongly (black, say), looks at the source files from
/// the days given and at the copies the app would upload, and lets the person have chosen
/// photos uploaded again once they've deleted the bad copies from the service.
struct CheckPhotosSheet: View {
    @EnvironmentObject var model: AppModel
    let mapping: Mapping
    let onClose: () -> Void

    @State private var daysText = ""
    @State private var checks: [PhotoCheck] = []
    @State private var selected: Set<String> = []
    @State private var running: String?
    @State private var task: Task<Void, Never>?
    @State private var message: String?
    @State private var confirming = false

    private var account: Account? { model.account(mapping.accountId) }
    private var days: [DateComponents]? { PhotoDiagnostics.days(from: daysText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check Photos").font(.title2.weight(.semibold))
            Text("Looks at the photos in \(mapping.source.displayName) taken on these days (and the day either side), and at the copies Photo Syncer would upload to \(mapping.destination.name). Nothing is uploaded; what it finds also goes to the log.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Days, like 2024-06-01, 2024-06-15", text: $daysText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(run)
                if running != nil {
                    Button("Stop") { task?.cancel() }
                } else {
                    Button("Check", action: run).disabled(days == nil)
                }
            }
            if let running {
                HStack { ProgressView().controlSize(.small); Text(running).font(.caption).foregroundStyle(.secondary) }
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !checks.isEmpty {
                List(checks) { check in
                    CheckRow(check: check, isSelected: Binding(
                        get: { selected.contains(check.key) },
                        set: { if $0 { selected.insert(check.key) } else { selected.remove(check.key) } }))
                }
                .frame(minHeight: 260)
                Text("If any of these show wrongly on the frame: delete them from \(mapping.destination.name) in \(account?.service.displayName ?? "the service") first (Photo Syncer never deletes anything), tick them here and choose Upload Again. The next sync sends fresh copies made as shown under “Upload”.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if !checks.isEmpty {
                    Button("Upload \(selected.count) Again…") { confirming = true }
                        .disabled(selected.isEmpty || model.isSyncing || running != nil)
                }
                Spacer()
                Button("Close") { task?.cancel(); onClose() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .confirmationDialog("Upload \(selected.count) photos again to \(mapping.destination.name)?", isPresented: $confirming) {
            Button("Upload Again on the Next Sync") { uploadAgain() }
        } message: {
            Text("Delete the bad copies from \(mapping.destination.name) first: the new copies are different files, so any old copy left there stays as a second copy.")
        }
    }

    private func run() {
        guard let days, running == nil, let account else { return }
        checks = []
        selected = []
        message = nil
        running = "Starting…"
        let engine = model.engine!
        let mapping = mapping
        task = Task {
            if case .photosAlbum = mapping.source { _ = await PhotosLibrary.requestAccess() }
            do {
                let result = try await Task.detached {
                    try await engine.checkPhotos(mapping, account: account, days: days, progress: { text in
                        Task { @MainActor in if running != nil { running = text } }
                    })
                }.value
                checks = result
                selected = Set(result.filter { PhotoDiagnostics.isOn($0.date, days) }.map(\.key))
                let bad = result.filter { !$0.isOK }.count
                let risky = result.filter { !$0.risks.isEmpty }.count
                message = result.isEmpty
                    ? "No photos in \(mapping.source.shortName) were taken within a day of those dates."
                    : "\(result.count) photos. \(risky) have something in the original a simple frame may show wrongly (listed in orange); "
                        + (bad == 0 ? "every copy Photo Syncer would upload now is a plain JPEG that isn't black." : "\(bad) would still upload with a problem (in red).")
            } catch is CancellationError {
                message = "Stopped."
            } catch {
                message = error.localizedDescription
            }
            running = nil
            task = nil
        }
    }

    private func uploadAgain() {
        model.uploadAgain(Array(selected), in: mapping)
        message = "\(selected.count) photos will be uploaded on the next sync of this mapping."
        selected = []
    }
}

private struct CheckRow: View {
    let check: PhotoCheck
    @Binding var isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: $isSelected).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(check.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "No date").font(.body.weight(.semibold))
                    Text(".\(check.fileExtension)").foregroundStyle(.secondary)
                    if let state = check.ledgerState {
                        Text(state == .uploaded ? "uploaded by Photo Syncer" : "already there before")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Photo: " + (check.original?.summary ?? "couldn't be read")).font(.caption)
                if !check.risks.isEmpty {
                    Text("May trip up a frame: " + check.risks.joined(separator: "; ")).font(.caption).foregroundStyle(.orange)
                }
                if let upload = check.upload {
                    Text("Upload: " + upload.summary + (check.redated ? ", library date written in" : "")).font(.caption)
                }
                if check.isOK {
                    Label("Uploads as a plain JPEG", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                } else {
                    Label(check.problems.joined(separator: "; "), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                }
            }
            .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}
