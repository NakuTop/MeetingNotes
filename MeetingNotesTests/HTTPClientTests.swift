import XCTest
@testable import MeetingNotes

final class HTTPClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testReturnsStubbedDataAndHTTPResponse() async throws {
        let client = makeClient()
        let url = try XCTUnwrap(URL(string: "https://api.example.com/v1/models"))
        let body = Data("{\"ok\":true}".utf8)
        URLProtocolStub.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["X-Request-ID": "request-1"]
            )!
            return (response, body)
        }

        let (data, response) = try await client.data(for: URLRequest(url: url))

        XCTAssertEqual(data, body)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "X-Request-ID"), "request-1")
    }

    func testNonSuccessStatusDoesNotExposeResponseBodySecret() async throws {
        let client = makeClient()
        let url = try XCTUnwrap(URL(string: "https://api.example.com/v1/models"))
        let secret = "body-contains-super-secret-token"
        URLProtocolStub.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(secret.utf8))
        }

        do {
            _ = try await client.data(for: URLRequest(url: url))
            XCTFail("Expected unacceptable status")
        } catch {
            XCTAssertEqual(error as? HTTPClientError, .unacceptableStatus(401))
            XCTAssertFalse(String(describing: error).contains(secret))
        }
    }

    private func makeClient() -> URLSessionHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        configuration.urlCache = nil
        return URLSessionHTTPClient(session: URLSession(configuration: configuration))
    }
}
