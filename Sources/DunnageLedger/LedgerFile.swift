import DunnageCore

/// The framing: how records are laid out in a file, and how a reader decides that one is
/// whole.
///
/// A record's completeness is answered by counting bytes, without parsing the payload. That
/// is what keeps a torn tail and a record from a newer build apart — if completeness meant
/// "the payload parses", the two would arrive as the same failure and one of them would
/// have to be guessed at. See ADR-0004 §2.
enum LedgerFile {

    static let suffix = ".ledger"

    private static let prefix = "dunnage-ledger "
    private static let newline = UInt8(ascii: "\n")
    private static let space = UInt8(ascii: " ")

    /// A ceiling on a frame's stated length, so that a length nothing wrote cannot ask the
    /// reader to index past the end of anything. Events are small; the largest is a
    /// declaration, and it is a few hundred bytes.
    private static let largestPayload = 1 << 22

    static let header = Array("\(prefix)\(LedgerFormat.version)\n".utf8)

    /// `<length> <payload>\n`. The length is written before the payload and the terminator
    /// after it, so a prefix of this is short in a way the reader can see.
    static func framed(_ event: UploadEvent) throws -> [UInt8] {
        let payload = try LedgerFormat.encode(event)
        return Array("\(payload.count) ".utf8) + payload + [newline]
    }

    /// Every record in `bytes`, in file order.
    ///
    /// Sequences are the records' positions. They are not written down: a stored sequence
    /// would be a second answer to a question that already has one, and then a rule for
    /// what to do when the two disagree.
    static func read(_ bytes: [UInt8], of upload: UploadID) throws -> [EventRecord] {
        var position = try endOfHeader(bytes)
        var records: [EventRecord] = []

        while position < bytes.count {
            guard let space = bytes[position...].firstIndex(of: space) else {
                throw LedgerError.incompleteRecord(atByteOffset: position)
            }
            guard let length = decimal(bytes[position..<space]), length <= largestPayload else {
                throw LedgerError.malformedFrame(atByteOffset: position)
            }
            let start = space + 1
            let end = start + length
            guard end < bytes.count else {
                throw LedgerError.incompleteRecord(atByteOffset: position)
            }
            // The payload's bytes were all there and the terminator is not. Nothing
            // truncated this, so it is not a tear.
            guard bytes[end] == newline else {
                throw LedgerError.malformedFrame(atByteOffset: position)
            }

            let sequence = LogSequence(records.count + 1)
            do {
                let event = try LedgerFormat.decode(Array(bytes[start..<end]))
                records.append(EventRecord(sequence: sequence, event: event))
            } catch let fault as RecordFault {
                throw LedgerError.unreadableRecord(upload: upload, sequence: sequence, fault: fault)
            }
            position = end + 1
        }
        return records
    }

    private static func endOfHeader(_ bytes: [UInt8]) throws -> Int {
        guard let end = bytes.firstIndex(of: newline) else {
            throw LedgerError.incompleteRecord(atByteOffset: 0)
        }
        let line = String(decoding: bytes[..<end], as: UTF8.self)
        guard line.hasPrefix(prefix), let version = Int(line.dropFirst(prefix.count)) else {
            throw LedgerError.unrecognizedFormat(header: line)
        }
        guard version == LedgerFormat.version else {
            throw LedgerError.unsupportedFormatVersion(version)
        }
        return end + 1
    }

    private static func decimal(_ digits: ArraySlice<UInt8>) -> Int? {
        guard !digits.isEmpty, digits.count <= 10 else { return nil }
        var value = 0
        for byte in digits {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return value
    }
}
