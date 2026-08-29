import XCTest

extension XCTestCase {
    /// A directory of this test's own, removed when it ends.
    ///
    /// The name is random so that two tests never share one. Nothing asserted anywhere
    /// depends on it: a ledger is found by the identifier of the upload it holds, not by
    /// where the directory happens to be.
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dunnage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
