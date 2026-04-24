import Foundation

public enum GatewayRole: String, Codable, Sendable {
    case `operator`
    case node
}

public enum GatewayClientMode: String, Codable, Sendable {
    case `operator`
    case node
}

public struct GatewayClientDescriptor: Sendable, Equatable {
    public var id: String
    public var displayName: String?
    public var version: String
    public var platform: String
    public var deviceFamily: String?
    public var mode: GatewayClientMode
    public var instanceID: String?

    public init(
        id: String,
        displayName: String? = nil,
        version: String,
        platform: String,
        deviceFamily: String? = nil,
        mode: GatewayClientMode,
        instanceID: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.platform = platform
        self.deviceFamily = deviceFamily
        self.mode = mode
        self.instanceID = instanceID
    }
}

public struct GatewayConnectionConfiguration: Sendable, Equatable {
    public var url: URL
    public var client: GatewayClientDescriptor
    public var role: GatewayRole
    public var scopes: [String]
    public var caps: [String]
    public var commands: [String]
    public var permissions: [String: Bool]
    public var token: String?
    public var bootstrapToken: String?
    public var deviceToken: String?
    public var password: String?
    public var locale: String?
    public var userAgent: String?

    public init(
        url: URL,
        client: GatewayClientDescriptor,
        role: GatewayRole,
        scopes: [String] = [],
        caps: [String] = [],
        commands: [String] = [],
        permissions: [String: Bool] = [:],
        token: String? = nil,
        bootstrapToken: String? = nil,
        deviceToken: String? = nil,
        password: String? = nil,
        locale: String? = nil,
        userAgent: String? = nil
    ) {
        self.url = url
        self.client = client
        self.role = role
        self.scopes = scopes
        self.caps = caps
        self.commands = commands
        self.permissions = permissions
        self.token = token
        self.bootstrapToken = bootstrapToken
        self.deviceToken = deviceToken
        self.password = password
        self.locale = locale
        self.userAgent = userAgent
    }

    public static func bootstrap(
        from setupCode: SetupCodePayload,
        clientVersion: String = "0.1.0",
        displayName: String? = nil
    ) -> GatewayConnectionConfiguration {
        GatewayConnectionConfiguration(
            url: setupCode.url,
            client: GatewayClientDescriptor(
                id: "openclaw-ios",
                displayName: displayName,
                version: clientVersion,
                platform: "ios",
                deviceFamily: "phone",
                mode: .node
            ),
            role: .node,
            scopes: [],
            bootstrapToken: setupCode.bootstrapToken,
            locale: Locale.current.identifier,
            userAgent: "alchemy-ios/\(clientVersion)"
        )
    }

    public static func `operator`(
        url: URL,
        clientVersion: String = "0.1.0",
        displayName: String? = nil
    ) -> GatewayConnectionConfiguration {
        GatewayConnectionConfiguration(
            url: url,
            client: GatewayClientDescriptor(
                id: "openclaw-ios",
                displayName: displayName,
                version: clientVersion,
                platform: "ios",
                deviceFamily: "phone",
                mode: .node
            ),
            role: .operator,
            scopes: [
                "operator.approvals",
                "operator.read",
                "operator.talk.secrets",
                "operator.write",
            ],
            locale: Locale.current.identifier,
            userAgent: "alchemy-ios/\(clientVersion)"
        )
    }
}

public struct GatewayIssuedToken: Sendable, Equatable {
    public var token: String
    public var role: GatewayRole
    public var scopes: [String]
    public var issuedAtMilliseconds: Int?

    public init(token: String, role: GatewayRole, scopes: [String], issuedAtMilliseconds: Int? = nil) {
        self.token = token
        self.role = role
        self.scopes = scopes
        self.issuedAtMilliseconds = issuedAtMilliseconds
    }
}

public struct GatewayHello: Sendable, Equatable {
    public var protocolVersion: Int
    public var connectionID: String?
    public var methods: [String]
    public var events: [String]
    public var tickIntervalMilliseconds: Int?
    public var primaryToken: GatewayIssuedToken?
    public var additionalTokens: [GatewayIssuedToken]
    public var rawPayload: JSONValue

    public init(
        protocolVersion: Int,
        connectionID: String?,
        methods: [String],
        events: [String],
        tickIntervalMilliseconds: Int?,
        primaryToken: GatewayIssuedToken?,
        additionalTokens: [GatewayIssuedToken],
        rawPayload: JSONValue
    ) {
        self.protocolVersion = protocolVersion
        self.connectionID = connectionID
        self.methods = methods
        self.events = events
        self.tickIntervalMilliseconds = tickIntervalMilliseconds
        self.primaryToken = primaryToken
        self.additionalTokens = additionalTokens
        self.rawPayload = rawPayload
    }
}

public struct GatewayEvent: Sendable, Equatable {
    public var name: String
    public var payload: JSONValue?
    public var sequence: Int?

    public init(name: String, payload: JSONValue?, sequence: Int?) {
        self.name = name
        self.payload = payload
        self.sequence = sequence
    }
}

public struct GatewayResponseError: Error, Sendable, Equatable {
    public var code: String
    public var message: String
    public var details: JSONValue?
    public var retryable: Bool
    public var retryAfterMilliseconds: Int?

    public init(
        code: String,
        message: String,
        details: JSONValue? = nil,
        retryable: Bool = false,
        retryAfterMilliseconds: Int? = nil
    ) {
        self.code = code
        self.message = message
        self.details = details
        self.retryable = retryable
        self.retryAfterMilliseconds = retryAfterMilliseconds
    }
}

public enum GatewayClientError: Error, Sendable, Equatable {
    case invalidMessage
    case unsupportedFrame
    case challengeMissingNonce
    case missingConnectConfiguration
    case notConnected
    case disconnected(String)
}

public enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self {
            return Int(value)
        }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    static func decode(from text: String) throws -> JSONValue {
        guard let data = text.data(using: .utf8) else {
            throw GatewayClientError.invalidMessage
        }

        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func encodeText() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw GatewayClientError.invalidMessage
        }
        return text
    }
}
