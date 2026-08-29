import Foundation
import DunnageCore

/// A ledger with no completeness marker.
///
/// This is not a strawman. It is the shape a simple append-only log usually takes: one
/// record per line, fields separated by spaces, read with `split(separator: "\n")`. It keeps
/// the `UploadEventLog` contract — there is a test — and it refuses a line it cannot parse
/// rather than stepping over it, which is the charitable version of the design.
///
/// What it does not have is any way to say that a record is *finished*. The end of the file
/// is the end of the last record, so a write that stopped half way through one is a record
/// as far as this reader is concerned. `NegativeControlTests` is what that costs.
///
/// A note on why the payload is tokens and not JSON, because it matters to whether the
/// control is fair: JSON is self-delimiting, so a truncated object usually fails to parse
/// and a newline-framed JSON log resists this by accident. That resistance is a property of
/// the encoding, not of the design — swap the payload for anything positional and it is
/// gone, with nothing anywhere recording that it was load-bearing. A ledger that relies on
/// its payload encoding to notice a tear has not decided anything.
actor MarkerlessEventLog: UploadEventLog {

    static let suffix = ".markerless"

    struct Unreadable: Error { let line: String }

    private let directory: URL
    private let files = FileManager()

    init(directory: URL) {
        self.directory = directory
    }

    @discardableResult
    func append(_ events: [UploadEvent], for upload: UploadID) throws -> [EventRecord] {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = url(for: upload)
        if !files.fileExists(atPath: file.path) {
            files.createFile(atPath: file.path, contents: Data())
        }

        let existing = try records(for: upload).count
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for event in events {
            try handle.write(contentsOf: Data((line(for: event) + "\n").utf8))
        }
        try handle.synchronize()

        return events.enumerated().map {
            EventRecord(sequence: LogSequence(existing + $0.offset + 1), event: $0.element)
        }
    }

    func records(for upload: UploadID) throws -> [EventRecord] {
        let file = url(for: upload)
        guard files.fileExists(atPath: file.path) else { return [] }
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)

        // The end of the file is the end of a record. There is nothing else it could be:
        // no length was written down, and nothing says a line is finished.
        return try text.split(separator: "\n").enumerated().map { position, line in
            EventRecord(sequence: LogSequence(position + 1), event: try event(from: String(line)))
        }
    }

    func uploads() throws -> [UploadID] {
        guard files.fileExists(atPath: directory.path) else { return [] }
        return try files.contentsOfDirectory(atPath: directory.path).sorted()
            .filter { $0.hasSuffix(Self.suffix) }
            .compactMap { name in
                let hex = Array(name.dropLast(Self.suffix.count).utf8)
                var bytes = [UInt8]()
                for pair in stride(from: 0, to: hex.count, by: 2) {
                    bytes.append(nibble(hex[pair]) << 4 | nibble(hex[pair + 1]))
                }
                return String(bytes: bytes, encoding: .utf8).map(UploadID.init)
            }
    }

    // MARK: - One record, one line of tokens

    private func line(for event: UploadEvent) -> String {
        switch event {
        case .declared(let intent):
            let policy = intent.policy
            return ["declared", intent.upload.rawValue, intent.destination.rawValue,
                    "\(policy.maxAttemptsPerChunk)",
                    "\(policy.initialBackoff.components.seconds)",
                    "\(policy.initialBackoff.components.attoseconds)",
                    "\(policy.maximumBackoff.components.seconds)",
                    "\(policy.maximumBackoff.components.attoseconds)",
                    "\(intent.plan.chunkSize)", "\(intent.plan.totalBytes)"].joined(separator: " ")
        case .transportSessionOpened(let session):
            return "transportSessionOpened \(session.rawValue)"
        case .chunkTransferReported(let chunk):
            return "chunkTransferReported \(chunk.ordinal)"
        case .chunkTransferRefused(let chunk):
            return "chunkTransferRefused \(chunk.ordinal)"
        case .chunkTransferInterrupted(let chunk):
            return "chunkTransferInterrupted \(chunk.ordinal)"
        case .authorityReported(let confirmation):
            let head = "authorityReported \(confirmation.upload.rawValue) \(confirmation.session.rawValue)"
            switch confirmation.progress {
            case .offset(let offset):
                return "\(head) offset \(offset.value)"
            case .chunks(let chunks):
                return ([head, "chunks"] + chunks.map(\.ordinal).sorted().map(String.init))
                    .joined(separator: " ")
            }
        case .finalized:
            return "finalized"
        case .abandoned(let reason):
            switch reason {
            case .retriesExhausted: return "abandoned retriesExhausted"
            case .taskCancelled:    return "abandoned taskCancelled"
            case .systemTerminated: return "abandoned systemTerminated"
            case .userForceQuit:    return "abandoned userForceQuit"
            }
        }
    }

    private func event(from line: String) throws -> UploadEvent {
        let token = line.split(separator: " ").map(String.init)
        func fail() -> Unreadable { Unreadable(line: line) }

        switch token.first {
        case "declared":
            guard token.count == 10, let attempts = Int(token[3]),
                  let initialSeconds = Int64(token[4]), let initialAttoseconds = Int64(token[5]),
                  let maximumSeconds = Int64(token[6]), let maximumAttoseconds = Int64(token[7]),
                  let chunkSize = Int(token[8]), let totalBytes = Int(token[9]),
                  attempts >= 1, chunkSize > 0, totalBytes >= 0 else { throw fail() }
            return .declared(UploadIntent(
                upload: UploadID(token[1]),
                destination: DestinationRef(token[2]),
                plan: ChunkPlan(totalBytes: totalBytes, chunkSize: chunkSize),
                policy: RetryPolicy(
                    maxAttemptsPerChunk: attempts,
                    initialBackoff: Duration(secondsComponent: initialSeconds,
                                             attosecondsComponent: initialAttoseconds),
                    maximumBackoff: Duration(secondsComponent: maximumSeconds,
                                             attosecondsComponent: maximumAttoseconds))))

        case "transportSessionOpened":
            guard token.count == 2 else { throw fail() }
            return .transportSessionOpened(TransportSessionID(token[1]))

        case "chunkTransferReported":   return .chunkTransferReported(try chunk(token))
        case "chunkTransferRefused":    return .chunkTransferRefused(try chunk(token))
        case "chunkTransferInterrupted": return .chunkTransferInterrupted(try chunk(token))

        case "authorityReported":
            guard token.count >= 5 else { throw fail() }
            let progress: ConfirmedProgress
            switch token[3] {
            case "offset":
                guard token.count == 5, let value = Int(token[4]), value >= 0 else { throw fail() }
                progress = .offset(ByteOffset(value))
            case "chunks":
                let ordinals = token.dropFirst(4).compactMap(Int.init)
                guard ordinals.count == token.count - 4, ordinals.allSatisfy({ $0 >= 1 }) else { throw fail() }
                progress = .chunks(Set(ordinals.map(ChunkID.init)))
            default:
                throw fail()
            }
            return .authorityReported(Confirmation(upload: UploadID(token[1]),
                                                   session: TransportSessionID(token[2]),
                                                   progress: progress))

        case "finalized":
            guard token.count == 1 else { throw fail() }
            return .finalized

        case "abandoned":
            guard token.count == 2 else { throw fail() }
            switch token[1] {
            case "retriesExhausted": return .abandoned(.retriesExhausted)
            case "taskCancelled":    return .abandoned(.taskCancelled)
            case "systemTerminated": return .abandoned(.systemTerminated)
            case "userForceQuit":    return .abandoned(.userForceQuit)
            default:                 throw fail()
            }

        default:
            throw fail()
        }
    }

    private func chunk(_ token: [String]) throws -> ChunkID {
        guard token.count == 2, let ordinal = Int(token[1]), ordinal >= 1 else {
            throw Unreadable(line: token.joined(separator: " "))
        }
        return ChunkID(ordinal)
    }

    // MARK: - Naming, the same rule the framed ledger uses

    private func url(for upload: UploadID) -> URL {
        let digits = Array("0123456789abcdef".utf8)
        var name = [UInt8]()
        for byte in upload.rawValue.utf8 {
            name.append(digits[Int(byte >> 4)])
            name.append(digits[Int(byte & 0x0f)])
        }
        return directory.appendingPathComponent(String(decoding: name, as: UTF8.self) + Self.suffix)
    }

    private func nibble(_ byte: UInt8) -> UInt8 {
        byte <= UInt8(ascii: "9") ? byte - UInt8(ascii: "0") : byte - UInt8(ascii: "a") + 10
    }
}
