import Foundation
@testable import MeetingNotes

struct HTTPClientStub: HTTPClient {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    let handler: Handler

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await handler(request)
    }
}
