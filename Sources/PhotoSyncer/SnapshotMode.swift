import AppKit
import PhotoSyncerCore

/// For checking the window without screen-recording permission: with
/// PHOTO_SYNCER_SNAPSHOT=<folder> set, the app draws its window into PNGs (each pane,
/// then the Sync pane again after syncing everything) and quits. Use it together with
/// PHOTO_SYNCER_HOME so it runs against throwaway settings.
@MainActor
enum SnapshotMode {
    static func runIfRequested(_ model: AppModel) async {
        guard let folder = ProcessInfo.processInfo.environment["PHOTO_SYNCER_SNAPSHOT"], !folder.isEmpty else { return }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        for pane in Pane.allCases {
            model.pane = pane
            try? await Task.sleep(nanoseconds: 800_000_000)
            capture(to: out.appendingPathComponent("\(pane.rawValue).png"))
        }
        model.pane = .sync
        model.syncAll()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        capture(to: out.appendingPathComponent("sync-running.png"))
        while model.isSyncing { try? await Task.sleep(nanoseconds: 300_000_000) }
        try? await Task.sleep(nanoseconds: 800_000_000)
        capture(to: out.appendingPathComponent("sync-done.png"))
        NSApp.terminate(nil)
    }

    static func capture(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
