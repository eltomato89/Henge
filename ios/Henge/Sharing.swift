import SwiftUI
import UIKit

/// What a running Mac shares with this device: the Shared folder in Files, and the clipboard. The Mac mounts
/// the folder and follows the clipboard through a small helper (host/share.c, tools/henge-agent.m).
enum Sharing {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Shared", isDirectory: true)
    }

    static let setUpCommand = "curl -s http://10.0.2.4/.henge/install | sh"
    /// Less background work and drawing in macOS (host/share.c, lighten_script), and back.
    static let lightenCommand = "curl -s http://10.0.2.4/.henge/lighten | sh"
    static let unlightenCommand = "curl -s http://10.0.2.4/.henge/unlighten | sh"

    /* The served root. By default the Shared folder above. The person using Henge can instead
       pick any folder the Files picker can reach; the pick is kept as a security-scoped
       bookmark (no entitlement needed on iOS) and re-resolved on every prepare(). The grant
       is held for the whole session: the share server reads and writes under it the entire
       time the Mac is up, so it is released only when a different root replaces it. */
    private static let bookmarkKey = "henge.share.bookmark"
    private static var held: URL?

    /// Every folder this run of the app has served, in canonical spelling.
    private static var servedThisProcess: Set<String> = []
    private static var seededServedSet = false

    /// Where the app's own small files live; the remembered served folder
    /// is kept here, outside every folder that can be served.
    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// The folder the Mac will actually be served, and where it came from, for Settings to show.
    static var servedDescription: String {
        if let held { return "\(held.lastPathComponent) (a folder you picked)" }
        return "Shared (in Henge's Documents)"
    }

    static var hasChosenFolder: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    /// Resolve the stored pick without changing anything: no bookmark is
    /// re-made here, so comparing against the pick cannot alter it.
    private static func resolveChosenForComparison() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return url
    }

    /// The folder being served, for comparison: the one held for a session
    /// when there is one, else the stored pick resolved for this question
    /// alone, else the Shared folder.
    static var servedRoot: URL? {
        if let held { return held }
        if hasChosenFolder { return resolveChosenForComparison() }
        return folder
    }

    /// What one pass of the machine scan holds back, and why.
    static func guardEvaluation() -> ImportGuard.Evaluation {
        if !seededServedSet {
            seededServedSet = true
            if let root = servedRoot { servedThisProcess.insert(ImportGuard.canonical(root)) }
        }
        let data = UserDefaults.standard.data(forKey: bookmarkKey)
        let resolved = held ?? (data != nil ? resolveChosenForComparison() : nil)
        let record = ImportGuard.validRecord(appSupport: appSupport, currentBookmark: data)
        return ImportGuard.evaluate(hasBookmark: data != nil, resolvedRoot: resolved,
                                    fallbackRoot: folder, validRecord: record,
                                    thisProcessRoots: Array(servedThisProcess))
    }

    /// Whether automatic imports are running, held to the remembered
    /// folder, or paused because the pick cannot be opened.
    static var importState: ImportGuard.State { guardEvaluation().state }

    /// Resolve the stored pick, if any. A stale bookmark still resolves; it is re-minted while
    /// access is held so the next launch starts fresh. A pick that no longer resolves (the
    /// folder is gone) falls back to nil, and the caller serves the default rather than fail.
    // iOS bookmark form: the WithSecurityScope option flags are macOS-only (API_UNAVAILABLE
    // on iOS). A bookmark minted from a picker URL carries its scope implicitly, and
    // startAccessingSecurityScopedResource below is what brings the folder into scope.
    private static func resolveChosen() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    /// Keep a folder the person picked in the Files picker as the served root, from now on.
    static func choose(_ url: URL) {
        ImportGuard.invalidateRecord(appSupport: appSupport)
        let access = url.startAccessingSecurityScopedResource()
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        if !access { url.stopAccessingSecurityScopedResource() }
        prepare()
    }

    /// Back to the Shared folder.
    static func forgetChosen() {
        ImportGuard.invalidateRecord(appSupport: appSupport)
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        prepare()
    }

    /// Before a Mac starts, and again whenever the app comes back to the front: the share
    /// server is restarted on the current root (hv_share_start re-serves), so a pick made in
    /// Settings, or a grant that had to be re-resolved, takes effect without relaunching.
    static func prepare() {
        if let old = held { old.stopAccessingSecurityScopedResource(); held = nil }
        let root: URL
        var servedFromPick = false
        if let chosen = resolveChosen() {
            held = chosen
            root = chosen
            servedFromPick = true
        } else {
            root = folder
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        servedThisProcess.insert(ImportGuard.canonical(root))
        // A Unix socket's path can't be long, so the short temporary folder.
        let socket = (NSTemporaryDirectory() as NSString).appendingPathComponent("s.sock")
        henge_vm_share(root.path, socket, Bundle.main.path(forResource: "henge-agent", ofType: "gz"))
        // Only a folder actually served from the pick is remembered, and
        // the pick as it now stands is copied after resolving, so a pick
        // that was re-made while resolving is remembered as it stands.
        if servedFromPick, let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            ImportGuard.recordServedRoot(root, appSupport: appSupport, bookmarkSnapshot: data)
        }
    }

    /// The helper asks the server for news at most 25 s apart.
    static var helperRunning: Bool {
        let seen = henge_share_agent_seen()
        return seen >= 0 && seen < 40
    }

    /// What is copied on the Mac is copied here too. The other way needs the system's paste button: iOS
    /// asks for permission whenever an app reads the clipboard on its own.
    static func followMacClipboard() async {
        while !Task.isCancelled {
            if let text = henge_share_take_clipboard() {
                UIPasteboard.general.string = String(cString: text)
                free(text)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Text from this device, pasted at the Mac's cursor. Without the helper it is typed, as far as the keyboard can.
    static func paste(_ text: String) {
        Task { @MainActor in
            if helperRunning {
                henge_share_set_clipboard(text)
                try? await Task.sleep(nanoseconds: 800_000_000) // for the helper to put it on the Mac's clipboard
                Keys.chord(Keys.command, "v")
            } else {
                await Keys.typeSlowly(text)
            }
        }
    }

    /// Types the set up command at the Mac's cursor, and stops there: the person using the Mac presses Return.
    /// Henge can't see what has the keyboard, so it must not submit anything by itself. Opening Terminal for them
    /// through Spotlight was tried: when Spotlight was slow the text went to a web search, and it could as easily
    /// have gone to a chat.
    static func typeSetUpCommand() async {
        await Keys.typeSlowly(setUpCommand)
    }
}
