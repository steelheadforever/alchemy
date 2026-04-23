import Foundation

public struct SetupCodePayload: Codable, Equatable, Sendable {
    public var url: URL
    public var bootstrapToken: String

    public init(url: URL, bootstrapToken: String) {
        self.url = url
        self.bootstrapToken = bootstrapToken
    }

    public init(setupCode: String) throws {
        let payload = try SetupCodeCodec.decode(setupCode)
        self = payload
    }

    public func encodeSetupCode() throws -> String {
        try SetupCodeCodec.encode(self)
    }
}

public enum SetupCodeCodec {
    public static func decode(_ setupCode: String) throws -> SetupCodePayload {
        let trimmed = setupCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SetupCodeError.empty
        }

        if let payload = try decodeJSON(trimmed) {
            return payload
        }

        if let payload = try decodeBase64URL(trimmed) {
            return payload
        }

        if let payload = try decodeBase64(trimmed) {
            return payload
        }

        throw SetupCodeError.invalidEncoding
    }

    public static func encode(_ payload: SetupCodePayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeJSON(_ string: String) throws -> SetupCodePayload? {
        guard let data = string.data(using: .utf8) else {
            return nil
        }

        return try decodePayload(data)
    }

    private static func decodeBase64URL(_ string: String) throws -> SetupCodePayload? {
        let padding = String(repeating: "=", count: (4 - string.count % 4) % 4)
        let base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding

        guard let data = Data(base64Encoded: base64) else {
            return nil
        }

        return try decodePayload(data)
    }

    private static func decodeBase64(_ string: String) throws -> SetupCodePayload? {
        guard let data = Data(base64Encoded: string) else {
            return nil
        }

        return try decodePayload(data)
    }

    private static func decodePayload(_ data: Data) throws -> SetupCodePayload? {
        do {
            return try JSONDecoder().decode(SetupCodePayload.self, from: data)
        } catch {
            if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return try decodeLegacyPayload(raw)
            }
            return nil
        }
    }

    private static func decodeLegacyPayload(_ raw: [String: Any]) throws -> SetupCodePayload {
        guard
            let urlString = raw["url"] as? String,
            let url = URL(string: urlString)
        else {
            throw SetupCodeError.missingURL
        }

        let bootstrapToken =
            (raw["bootstrapToken"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ??
            (raw["token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ??
            ""

        guard !bootstrapToken.isEmpty else {
            throw SetupCodeError.missingBootstrapToken
        }

        return SetupCodePayload(url: url, bootstrapToken: bootstrapToken)
    }
}

public enum SetupCodeError: Error, Equatable {
    case empty
    case invalidEncoding
    case missingURL
    case missingBootstrapToken
}

