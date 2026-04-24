import Foundation

private struct PendingAuthSelection: Sendable {
    var authToken: String?
    var authBootstrapToken: String?
    var resolvedDeviceToken: String?
    var authPassword: String?
    var signatureToken: String?
    var scopes: [String]
}

public actor GatewayClient {
    public static let protocolVersion = 3

    private let transport: any GatewayTransporting
    private let authStore: GatewayAuthStore
    private let deviceIdentity: GatewayDeviceIdentity

    private var configuration: GatewayConnectionConfiguration?
    private var connectRequestID: String?
    private var connectContinuation: CheckedContinuation<GatewayHello, Error>?
    private var pendingResponses: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var readLoopTask: Task<Void, Never>?
    private var eventStreams: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]
    private var hello: GatewayHello?

    public init(
        transport: any GatewayTransporting = URLSessionGatewayTransport(),
        authStore: GatewayAuthStore = GatewayAuthStore(),
        deviceIdentity: GatewayDeviceIdentity = .generate()
    ) {
        self.transport = transport
        self.authStore = authStore
        self.deviceIdentity = deviceIdentity
    }

    public func events() -> AsyncStream<GatewayEvent> {
        let identifier = UUID()

        return AsyncStream { continuation in
            Task { await self.addEventStream(id: identifier, continuation: continuation) }
        }
    }

    public func connect(configuration: GatewayConnectionConfiguration) async throws -> GatewayHello {
        self.configuration = configuration
        self.hello = nil
        self.connectRequestID = nil
        self.readLoopTask?.cancel()
        try await transport.connect(to: configuration.url)

        return try await withCheckedThrowingContinuation { continuation in
            connectContinuation = continuation
            readLoopTask = Task { await self.runReadLoop() }
        }
    }

    public func disconnect() async {
        readLoopTask?.cancel()
        readLoopTask = nil
        hello = nil
        connectRequestID = nil
        failPending(with: GatewayClientError.disconnected("Client disconnected"))
        await transport.disconnect()
    }

    public func listAgents() async throws -> JSONValue {
        try await request(method: "agents.list", params: .object([:]))
    }

    public func listSessions(
        limit: Int? = nil,
        includeDerivedTitles: Bool = true,
        includeLastMessage: Bool = true
    ) async throws -> JSONValue {
        var params: [String: JSONValue] = [
            "includeDerivedTitles": .bool(includeDerivedTitles),
            "includeLastMessage": .bool(includeLastMessage),
        ]

        if let limit {
            params["limit"] = .number(Double(limit))
        }

        return try await request(method: "sessions.list", params: .object(params))
    }

    public func createSession(
        agentID: String? = nil,
        label: String? = nil,
        message: String? = nil
    ) async throws -> JSONValue {
        var params: [String: JSONValue] = [:]

        if let agentID {
            params["agentId"] = .string(agentID)
        }

        if let label {
            params["label"] = .string(label)
        }

        if let message {
            params["message"] = .string(message)
        }

        return try await request(method: "sessions.create", params: .object(params))
    }

    public func subscribeSessionMessages(key: String) async throws -> JSONValue {
        try await request(
            method: "sessions.messages.subscribe",
            params: .object(["key": .string(key)])
        )
    }

    public func sendSessionMessage(
        key: String,
        message: String,
        timeoutMilliseconds: Int? = nil,
        idempotencyKey: String? = nil
    ) async throws -> JSONValue {
        var params: [String: JSONValue] = [
            "key": .string(key),
            "message": .string(message),
        ]

        if let timeoutMilliseconds {
            params["timeoutMs"] = .number(Double(timeoutMilliseconds))
        }

        if let idempotencyKey {
            params["idempotencyKey"] = .string(idempotencyKey)
        }

        return try await request(method: "sessions.send", params: .object(params))
    }

    public func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard hello != nil else {
            throw GatewayClientError.notConnected
        }

        let requestID = UUID().uuidString.lowercased()
        print("Alchemy Gateway request: method=\(method) id=\(requestID)")
        let frame = JSONValue.object([
            "type": .string("req"),
            "id": .string(requestID),
            "method": .string(method),
            "params": params,
        ])

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[requestID] = continuation

            Task {
                do {
                    try await transport.send(text: try frame.encodeText())
                } catch {
                    self.resumePendingResponse(id: requestID, result: .failure(error))
                }
            }
        }
    }

    private func registerEventStream(
        id: UUID,
        continuation: AsyncStream<GatewayEvent>.Continuation
    ) {
        eventStreams[id] = continuation
        continuation.onTermination = { _ in
            Task { await self.removeEventStream(id: id) }
        }
    }

    private func addEventStream(
        id: UUID,
        continuation: AsyncStream<GatewayEvent>.Continuation
    ) async {
        registerEventStream(id: id, continuation: continuation)
    }

    private func removeEventStream(id: UUID) {
        eventStreams.removeValue(forKey: id)
    }

    private func runReadLoop() async {
        do {
            while !Task.isCancelled {
                let text = try await transport.receiveText()
                try await handleIncomingText(text)
            }
        } catch {
            failPending(with: error)
        }
    }

    private func handleIncomingText(_ text: String) async throws {
        let frame = try JSONValue.decode(from: text)
        guard let object = frame.objectValue else {
            throw GatewayClientError.invalidMessage
        }

        switch object["type"]?.stringValue {
        case "event":
            try await handleEventFrame(object)
        case "res":
            try await handleResponseFrame(object)
        default:
            throw GatewayClientError.unsupportedFrame
        }
    }

    private func handleEventFrame(_ object: [String: JSONValue]) async throws {
        guard let eventName = object["event"]?.stringValue else {
            throw GatewayClientError.invalidMessage
        }

        if eventName == "connect.challenge" {
            guard let nonce = object["payload"]?["nonce"]?.stringValue else {
                throw GatewayClientError.challengeMissingNonce
            }

            try await sendConnect(nonce: nonce)
            return
        }

        let event = GatewayEvent(
            name: eventName,
            payload: object["payload"],
            sequence: object["seq"]?.intValue
        )

        for continuation in eventStreams.values {
            continuation.yield(event)
        }
    }

    private func handleResponseFrame(_ object: [String: JSONValue]) async throws {
        guard let requestID = object["id"]?.stringValue else {
            throw GatewayClientError.invalidMessage
        }

        let ok = object["ok"]?.boolValue ?? false

        if requestID == connectRequestID {
            if ok {
                let hello = try parseHello(payload: object["payload"])
                self.hello = hello
                try await storeAuthTokens(from: hello)
                connectContinuation?.resume(returning: hello)
                connectContinuation = nil
            } else {
                let error = parseResponseError(object["error"])
                connectContinuation?.resume(throwing: error)
                connectContinuation = nil
            }
            return
        }

        if ok {
            print("Alchemy Gateway response ok: id=\(requestID)")
            resumePendingResponse(id: requestID, result: .success(object["payload"] ?? .null))
        } else {
            let error = parseResponseError(object["error"])
            print("Alchemy Gateway response error: id=\(requestID) code=\(error.code) message=\(error.message)")
            resumePendingResponse(id: requestID, result: .failure(error))
        }
    }

    private func sendConnect(nonce: String) async throws {
        guard let configuration else {
            throw GatewayClientError.missingConnectConfiguration
        }

        let selection = await selectConnectAuth(for: configuration)
        let requestID = UUID().uuidString.lowercased()
        connectRequestID = requestID

        let signedAtMilliseconds = Int(Date().timeIntervalSince1970 * 1000)
        let signaturePayload = GatewayDeviceAuthPayload.buildV3(
            deviceID: try deviceIdentity.deviceID,
            clientID: configuration.client.id,
            clientMode: configuration.client.mode.rawValue,
            role: configuration.role.rawValue,
            scopes: selection.scopes,
            signedAtMilliseconds: signedAtMilliseconds,
            token: selection.signatureToken,
            nonce: nonce,
            platform: configuration.client.platform,
            deviceFamily: configuration.client.deviceFamily
        )

        var clientObject: [String: JSONValue] = [
            "id": .string(configuration.client.id),
            "version": .string(configuration.client.version),
            "platform": .string(configuration.client.platform),
            "mode": .string(configuration.client.mode.rawValue),
        ]

        if let displayName = configuration.client.displayName {
            clientObject["displayName"] = .string(displayName)
        }

        if let deviceFamily = configuration.client.deviceFamily {
            clientObject["deviceFamily"] = .string(deviceFamily)
        }

        if let instanceID = configuration.client.instanceID {
            clientObject["instanceId"] = .string(instanceID)
        }

        var authObject: [String: JSONValue] = [:]
        if let authToken = selection.authToken {
            authObject["token"] = .string(authToken)
        }
        if let bootstrapToken = selection.authBootstrapToken {
            authObject["bootstrapToken"] = .string(bootstrapToken)
        }
        if let deviceToken = selection.resolvedDeviceToken {
            authObject["deviceToken"] = .string(deviceToken)
        }
        if let password = selection.authPassword {
            authObject["password"] = .string(password)
        }

        var params: [String: JSONValue] = [
            "minProtocol": .number(Double(Self.protocolVersion)),
            "maxProtocol": .number(Double(Self.protocolVersion)),
            "client": .object(clientObject),
            "role": .string(configuration.role.rawValue),
            "scopes": .array(selection.scopes.map(JSONValue.string)),
            "caps": .array(configuration.caps.map(JSONValue.string)),
            "device": .object([
                "id": .string(try deviceIdentity.deviceID),
                "publicKey": .string(try deviceIdentity.publicKeyBase64URL),
                "signature": .string(try deviceIdentity.sign(payload: signaturePayload)),
                "signedAt": .number(Double(signedAtMilliseconds)),
                "nonce": .string(nonce),
            ]),
        ]

        if !configuration.commands.isEmpty {
            params["commands"] = .array(configuration.commands.map(JSONValue.string))
        }

        if !configuration.permissions.isEmpty {
            params["permissions"] = .object(
                configuration.permissions.mapValues(JSONValue.bool)
            )
        }

        if !authObject.isEmpty {
            params["auth"] = .object(authObject)
        }

        if let locale = configuration.locale {
            params["locale"] = .string(locale)
        }

        if let userAgent = configuration.userAgent {
            params["userAgent"] = .string(userAgent)
        }

        print(
            """
            Alchemy Gateway sending connect: role=\(configuration.role.rawValue) \
            client.id=\(configuration.client.id) platform=\(configuration.client.platform) \
            mode=\(configuration.client.mode.rawValue)
            """
        )

        let frame = JSONValue.object([
            "type": .string("req"),
            "id": .string(requestID),
            "method": .string("connect"),
            "params": .object(params),
        ])

        try await transport.send(text: frame.encodeText())
    }

    private func selectConnectAuth(
        for configuration: GatewayConnectionConfiguration
    ) async -> PendingAuthSelection {
        let explicitGatewayToken = normalizeOptionalString(configuration.token)
        let explicitBootstrapToken = normalizeOptionalString(configuration.bootstrapToken)
        let explicitDeviceToken = normalizeOptionalString(configuration.deviceToken)
        let explicitPassword = normalizeOptionalString(configuration.password)
        let stored = await authStore.loadToken(
            deviceID: (try? deviceIdentity.deviceID) ?? "",
            role: configuration.role.rawValue
        )

        let resolvedDeviceToken = explicitDeviceToken ??
            ((explicitGatewayToken == nil && explicitPassword == nil &&
              (explicitBootstrapToken == nil || stored != nil)) ? stored?.token : nil)

        let usingStoredDeviceToken =
            resolvedDeviceToken != nil &&
            explicitDeviceToken == nil &&
            stored?.token == resolvedDeviceToken

        let scopes = usingStoredDeviceToken && !(stored?.scopes.isEmpty ?? true)
            ? (stored?.scopes ?? configuration.scopes)
            : configuration.scopes

        let authToken = explicitGatewayToken ?? resolvedDeviceToken
        let authBootstrapToken = (explicitGatewayToken == nil && resolvedDeviceToken == nil)
            ? explicitBootstrapToken
            : nil

        return PendingAuthSelection(
            authToken: authToken,
            authBootstrapToken: authBootstrapToken,
            resolvedDeviceToken: resolvedDeviceToken,
            authPassword: explicitPassword,
            signatureToken: authToken ?? authBootstrapToken,
            scopes: scopes
        )
    }

    private func storeAuthTokens(from hello: GatewayHello) async throws {
        if let primaryToken = hello.primaryToken {
            await authStore.storeToken(
                deviceID: try deviceIdentity.deviceID,
                role: primaryToken.role.rawValue,
                token: primaryToken.token,
                scopes: primaryToken.scopes
            )
        }

        for token in hello.additionalTokens {
            await authStore.storeToken(
                deviceID: try deviceIdentity.deviceID,
                role: token.role.rawValue,
                token: token.token,
                scopes: token.scopes
            )
        }
    }

    private func parseHello(payload: JSONValue?) throws -> GatewayHello {
        guard let payload, let object = payload.objectValue else {
            throw GatewayClientError.invalidMessage
        }

        let protocolVersion = object["protocol"]?.intValue ?? Self.protocolVersion
        let methods = object["features"]?["methods"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let events = object["features"]?["events"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let connectionID = object["server"]?["connId"]?.stringValue
        let tickIntervalMilliseconds = object["policy"]?["tickIntervalMs"]?.intValue

        var primaryToken: GatewayIssuedToken?
        var additionalTokens: [GatewayIssuedToken] = []

        if let auth = object["auth"]?.objectValue {
            if
                let deviceToken = auth["deviceToken"]?.stringValue,
                let role = GatewayRole(rawValue: auth["role"]?.stringValue ?? "")
            {
                primaryToken = GatewayIssuedToken(
                    token: deviceToken,
                    role: role,
                    scopes: auth["scopes"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                    issuedAtMilliseconds: auth["issuedAtMs"]?.intValue
                )
            }

            additionalTokens = auth["deviceTokens"]?.arrayValue?.compactMap { value in
                guard
                    let token = value["deviceToken"]?.stringValue,
                    let role = GatewayRole(rawValue: value["role"]?.stringValue ?? "")
                else {
                    return nil
                }

                return GatewayIssuedToken(
                    token: token,
                    role: role,
                    scopes: value["scopes"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                    issuedAtMilliseconds: value["issuedAtMs"]?.intValue
                )
            } ?? []
        }

        return GatewayHello(
            protocolVersion: protocolVersion,
            connectionID: connectionID,
            methods: methods,
            events: events,
            tickIntervalMilliseconds: tickIntervalMilliseconds,
            primaryToken: primaryToken,
            additionalTokens: additionalTokens,
            rawPayload: payload
        )
    }

    private func parseResponseError(_ value: JSONValue?) -> GatewayResponseError {
        let object = value?.objectValue

        return GatewayResponseError(
            code: object?["code"]?.stringValue ?? "UNAVAILABLE",
            message: object?["message"]?.stringValue ?? "Unknown gateway error",
            details: object?["details"],
            retryable: object?["retryable"]?.boolValue ?? false,
            retryAfterMilliseconds: object?["retryAfterMs"]?.intValue
        )
    }

    private func resumePendingResponse(
        id: String,
        result: Result<JSONValue, Error>
    ) {
        guard let continuation = pendingResponses.removeValue(forKey: id) else {
            return
        }

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func failPending(with error: Error) {
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil

        let continuations = pendingResponses.values
        pendingResponses.removeAll()

        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }
}

private func normalizeOptionalString(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}
