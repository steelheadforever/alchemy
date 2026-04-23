import Foundation
import Security

public struct GatewayStoredToken: Codable, Equatable, Sendable {
    public var token: String
    public var role: String
    public var scopes: [String]
    public var updatedAtMilliseconds: Int

    public init(token: String, role: String, scopes: [String], updatedAtMilliseconds: Int) {
        self.token = token
        self.role = role
        self.scopes = scopes
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }
}

public struct GatewayStoredAuthSnapshot: Codable, Equatable, Sendable {
    public var version: Int
    public var deviceID: String
    public var tokens: [String: GatewayStoredToken]

    public init(version: Int = 1, deviceID: String, tokens: [String: GatewayStoredToken]) {
        self.version = version
        self.deviceID = deviceID
        self.tokens = tokens
    }
}

public protocol GatewayAuthSnapshotPersisting: Actor {
    func loadSnapshot(deviceID: String) -> GatewayStoredAuthSnapshot?
    func saveSnapshot(_ snapshot: GatewayStoredAuthSnapshot)
    func deleteSnapshot(deviceID: String)
}

public actor InMemoryGatewayAuthSnapshotStore: GatewayAuthSnapshotPersisting {
    private var snapshots: [String: GatewayStoredAuthSnapshot] = [:]

    public init() {}

    public func loadSnapshot(deviceID: String) -> GatewayStoredAuthSnapshot? {
        snapshots[deviceID]
    }

    public func saveSnapshot(_ snapshot: GatewayStoredAuthSnapshot) {
        snapshots[snapshot.deviceID] = snapshot
    }

    public func deleteSnapshot(deviceID: String) {
        snapshots.removeValue(forKey: deviceID)
    }
}

public actor KeychainGatewayAuthSnapshotStore: GatewayAuthSnapshotPersisting {
    private let service: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(service: String = "ai.alchemy.gateway-auth") {
        self.service = service
    }

    public func loadSnapshot(deviceID: String) -> GatewayStoredAuthSnapshot? {
        guard let data = copyData(for: deviceID) else {
            return nil
        }

        return try? decoder.decode(GatewayStoredAuthSnapshot.self, from: data)
    }

    public func saveSnapshot(_ snapshot: GatewayStoredAuthSnapshot) {
        guard let data = try? encoder.encode(snapshot) else {
            return
        }

        deleteData(for: snapshot.deviceID)

        var query = baseQuery(deviceID: snapshot.deviceID)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        SecItemAdd(query as CFDictionary, nil)
    }

    public func deleteSnapshot(deviceID: String) {
        deleteData(for: deviceID)
    }

    private func copyData(for deviceID: String) -> Data? {
        var query = baseQuery(deviceID: deviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            return nil
        }

        return result as? Data
    }

    private func deleteData(for deviceID: String) {
        SecItemDelete(baseQuery(deviceID: deviceID) as CFDictionary)
    }

    private func baseQuery(deviceID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID,
        ]
    }
}

public actor GatewayAuthStore {
    private let persistence: any GatewayAuthSnapshotPersisting
    private var snapshots: [String: GatewayStoredAuthSnapshot] = [:]

    public init(persistence: any GatewayAuthSnapshotPersisting = KeychainGatewayAuthSnapshotStore()) {
        self.persistence = persistence
    }

    public func loadToken(deviceID: String, role: String) async -> GatewayStoredToken? {
        let snapshot = await loadSnapshot(deviceID: deviceID)
        return snapshot?.tokens[normalizeRole(role)]
    }

    public func snapshot(deviceID: String) async -> GatewayStoredAuthSnapshot? {
        await loadSnapshot(deviceID: deviceID)
    }

    @discardableResult
    public func storeToken(
        deviceID: String,
        role: String,
        token: String,
        scopes: [String]
    ) async -> GatewayStoredToken {
        let normalizedRole = normalizeRole(role)
        var snapshot = await loadSnapshot(deviceID: deviceID) ?? GatewayStoredAuthSnapshot(
            deviceID: deviceID,
            tokens: [:]
        )

        let entry = GatewayStoredToken(
            token: token,
            role: normalizedRole,
            scopes: normalizeScopes(scopes),
            updatedAtMilliseconds: Int(Date().timeIntervalSince1970 * 1000)
        )
        snapshot.tokens[normalizedRole] = entry
        snapshots[deviceID] = snapshot
        await persistence.saveSnapshot(snapshot)
        return entry
    }

    public func clearToken(deviceID: String, role: String) async {
        guard var snapshot = await loadSnapshot(deviceID: deviceID) else {
            return
        }

        snapshot.tokens.removeValue(forKey: normalizeRole(role))

        if snapshot.tokens.isEmpty {
            snapshots.removeValue(forKey: deviceID)
            await persistence.deleteSnapshot(deviceID: deviceID)
            return
        }

        snapshots[deviceID] = snapshot
        await persistence.saveSnapshot(snapshot)
    }

    private func loadSnapshot(deviceID: String) async -> GatewayStoredAuthSnapshot? {
        if let cached = snapshots[deviceID] {
            return cached
        }

        let loaded = await persistence.loadSnapshot(deviceID: deviceID)
        if let loaded {
            snapshots[deviceID] = loaded
        }
        return loaded
    }

    private func normalizeRole(_ role: String) -> String {
        role.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeScopes(_ scopes: [String]) -> [String] {
        var unique = Set<String>()

        for scope in scopes {
            let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            unique.insert(trimmed)
        }

        if unique.contains("operator.admin") {
            unique.insert("operator.read")
            unique.insert("operator.write")
        } else if unique.contains("operator.write") {
            unique.insert("operator.read")
        }

        return unique.sorted()
    }
}
