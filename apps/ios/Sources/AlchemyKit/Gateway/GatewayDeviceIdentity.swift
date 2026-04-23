import CryptoKit
import Foundation

public struct GatewayDeviceIdentity: Sendable, Equatable {
    public let privateKeyRepresentation: Data

    public init(privateKeyRepresentation: Data) throws {
        _ = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyRepresentation)
        self.privateKeyRepresentation = privateKeyRepresentation
    }

    public static func generate() -> GatewayDeviceIdentity {
        let key = Curve25519.Signing.PrivateKey()
        return try! GatewayDeviceIdentity(privateKeyRepresentation: key.rawRepresentation)
    }

    private var privateKey: Curve25519.Signing.PrivateKey {
        get throws {
            try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyRepresentation)
        }
    }

    public var publicKeyRepresentation: Data {
        get throws {
            try privateKey.publicKey.rawRepresentation
        }
    }

    public var publicKeyBase64URL: String {
        get throws {
            try Base64URL.encode(publicKeyRepresentation)
        }
    }

    public var deviceID: String {
        get throws {
            let digest = SHA256.hash(data: try publicKeyRepresentation)
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    public func sign(payload: String) throws -> String {
        let signature = try privateKey.signature(for: Data(payload.utf8))
        return Base64URL.encode(signature)
    }
}

enum GatewayDeviceAuthPayload {
    static func buildV3(
        deviceID: String,
        clientID: String,
        clientMode: String,
        role: String,
        scopes: [String],
        signedAtMilliseconds: Int,
        token: String?,
        nonce: String,
        platform: String?,
        deviceFamily: String?
    ) -> String {
        [
            "v3",
            deviceID,
            clientID,
            clientMode,
            role,
            scopes.joined(separator: ","),
            String(signedAtMilliseconds),
            token ?? "",
            nonce,
            normalizeMetadataForAuth(platform),
            normalizeMetadataForAuth(deviceFamily),
        ].joined(separator: "|")
    }

    private static func normalizeMetadataForAuth(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return ""
        }

        return String(trimmed.unicodeScalars.map { scalar in
            guard scalar.value >= 65, scalar.value <= 90 else {
                return Character(scalar)
            }
            return Character(UnicodeScalar(scalar.value + 32)!)
        })
    }
}

