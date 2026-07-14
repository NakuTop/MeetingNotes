import Foundation

enum NotionPageLinkParser {
    static func parse(_ rawValue: String) -> UUID? {
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              host == "notion.so"
                  || host == "www.notion.so"
                  || host == "app.notion.com",
              let lastComponent = components.path
                .split(separator: "/", omittingEmptySubsequences: true)
                .last else {
            return nil
        }

        let component = String(lastComponent).removingPercentEncoding
            ?? String(lastComponent)
        if component.count >= 36,
           let uuid = UUID(uuidString: String(component.suffix(36))) {
            return uuid
        }

        guard component.count >= 32 else {
            return nil
        }
        let compactID = String(component.suffix(32))
        guard compactID.unicodeScalars.allSatisfy(isASCIIHexDigit) else {
            return nil
        }

        let characters = Array(compactID)
        let normalized = [
            String(characters[0..<8]),
            String(characters[8..<12]),
            String(characters[12..<16]),
            String(characters[16..<20]),
            String(characters[20..<32])
        ].joined(separator: "-")
        return UUID(uuidString: normalized)
    }

    private static func isASCIIHexDigit(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...70, 97...102:
            return true
        default:
            return false
        }
    }
}
