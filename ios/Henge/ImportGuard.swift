// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

/// Decides whether a folder found by the automatic machine scan may be
/// brought in on its own. A folder that sits in, or is, a folder served to
/// a Mac is not brought in automatically: what a Mac writes there must not
/// become a machine without the person using Henge choosing it. Choosing a
/// folder in the Files picker is that choice, and is never blocked here.
///
/// The last folder served from a pick is remembered in a small file of the
/// app's own, outside every folder that can be served, so that when a pick
/// can no longer be opened the scan still knows which folder to hold back.
/// When no remembered folder checks out, the scan holds everything back
/// for that pass rather than guess.
enum ImportGuard {
    // MARK: Canonical paths

    /// The one spelling of a path every comparison here uses.
    static func canonical(_ url: URL) -> String { canonicalPath(url.path) }

    static func canonicalPath(_ path: String) -> String {
        var p = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// True when the candidate is the root itself or sits inside it. The
    /// separator in the prefix test is what keeps a sibling whose name
    /// merely starts with the root's name from matching.
    static func isAtOrInsideCanonical(_ candidate: String, root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root + "/")
    }

    static func isAtOrInside(_ candidate: URL, root: URL) -> Bool {
        isAtOrInsideCanonical(canonical(candidate), root: canonical(root))
    }

    // MARK: The remembered served folder

    static let recordFileName = "ShareLastKnownRoot.plist"

    struct Record: Codable, Equatable {
        var version: Int
        var bookmarkSnapshot: Data
        var canonicalRoot: String
        var anchorVolume: UInt64
        var anchorFile: UInt64
    }

    static func recordURL(appSupport: URL) -> URL {
        appSupport.appendingPathComponent(recordFileName)
    }

    /// The pair of numbers that identifies a folder itself, apart from its
    /// path: a folder keeps them when it is renamed, and a new folder made
    /// at the same path does not share them.
    static func anchor(of url: URL) -> (volume: UInt64, file: UInt64)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let volume = (attrs[.systemNumber] as? NSNumber)?.uint64Value,
              let file = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
              volume != 0, file != 0 else { return nil }
        return (volume, file)
    }

    private static func flushDirectory(_ dir: URL) {
        let fd = open(dir.path, O_RDONLY)
        if fd >= 0 { fsync(fd); close(fd) }
    }

    /// Remembers a served folder. The file is replaced whole: written
    /// beside its final place, flushed, then renamed over it in a
    /// single step, so a reader only ever sees a complete record or
    /// the previous one. When the
    /// folder's identifying numbers cannot be read, nothing is written:
    /// a record that cannot be checked later must not be trusted later.
    @discardableResult
    static func recordServedRoot(_ root: URL, appSupport: URL, bookmarkSnapshot: Data) -> Bool {
        guard let anchor = anchor(of: root) else { return false }
        let record = Record(version: 1, bookmarkSnapshot: bookmarkSnapshot,
                            canonicalRoot: canonical(root),
                            anchorVolume: anchor.volume, anchorFile: anchor.file)
        guard let data = try? PropertyListEncoder().encode(record) else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let target = recordURL(appSupport: appSupport)
        let temp = appSupport.appendingPathComponent(recordFileName + ".writing")
        do {
            try data.write(to: temp)
            let handle = try FileHandle(forWritingTo: temp)
            try handle.synchronize()
            try handle.close()
            // One rename over the previous record: the name is replaced
            // as a single step, so a reader sees the previous complete
            // record or the new one, and a failure here leaves the
            // previous record in place rather than no record at all.
            guard rename(temp.path, target.path) == 0 else {
                try? fm.removeItem(at: temp)
                return false
            }
            flushDirectory(appSupport)
            return true
        } catch {
            try? fm.removeItem(at: temp)
            return false
        }
    }

    /// Forgets the remembered folder, when a pick is made or given up. If
    /// the file cannot be removed it is replaced with one that can never
    /// check out, because its remembered pick matches no stored pick.
    static func invalidateRecord(appSupport: URL) {
        let fm = FileManager.default
        let target = recordURL(appSupport: appSupport)
        guard fm.fileExists(atPath: target.path) else { return }
        do {
            try fm.removeItem(at: target)
            flushDirectory(appSupport)
        } catch {
            let tombstone = Record(version: 1, bookmarkSnapshot: Data(),
                                   canonicalRoot: "", anchorVolume: 0, anchorFile: 0)
            if let data = try? PropertyListEncoder().encode(tombstone) {
                try? data.write(to: target, options: .atomic)
            }
            flushDirectory(appSupport)
        }
    }

    /// The remembered folder, only when every check holds: the file reads
    /// as a complete record of the current form, it describes the pick
    /// currently stored (byte for byte), the folder at its path is still
    /// the same folder that was served, and its path is already in
    /// canonical spelling. Any doubt at all means there is no record.
    static func validRecord(appSupport: URL, currentBookmark: Data?) -> Record? {
        guard let currentBookmark,
              let data = try? Data(contentsOf: recordURL(appSupport: appSupport)),
              let record = try? PropertyListDecoder().decode(Record.self, from: data),
              record.version == 1,
              record.bookmarkSnapshot == currentBookmark,
              !record.canonicalRoot.isEmpty,
              record.anchorVolume != 0, record.anchorFile != 0,
              let now = anchor(of: URL(fileURLWithPath: record.canonicalRoot)),
              now.volume == record.anchorVolume, now.file == record.anchorFile,
              canonicalPath(record.canonicalRoot) == record.canonicalRoot
        else { return nil }
        return record
    }

    // MARK: One pass of the scan

    enum State: Equatable { case normal, seeded, blanket }

    struct Evaluation: Equatable {
        var refusalRoots: [String]
        var state: State
        var refusesEverything: Bool { state == .blanket }
        func refuses(_ candidate: URL) -> Bool {
            if refusesEverything { return true }
            let c = canonical(candidate)
            return refusalRoots.contains { isAtOrInsideCanonical(c, root: $0) }
        }
    }

    /// Works out what one pass of the scan holds back. When a pick is
    /// stored but cannot be opened, the remembered folder joins the held
    /// roots when it checks out; when it does not, the pass holds
    /// everything back. That state is worked out fresh on every pass and
    /// is never stored, so it ends by itself as soon as the pick can be
    /// opened again, is replaced, or is given up.
    static func evaluate(hasBookmark: Bool, resolvedRoot: URL?, fallbackRoot: URL,
                         validRecord: Record?, thisProcessRoots: [String]) -> Evaluation {
        var roots = thisProcessRoots
        if let resolvedRoot {
            let r = canonical(resolvedRoot)
            if !roots.contains(r) { roots.append(r) }
            return Evaluation(refusalRoots: roots, state: .normal)
        }
        // No root resolved: the default folder is the root that will be
        // served for this pass, so it joins the held roots here and only
        // here. When a pick is served, the default folder is held back
        // only if this process actually served it (it is then already
        // in thisProcessRoots).
        let fallback = canonical(fallbackRoot)
        if !roots.contains(fallback) { roots.append(fallback) }
        guard hasBookmark else { return Evaluation(refusalRoots: roots, state: .normal) }
        if let validRecord {
            if !roots.contains(validRecord.canonicalRoot) { roots.append(validRecord.canonicalRoot) }
            return Evaluation(refusalRoots: roots, state: .seeded)
        }
        return Evaluation(refusalRoots: roots, state: .blanket)
    }
}
