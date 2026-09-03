import XCTest
import DunnageCore
@testable import DunnageTransport

/// A background task names one chunk of one upload, and a task this transport did not
/// name is never read as progress.
///
/// ADR-0007 §4: the description is a JSON object with sorted keys, because both the upload
/// id and the composed session identity may contain `/`, and a delimiter either side may
/// contain is a parse that is not total. Deterministic; nothing here touches a session.
final class TaskDescriptionTests: XCTestCase {

    /// Upload `a`, session `r/u`, chunk 3 encodes to exactly the string ADR-0007 §4 shows —
    /// keys sorted, the slash unescaped — and that string decodes back to the same value.
    func testATaskDescriptionRoundTripsAndItsKeysAreSorted() {
        let description = TaskDescription(upload: UploadID("a"),
                                          session: TransportSessionID("r/u"),
                                          chunk: ChunkID(3))
        XCTAssertEqual(description.encoded, #"{"chunk":3,"session":"r/u","upload":"a"}"#,
                       "the encoding is not the string ADR-0007 §4 shows")
        XCTAssertEqual(TaskDescription(decoding: description.encoded), description,
                       "the encoding did not decode to the value that produced it")
    }

    /// Eight strings this transport never minted: an empty object, a missing key, a chunk
    /// below one, a session identity that does not parse, a fourth key, a boolean chunk, a
    /// floating-point chunk, and a space. The last three would pass a field-by-field read
    /// through NSNumber bridging or a lenient parser; the rule that refuses them is not a
    /// list but an equality: a description is ours only if it is byte-for-byte the string
    /// this transport writes for those values. Each decodes to nothing, and the ones that
    /// did not are named.
    func testADescriptionThisTransportDidNotMintDecodesToNothing() {
        let notOurs = [
            #"{}"#,
            #"{"chunk":1,"upload":"a"}"#,
            #"{"chunk":0,"session":"r/u","upload":"a"}"#,
            #"{"chunk":1,"session":"nosep","upload":"a"}"#,
            #"{"chunk":1,"session":"r/u","upload":"a","x":1}"#,
            #"{"chunk":true,"session":"r/u","upload":"a"}"#,
            #"{"chunk":1.0,"session":"r/u","upload":"a"}"#,
            #"{"chunk":1, "session":"r/u","upload":"a"}"#,
        ]
        let survivors = notOurs.filter { TaskDescription(decoding: $0) != nil }
        XCTAssertEqual(survivors, [],
                       "a description this transport did not mint was read as one it did")
    }
}
