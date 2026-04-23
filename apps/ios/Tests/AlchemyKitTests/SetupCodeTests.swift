import Foundation
import Testing
@testable import AlchemyKit

struct SetupCodeTests {
    @Test
    func decodesBase64URLSetupCode() throws {
        let url = try #require(URL(string: "wss://gateway.example/ws"))
        let payload = SetupCodePayload(url: url, bootstrapToken: "secret-token")
        let encoded = try payload.encodeSetupCode()
        let decoded = try SetupCodePayload(setupCode: encoded)

        #expect(decoded == payload)
    }

    @Test
    func decodesRawJSONForDebugBuilds() throws {
        let decoded = try SetupCodePayload(
            setupCode: #"{"url":"ws://127.0.0.1:18789","bootstrapToken":"abc"}"#
        )

        #expect(decoded.bootstrapToken == "abc")
        #expect(decoded.url.absoluteString == "ws://127.0.0.1:18789")
    }

    @Test
    func acceptsLegacyTokenKey() throws {
        let raw = #"{"url":"ws://127.0.0.1:18789","token":"legacy"}"#
        let encoded = Data(raw.utf8).base64EncodedString()
        let decoded = try SetupCodePayload(setupCode: encoded)

        #expect(decoded.bootstrapToken == "legacy")
    }
}
