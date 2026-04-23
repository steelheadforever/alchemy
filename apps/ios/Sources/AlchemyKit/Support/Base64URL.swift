import Foundation

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) throws -> Data {
        let normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - normalized.count % 4) % 4)

        guard let data = Data(base64Encoded: normalized + padding) else {
            throw Base64URLError.invalidEncoding
        }

        return data
    }
}

enum Base64URLError: Error {
    case invalidEncoding
}

