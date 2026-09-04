import Foundation
import DunnageCore

/// The app's container: the three directories under Application Support, the copy a picked
/// file becomes, and the marker the terminate hook writes.
///
/// Application Support and not Caches, because Caches may be purged and a purged payload is
/// an upload that cannot move (spec §4.1). Everything the ledger, the payload copy and the
/// chunk files need is derived from `root`, so a container that moved is still readable:
/// `PayloadRef` is a path *relative* to `root` and never an absolute one (ADR-0007 §8).
///
/// **What is established where.** Only the copy is tier 1; the rest is a directory layout
/// the simulator test exercises whole.
///
/// - tier 1 (`DunnageAppTests`, no session and no socket):
///   `testPayloadRefNamesTheCopyInsideTheContainer` — the picked file is copied into the
///   container and `PayloadRef` names the copy, never the picker's security-scoped URL
///   (spec §4 rider b).
/// - simulator evidence (ADR-0007 §2, tier 2): that the ledger, the payload copy and the
///   chunk directory a killed process left are the ones the next process reads.
/// - device harness (ADR-0007 §2, tier 3): whether the background daemon can read the copy
///   after relaunch, or copies the file itself (O-15).
struct Container: Sendable {

    /// Application Support for this app, created if it is absent.
    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// The container the app runs in.
    static func applicationSupport() throws -> Container {
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Container(root: root)
    }

    var ledgerDirectory: URL { root.appendingPathComponent("ledger", isDirectory: true) }
    var partsDirectory: URL { root.appendingPathComponent("parts", isDirectory: true) }
    var payloadsDirectory: URL { root.appendingPathComponent("payloads", isDirectory: true) }

    /// The marker the terminate hook writes. **Evidence only when present**: a process
    /// killed before the hook ran and a hook that never runs leave the same missing file,
    /// so its absence says nothing about which signal ended the process (ADR-0007 O-14).
    var lastExitMarker: URL { root.appendingPathComponent("last-exit") }

    /// Where a `PayloadRef` points. The ref is a path relative to `root`, so this is the
    /// only place the two are joined.
    func resolve(_ payload: PayloadRef) -> URL {
        root.appendingPathComponent(payload.rawValue)
    }

    /// Copy `source` into the container and name the copy.
    ///
    /// The returned ref is relative to `root` and names the copy — never the URL the picker
    /// handed over, which is security-scoped, outside the container, and not something a
    /// background daemon is promised access to after a relaunch (spec §4 rider b, O-15).
    ///
    /// The name is the lowercase hex of the upload id's UTF-8, the ledger's own naming rule
    /// for the ledger's own reason (ADR-0004 §3): APFS is case-insensitive by default, and
    /// two uploads whose names differ only in case must not share a file.
    func adoptPayload(from source: URL, for upload: UploadID) throws -> PayloadRef {
        try FileManager.default.createDirectory(at: payloadsDirectory,
                                                withIntermediateDirectories: true)
        let name = Self.hex(upload)
        let copy = payloadsDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: copy.path) {
            try FileManager.default.removeItem(at: copy)
        }
        // The picker hands back a security-scoped URL; the scope is opened around the read
        // and closed after it, and nothing outside this call holds it.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: source, to: copy)
        return PayloadRef("payloads/" + name)
    }

    /// Read the marker the previous process left, and remove it, so a marker on the screen
    /// is one this launch's predecessor wrote and never one from further back.
    func takeLastExit() -> String? {
        guard let contents = try? String(contentsOf: lastExitMarker, encoding: .utf8) else {
            return nil
        }
        try? FileManager.default.removeItem(at: lastExitMarker)
        return contents
    }

    /// Write the marker. Called from `applicationWillTerminate` and nowhere else.
    func recordExit(_ note: String) {
        try? note.write(to: lastExitMarker, atomically: true, encoding: .utf8)
    }

    static func hex(_ upload: UploadID) -> String {
        upload.rawValue.utf8.map { String(format: "%02x", $0) }.joined()
    }
}
