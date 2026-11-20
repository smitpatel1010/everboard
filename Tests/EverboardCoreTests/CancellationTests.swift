import Foundation
import Testing
@testable import EverboardCore

@Suite struct CancellationTests {
    /// A refresh cancels the polling task while it may be reloading from the store; the read then throws
    /// CancellationError. That's expected and must not be reported as a database problem.
    @Test func readInCancelledTaskThrowsCancellation() async throws {
        let store = try Store.inMemory()
        let task = Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await store.items(scopePrefix: "gitlab."); return nil } catch { return error }
        }
        let error = await task.value
        #expect(error is CancellationError)
    }
}
