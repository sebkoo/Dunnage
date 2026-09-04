import XCTest
import DunnageCore
@testable import Dunnage

/// Tier 1 (ADR-0007 §2): no session, no socket, no clock. Everything here is a file copy
/// and a string.
final class ContainerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dunnage-container-tests-" + UUID().uuidString,
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Spec §4 rider (b): the file the user picks is copied into the container, and
    /// `PayloadRef` names the copy — never the picker's security-scoped URL, which is
    /// outside the container and which no background daemon is promised access to after a
    /// relaunch (ADR-0007 O-15).
    ///
    /// The ref is relative to Application Support so it survives the container moving
    /// (ADR-0007 §8), which is why the first assertion is about a leading separator.
    func testPayloadRefNamesTheCopyInsideTheContainer() throws {
        let container = Container(root: root)
        let upload = UploadID("an upload")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("dunnage-picked-" + UUID().uuidString)
        let bytes = Data("the bytes the user picked".utf8)
        try bytes.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let ref = try container.adoptPayload(from: outside, for: upload)
        let copy = container.resolve(ref)

        XCTAssertFalse(ref.rawValue.hasPrefix("/"),
                       "the ref is relative to Application Support, and '\(ref.rawValue)' is absolute")
        XCTAssertEqual(ref.rawValue, "payloads/" + Container.hex(upload),
                       "the ref names the copy under payloads/, by the ledger's hex naming rule")
        XCTAssertNotEqual(copy.standardizedFileURL, outside.standardizedFileURL,
                          "the ref resolved to the picked file itself, not to a copy")
        XCTAssertTrue(copy.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path),
                      "the copy is at \(copy.path), which is outside the container at \(root.path)")
        XCTAssertEqual(try Data(contentsOf: copy), bytes,
                       "the copy does not hold the bytes that were picked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path),
                      "the picked file was moved rather than copied")
    }
}
