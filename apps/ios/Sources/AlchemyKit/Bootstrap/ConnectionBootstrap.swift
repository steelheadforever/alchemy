import Foundation

public struct ConnectionBootstrap: Equatable, Sendable {
    public var displayName: String
    public var gatewayURL: URL
    public var bootstrapToken: String

    public init(
        displayName: String,
        gatewayURL: URL,
        bootstrapToken: String
    ) {
        self.displayName = displayName
        self.gatewayURL = gatewayURL
        self.bootstrapToken = bootstrapToken
    }
}

