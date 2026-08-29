import Foundation
import DunnageCore

/// `UploadEventLog`, on a file. The implementation that outlives the process that wrote it.
///
/// One file per upload, so that reading one upload's log reads one file and one upload's
/// writes never move another upload's bytes. The file is named by the lowercase hex of the
/// identifier's UTF-8: APFS is case-insensitive by default, and a case-sensitive encoding
/// can therefore give two uploads one file. base64url writes `man` as `bWFu` and `maT` as
/// `bWFU`, which differ only in the case of one character. Hex has no upper case to fold.
///
/// The protocol is unchanged. Nothing here needed a method the in-memory implementation did
/// not have, which is the claim ADR-0004 makes about the boundary having been drawn in the
/// right place.
public actor FileEventLog: UploadEventLog {

    private let directory: URL
    private let files = FileManager()

    public init(directory: URL) {
        self.directory = directory
    }

    @discardableResult
    public func append(_ events: [UploadEvent], for upload: UploadID) throws -> [EventRecord] {
        let file = try url(for: upload)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)

        // Read before writing. The sequence a record gets is its position, so the writer has
        // to know what is already there — and a log this binary cannot read is one it must
        // not append to, because the events it would write are derived from a state it
        // cannot derive.
        let existing: [EventRecord]
        if files.fileExists(atPath: file.path) {
            existing = try LedgerFile.read([UInt8](try Data(contentsOf: file)), of: upload)
        } else {
            guard files.createFile(atPath: file.path, contents: Data(LedgerFile.header)) else {
                throw LedgerError.couldNotCreateLedger(upload)
            }
            existing = []
        }

        var bytes: [UInt8] = []
        var appended: [EventRecord] = []
        for (offset, event) in events.enumerated() {
            bytes.append(contentsOf: try LedgerFile.framed(event))
            appended.append(EventRecord(sequence: LogSequence(existing.count + offset + 1),
                                        event: event))
        }

        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(bytes))
        // The strongest durability action available from user space, and the reason this
        // phase exists. That it survives a power loss is a claim about the device, and no
        // test in this repository makes it. See the honesty boundary in ADR-0004.
        try handle.synchronize()

        return appended
    }

    public func records(for upload: UploadID) throws -> [EventRecord] {
        let file = try url(for: upload)
        guard files.fileExists(atPath: file.path) else { return [] }
        return try LedgerFile.read([UInt8](try Data(contentsOf: file)), of: upload)
    }

    public func uploads() throws -> [UploadID] {
        guard files.fileExists(atPath: directory.path) else { return [] }
        var found: [UploadID] = []
        for name in try files.contentsOfDirectory(atPath: directory.path).sorted()
        where name.hasSuffix(LedgerFile.suffix) {
            guard let upload = Self.upload(named: name) else {
                throw LedgerError.unrecognizedLedgerFile(name: name)
            }
            found.append(upload)
        }
        return found
    }

    // MARK: - Naming

    private static let hexDigits = Array("0123456789abcdef".utf8)

    private func url(for upload: UploadID) throws -> URL {
        var name = [UInt8]()
        name.reserveCapacity(upload.rawValue.utf8.count * 2)
        for byte in upload.rawValue.utf8 {
            name.append(Self.hexDigits[Int(byte >> 4)])
            name.append(Self.hexDigits[Int(byte & 0x0f)])
        }
        let file = String(decoding: name, as: UTF8.self) + LedgerFile.suffix
        guard file.utf8.count <= 255 else {
            throw LedgerError.uploadIdentifierTooLongForAFilename(upload)
        }
        return directory.appendingPathComponent(file)
    }

    private static func upload(named name: String) -> UploadID? {
        let hex = Array(name.dropLast(LedgerFile.suffix.count).utf8)
        guard hex.count.isMultiple(of: 2) else { return nil }

        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        for pair in stride(from: 0, to: hex.count, by: 2) {
            guard let high = nibble(hex[pair]), let low = nibble(hex[pair + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        // Lower case only: this module writes no other, so a name with upper case in it is
        // not one of ours however well it decodes.
        return String(bytes: bytes, encoding: .utf8).map(UploadID.init)
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }
}
