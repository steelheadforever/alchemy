import Foundation
import Testing
@testable import AlchemyKit

actor MockGatewayTransport: GatewayTransporting {
    private var queuedMessages: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private(set) var sentMessages: [String] = []
    private(set) var connectedURL: URL?

    func connect(to url: URL) async throws {
        connectedURL = url
    }

    func send(text: String) async throws {
        sentMessages.append(text)
    }

    func receiveText() async throws -> String {
        if !queuedMessages.isEmpty {
            return queuedMessages.removeFirst()
        }

        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func disconnect() async {}

    func push(_ text: String) {
        if !waiters.isEmpty {
            let continuation = waiters.removeFirst()
            continuation.resume(returning: text)
            return
        }

        queuedMessages.append(text)
    }

    func firstSentMessage() -> String? {
        sentMessages.first
    }
}

struct GatewayClientTests {
    @Test
    func bootstrapHandshakeStoresNodeAndOperatorTokens() async throws {
        let transport = MockGatewayTransport()
        let store = GatewayAuthStore(persistence: InMemoryGatewayAuthSnapshotStore())
        let identity = GatewayDeviceIdentity.generate()
        let client = GatewayClient(
            transport: transport,
            authStore: store,
            deviceIdentity: identity
        )

        let setup = SetupCodePayload(
            url: try #require(URL(string: "wss://gateway.example/ws")),
            bootstrapToken: "bootstrap-secret"
        )

        let connectTask = Task {
            try await client.connect(configuration: .bootstrap(from: setup))
        }

        await transport.push(
            #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-123","ts":1737264000000}}"#
        )

        try await Task.sleep(for: .milliseconds(20))
        let connectFrameText = try #require(await transport.firstSentMessage())
        let connectFrame = try JSONValue.decode(from: connectFrameText)
        let expectedDeviceID = try identity.deviceID
        let expectedPublicKey = try identity.publicKeyBase64URL

        #expect(connectFrame["method"]?.stringValue == "connect")
        #expect(connectFrame["params"]?["client"]?["id"]?.stringValue == "openclaw-ios")
        #expect(connectFrame["params"]?["auth"]?["bootstrapToken"]?.stringValue == "bootstrap-secret")
        #expect(connectFrame["params"]?["auth"]?["token"] == nil)
        #expect(connectFrame["params"]?["device"]?["id"]?.stringValue == expectedDeviceID)
        #expect(connectFrame["params"]?["device"]?["publicKey"]?.stringValue == expectedPublicKey)

        let requestID = try #require(connectFrame["id"]?.stringValue)

        await transport.push(
            """
            {
              "type":"res",
              "id":"\(requestID)",
              "ok":true,
              "payload":{
                "type":"hello-ok",
                "protocol":3,
                "server":{"version":"2026.4.15","connId":"conn-1"},
                "features":{"methods":["agents.list","sessions.list"],"events":["session.message"]},
                "snapshot":{"presence":[],"stateVersion":{"presence":1}},
                "auth":{
                  "deviceToken":"node-token",
                  "role":"node",
                  "scopes":[],
                  "deviceTokens":[
                    {
                      "deviceToken":"operator-token",
                      "role":"operator",
                      "scopes":["operator.approvals","operator.read","operator.talk.secrets","operator.write"],
                      "issuedAtMs":1737264001000
                    }
                  ]
                },
                "policy":{"maxPayload":1048576,"maxBufferedBytes":1048576,"tickIntervalMs":15000}
              }
            }
            """
        )

        let hello = try await connectTask.value

        #expect(hello.protocolVersion == 3)
        #expect(hello.primaryToken?.token == "node-token")
        #expect(hello.additionalTokens.count == 1)
        #expect(hello.additionalTokens.first?.token == "operator-token")

        let nodeToken = await store.loadToken(deviceID: try identity.deviceID, role: "node")
        let operatorToken = await store.loadToken(deviceID: try identity.deviceID, role: "operator")

        #expect(nodeToken?.token == "node-token")
        #expect(operatorToken?.token == "operator-token")

        await client.disconnect()
    }
}
