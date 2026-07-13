import Foundation

protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

enum HTTPClientError: Error, Equatable, Sendable {
    case nonHTTPResponse
    case unacceptableStatus(Int)
}
