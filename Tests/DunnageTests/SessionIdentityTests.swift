import XCTest
import DunnageCore
@testable import DunnageTransport

/// The Swift half of ADR-0006 §2: the composed identity is `<ref>/<uploadId>`, split on
/// the first separator, and exactly three inputs are not one this transport minted.
/// Deterministic; nothing here touches a session.
final class SessionIdentityTests: XCTestCase {

    /// `r/a/b` is ref `r` and uploadId `a/b`. An identity with two separators is not
    /// malformed: S3's upload id is an opaque token, and refusing a second `/` would encode
    /// a guess about a vendor's format. Composing the parts gives the identity back.
    func testASessionIdentitySplitsOnTheFirstSeparatorSoAnUploadIdMayContainOne() throws {
        let id = TransportSessionID("r/a/b")
        let identity = try SessionIdentity.parse(id)
        XCTAssertEqual(identity, SessionIdentity(ref: "r", uploadId: "a/b"),
                       "the split was not on the first separator")
        XCTAssertEqual(identity.composed, id, "composing the parts did not give the identity back")
    }

    /// No separator, an empty ref, an empty uploadId: each throws `.unrecognisedSession`,
    /// and the list is three because `openSession` always mints a well-formed one. The
    /// inputs that did not throw it are named.
    func testExactlyThreeInputsAreNotASessionThisTransportMinted() {
        let notOurs = ["nosep", "/u", "r/"]
        var accepted: [String] = []
        for raw in notOurs {
            do {
                _ = try SessionIdentity.parse(TransportSessionID(raw))
                accepted.append("\(raw): did not throw")
            } catch let error as TransportError where error == .unrecognisedSession {
                continue
            } catch {
                accepted.append("\(raw): threw \(error)")
            }
        }
        XCTAssertEqual(accepted, [], "an identity this transport never minted was accepted")
    }
}
