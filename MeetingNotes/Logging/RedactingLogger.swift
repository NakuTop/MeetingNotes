import Foundation
import OSLog

enum NetworkErrorCategory: String, Equatable, Sendable {
    case invalidRequest
    case transport
    case timeout
    case unauthorized
    case rateLimited
    case server
    case decoding
}

struct NetworkLogEvent: Equatable, Sendable {
    let requestID: UUID
    let statusCode: Int?
    let path: String
    let errorCategory: NetworkErrorCategory?
}

struct RedactingLogger: Sendable {
    private let logger: Logger

    init(subsystem: String, category: String) {
        logger = Logger(subsystem: subsystem, category: category)
    }

    func log(_ event: NetworkLogEvent) {
        logger.info("\(message(for: event), privacy: .public)")
    }

    func message(for event: NetworkLogEvent) -> String {
        let status = event.statusCode.map(String.init) ?? "none"
        let category = event.errorCategory?.rawValue ?? "none"
        return [
            "request_id=\(event.requestID.uuidString)",
            "status=\(status)",
            "path=\(safePath(event.path))",
            "error=\(category)"
        ].joined(separator: " ")
    }

    private func safePath(_ value: String) -> String {
        if let components = URLComponents(string: value),
           !components.path.isEmpty {
            return components.path
        }

        return String(value.split(separator: "?", maxSplits: 1)[0])
            .split(separator: "#", maxSplits: 1)
            .first
            .map(String.init) ?? "/"
    }
}
