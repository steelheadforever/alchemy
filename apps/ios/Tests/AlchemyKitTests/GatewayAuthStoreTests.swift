import Testing
@testable import AlchemyKit

struct GatewayAuthStoreTests {
    @Test
    func persistsSnapshotsAcrossStoreInstances() async throws {
        let persistence = InMemoryGatewayAuthSnapshotStore()
        let firstStore = GatewayAuthStore(persistence: persistence)
        let secondStore = GatewayAuthStore(persistence: persistence)

        _ = await firstStore.storeToken(
            deviceID: "device-1",
            role: "operator",
            token: "operator-token",
            scopes: ["operator.write"]
        )

        let restored = await secondStore.loadToken(deviceID: "device-1", role: "operator")

        #expect(restored?.token == "operator-token")
        #expect(restored?.scopes == ["operator.read", "operator.write"])
    }

    @Test
    func clearingLastRoleDeletesSnapshot() async throws {
        let persistence = InMemoryGatewayAuthSnapshotStore()
        let store = GatewayAuthStore(persistence: persistence)

        _ = await store.storeToken(
            deviceID: "device-2",
            role: "node",
            token: "node-token",
            scopes: []
        )

        await store.clearToken(deviceID: "device-2", role: "node")

        let snapshot = await store.snapshot(deviceID: "device-2")
        #expect(snapshot == nil)
    }
}
