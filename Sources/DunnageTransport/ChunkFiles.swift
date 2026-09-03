import Foundation
import DunnageCore

/// The chunk files: one file per in-flight chunk, holding exactly the span the plan names.
///
/// A cache, and nothing else. Each file is derived from two things the log already knows —
/// the intent's `PayloadRef` and the plan's range for the chunk — so deleting any of them is
/// always safe: the next `send` re-derives it. A chunk file is written at `send` and
/// deleted when the authority confirms the chunk, not when a completion reports it, and the
/// files that exist at once are therefore bounded by the in-flight set. That sentence is
/// both the cache's lifecycle and its disk bound (ADR-0007 §7).
///
/// The layout is `<directory>/<hex of the upload id's UTF-8>/<ordinal>` — the ledger's
/// naming rule, for the ledger's reason (ADR-0004 §3): APFS is case-insensitive by
/// default, and two uploads whose names differ only in case must not share a directory.
///
/// This reads `intent.payload` and `intent.upload` and nothing else about the intent. It
/// holds no clock and no entropy. Every error is thrown except the read handle's close,
/// which nothing depends on.
public struct ChunkFiles: Sendable {

    /// What can go wrong that the file system does not already name.
    public enum Failure: Error, Hashable, Sendable {
        /// The payload ended before the span the plan names. The plan was made against a
        /// payload of a different length, and a chunk file written short would be sent
        /// as if it were whole.
        case payloadShorterThanThePlan(PayloadRef, ChunkID, expected: Int, read: Int)
        /// The atomic rename that publishes a chunk file failed, with the `errno` it gave.
        case couldNotPublish(ChunkID, errno: Int32)
    }

    private let directory: URL
    private let resolve: @Sendable (PayloadRef) -> URL

    /// `resolve` is the app's: a `PayloadRef` is a path relative to Application Support,
    /// and only the app knows where that is (ADR-0007 §8).
    public init(directory: URL, resolve: @escaping @Sendable (PayloadRef) -> URL) {
        self.directory = directory
        self.resolve = resolve
    }

    /// The chunk file for this transfer, written if it is absent.
    ///
    /// Exactly `transfer.range` of the resolved payload, and no more: a trailing partial
    /// chunk holds what is left, not a padded chunk. Written to `<ordinal>.tmp` and renamed
    /// into place, so a file that exists under the ordinal's name is always whole.
    public func file(for transfer: PlannedTransfer, of intent: UploadIntent) throws -> URL {
        let uploadDirectory = self.uploadDirectory(intent.upload)
        let file = uploadDirectory.appendingPathComponent(String(transfer.chunk.ordinal))
        if FileManager.default.fileExists(atPath: file.path) { return file }

        try FileManager.default.createDirectory(at: uploadDirectory,
                                                withIntermediateDirectories: true)

        let payload = try FileHandle(forReadingFrom: resolve(intent.payload))
        defer { try? payload.close() }
        try payload.seek(toOffset: UInt64(transfer.range.start.value))
        let span = try payload.read(upToCount: transfer.range.count) ?? Data()
        guard span.count == transfer.range.count else {
            throw Failure.payloadShorterThanThePlan(intent.payload, transfer.chunk,
                                                    expected: transfer.range.count,
                                                    read: span.count)
        }

        let staging = uploadDirectory.appendingPathComponent("\(transfer.chunk.ordinal).tmp")
        try span.write(to: staging)
        // rename(2) replaces atomically, so a reader never sees a chunk file half written.
        guard rename(staging.path, file.path) == 0 else {
            throw Failure.couldNotPublish(transfer.chunk, errno: errno)
        }
        return file
    }

    /// Delete the chunk files the authority has confirmed. A file that is not there is not
    /// an error: a confirmation can name a chunk whose file this process never wrote.
    public func discard(_ confirmed: Set<ChunkID>, of upload: UploadID) throws {
        let uploadDirectory = self.uploadDirectory(upload)
        for chunk in confirmed {
            let file = uploadDirectory.appendingPathComponent(String(chunk.ordinal))
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            try FileManager.default.removeItem(at: file)
        }
    }

    /// Delete the upload's whole directory. Absent is not an error, for the same reason.
    public func remove(_ upload: UploadID) throws {
        let uploadDirectory = self.uploadDirectory(upload)
        guard FileManager.default.fileExists(atPath: uploadDirectory.path) else { return }
        try FileManager.default.removeItem(at: uploadDirectory)
    }

    /// The chunks whose files exist now. A staged `.tmp` is not a chunk file, and an
    /// upload with no directory has none.
    public func present(for upload: UploadID) throws -> Set<ChunkID> {
        let uploadDirectory = self.uploadDirectory(upload)
        guard FileManager.default.fileExists(atPath: uploadDirectory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: uploadDirectory.path)
        return Set(names.compactMap { Int($0) }.filter { $0 >= 1 }.map(ChunkID.init))
    }

    private func uploadDirectory(_ upload: UploadID) -> URL {
        let hex = upload.rawValue.utf8.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hex, isDirectory: true)
    }
}
