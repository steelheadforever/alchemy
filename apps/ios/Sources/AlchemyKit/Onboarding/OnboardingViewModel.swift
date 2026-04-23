import Foundation
import Observation

@Observable
@MainActor
public final class OnboardingViewModel {
    public var setupCodeText = ""
    public var bootstrap: ConnectionBootstrap?
    public private(set) var setupCode: SetupCodePayload?
    public var errorMessage: String?

    public init() {}

    public func importSetupCode() {
        applySetupCode(setupCodeText)
    }

    public func applySetupCode(_ value: String) {
        do {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let payload = try SetupCodePayload(setupCode: trimmed)
            setupCodeText = trimmed
            setupCode = payload
            bootstrap = ConnectionBootstrap(
                displayName: payload.url.host ?? "OpenClaw Gateway",
                gatewayURL: payload.url,
                bootstrapToken: payload.bootstrapToken
            )
            errorMessage = nil
        } catch {
            setupCode = nil
            bootstrap = nil
            errorMessage = "The setup code is invalid or incomplete."
        }
    }
}
