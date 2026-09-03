import DunnageTransport

/// The control plane, as scripted data: a closure the test hands in. The canned answers
/// and the request journal are locals of the test that built the closure; this wrapper
/// holds no state and keeps no contract beyond returning what it was handed, so it is not
/// a double and has no contract test (ADR-0007 §2's table names the pure half instead).
struct CannedPlane: PlaneExchange {
    let perform: @Sendable (PlaneRequest) async throws -> PlaneResponse

    func perform(_ request: PlaneRequest) async throws -> PlaneResponse {
        try await perform(request)
    }
}
