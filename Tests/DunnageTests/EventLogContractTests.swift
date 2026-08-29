import XCTest
import DunnageCore

/// The contract, held against the in-memory double. A fake that does not keep it makes
/// every test built on it meaningless.
final class EventLogContractTests: XCTestCase {

    func testEventLogStoreAppendsMonotonicallyAndNeverAltersEarlierRecords() async throws {
        try await EventLogContract.appendsMonotonicallyAndNeverAltersEarlierRecords(InMemoryEventLog())
    }

    func testEventLogSequencesAreScopedToOneUpload() async throws {
        try await EventLogContract.sequencesAreScopedToOneUpload(InMemoryEventLog())
    }

    func testEventLogEnumeratesEveryUploadItHoldsAndIsEmptyForOnesItDoesNot() async throws {
        try await EventLogContract.enumeratesEveryUploadItHoldsAndIsEmptyForOnesItDoesNot(InMemoryEventLog())
    }
}
