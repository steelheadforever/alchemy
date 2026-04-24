import CryptoKit
import Foundation
import Security

public protocol DeviceIdentityPersisting: Actor {
    func load() -> Data?
    func save(_ privateKey: Data)
    func delete()
}

public actor KeychainDeviceIdentityStore: DeviceIdentityPersisting {
    private let service: String
    private let account: String

    public init(
        service: String = "ai.alchemy.device-identity",
        account: String = "primary"
    ) {
        self.service = service
        self.account = account
    }

    public func load() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            return nil
        }

        return result as? Data
    }

    public func save(_ privateKey: Data) {
        SecItemDelete(baseQuery() as CFDictionary)

        var query = baseQuery()
        query[kSecValueData as String] = privateKey
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        SecItemAdd(query as CFDictionary, nil)
    }

    public func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public actor InMemoryDeviceIdentityStore: DeviceIdentityPersisting {
    private var stored: Data?

    public init() {}

    public func load() -> Data? { stored }
    public func save(_ privateKey: Data) { stored = privateKey }
    public func delete() { stored = nil }
}

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

    public static func loadOrGenerate() -> GatewayDeviceIdentity {
        let service = "ai.alchemy.device-identity"
        let account = "primary"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let identity = try? GatewayDeviceIdentity(privateKeyRepresentation: data) {
            return identity
        }

        let identity = generate()
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var addQuery = deleteQuery
        addQuery[kSecValueData as String] = identity.privateKeyRepresentation
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(addQuery as CFDictionary, nil)

        return identity
    }

    public static func deleteStored() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ai.alchemy.device-identity",
            kSecAttrAccount as String: "primary",
        ]
        SecItemDelete(query as CFDictionary)
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

