import Foundation
import Observation

@Observable
@MainActor
public final class DiscordWorkspaceViewModel {
    public private(set) var channels: [WorkspaceChannel] = []
    public private(set) var selectedChannelID: WorkspaceChannel.ID?
    public private(set) var availableAgents: [AgentSummary] = []
    public private(set) var connectionDiagnostics: [ConnectionDiagnostic] = []
    public private(set) var isConnected = false
    public private(set) var isLoadingAgents = false
    public var errorMessage: String?

    private let gateway: GatewayClient
    private var eventTask: Task<Void, Never>?
    private var operatorConfiguration: GatewayConnectionConfiguration?

    public init(gateway: GatewayClient = GatewayClient()) {
        self.gateway = gateway
    }

    public var selectedChannel: WorkspaceChannel? {
        guard let selectedChannelID else {
            return channels.first
        }
        return channels.first(where: { $0.id == selectedChannelID })
    }

    public func connect(using setupCode: SetupCodePayload) async {
        do {
            errorMessage = nil
            connectionDiagnostics.removeAll()
            logConnectionDiagnostic("Setup code resolved: \(Self.describeGatewayURL(setupCode.url))")

            _ = try await connectBootstrap(using: setupCode)
            logConnectionDiagnostic("Bootstrap connection succeeded; device tokens received.")
            await gateway.disconnect()

            let operatorConfiguration = try await connectOperator(to: setupCode.url)
            logConnectionDiagnostic("Operator connection succeeded.")
            self.operatorConfiguration = operatorConfiguration
            isConnected = true

            startEventLoop()
            await refreshAgents()
            await refreshChannels()
        } catch {
            isConnected = false
            logConnectionDiagnostic("Connection failed: \(Self.describe(error: error))")
            errorMessage = "Gateway connection failed: \(error.localizedDescription)"
        }
    }

    private func connectBootstrap(using setupCode: SetupCodePayload) async throws -> GatewayHello {
        try await connectUsingFallbacks(
            configurations: Self.bootstrapConfigurations(from: setupCode),
            phase: "bootstrap"
        )
    }

    private func connectOperator(to url: URL) async throws -> GatewayConnectionConfiguration {
        var lastError: (any Error)?
        for configuration in Self.operatorConfigurations(url: url) {
            do {
                logConnectionDiagnostic(
                    "Opening operator connection with client.id=\(configuration.client.id)."
                )
                _ = try await gateway.connect(configuration: configuration)
                return configuration
            } catch {
                lastError = error
                logConnectionDiagnostic(
                    "Operator client.id=\(configuration.client.id) failed: \(Self.describe(error: error))"
                )
                await gateway.disconnect()
                if !Self.isClientIDSchemaRejection(error) && !Self.isClientModeSchemaRejection(error) {
                    throw error
                }
            }
        }

        throw lastError ?? GatewayClientError.disconnected("No operator client id candidates were attempted")
    }

    private func connectUsingFallbacks(
        configurations: [GatewayConnectionConfiguration],
        phase: String
    ) async throws -> GatewayHello {
        var lastError: (any Error)?

        for configuration in configurations {
            do {
                logConnectionDiagnostic(
                    "Opening \(phase) connection with client.id=\(configuration.client.id)."
                )
                return try await gateway.connect(configuration: configuration)
            } catch {
                lastError = error
                logConnectionDiagnostic(
                    "\(phase.capitalized) client.id=\(configuration.client.id) failed: \(Self.describe(error: error))"
                )
                await gateway.disconnect()
                if !Self.isClientIDSchemaRejection(error) {
                    throw error
                }
            }
        }

        throw lastError ?? GatewayClientError.disconnected("No \(phase) client id candidates were attempted")
    }

    private static func isClientIDSchemaRejection(_ error: any Error) -> Bool {
        switch error {
        case let response as GatewayResponseError:
            return response.message.contains("/client/id")
        case GatewayClientError.disconnected(let message):
            return message.contains("/client/id")
        default:
            return false
        }
    }

    private static func isClientModeSchemaRejection(_ error: any Error) -> Bool {
        switch error {
        case let response as GatewayResponseError:
            return response.message.contains("/client/mode")
        case GatewayClientError.disconnected(let message):
            return message.contains("/client/mode")
        default:
            return false
        }
    }

    public func refreshAgents() async {
        guard isConnected else {
            return
        }

        isLoadingAgents = true
        defer { isLoadingAgents = false }

        do {
            print("Alchemy Workspace: refreshing agents")
            availableAgents = GatewayWorkspaceParsing.parseAgentSummaries(try await gateway.listAgents())
            print("Alchemy Workspace: loaded agents count=\(availableAgents.count)")
        } catch {
            errorMessage = "Could not load agents: \(error.localizedDescription)"
            print("Alchemy Workspace: refresh agents failed: \(Self.describe(error: error))")
        }
    }

    public func disconnect() async {
        eventTask?.cancel()
        eventTask = nil
        await gateway.disconnect()
        isConnected = false
        selectedChannelID = nil
    }

    public func refreshChannels() async {
        guard isConnected else {
            return
        }

        do {
            print("Alchemy Workspace: refreshing channels")
            let payload = try await gateway.listSessions(limit: 50)
            let existingChannels = channels
            let parsed = GatewayWorkspaceParsing.parseChannels(payload)
            print("Alchemy Workspace: loaded channels count=\(parsed.count)")

            for channel in parsed {
                _ = try? await gateway.subscribeSessionMessages(key: channel.sessionKey)
            }

            channels = parsed.map { incoming in
                guard let existing = existingChannels.first(where: { $0.sessionKey == incoming.sessionKey }) else {
                    return incoming
                }

                return WorkspaceChannel(
                    sessionKey: incoming.sessionKey,
                    title: incoming.title,
                    agentID: incoming.agentID ?? existing.agentID,
                    status: existing.status == .error ? .error : incoming.status,
                    timeline: existing.timeline.count >= incoming.timeline.count ? existing.timeline : incoming.timeline,
                    draftMessage: existing.draftMessage
                )
            }

            if selectedChannelID == nil {
                selectedChannelID = Self.loadSelectedSessionKey().flatMap { key in
                    channels.first(where: { $0.sessionKey == key })?.id
                } ?? channels.first?.id
            }
        } catch {
            errorMessage = "Could not load sessions: \(error.localizedDescription)"
            print("Alchemy Workspace: refresh channels failed: \(Self.describe(error: error))")
        }
    }

    public func createChannel(for agent: AgentSummary?) async {
        guard isConnected else {
            return
        }

        let title = Self.channelTitle(for: agent)
        await refreshChannels()

        if let existing = existingChannel(for: agent, title: title) {
            selectChannelID(existing.id)
            return
        }

        do {
            print("Alchemy Workspace: creating channel agent=\(agent?.id ?? "<default>")")
            let created = try await gateway.createSession(
                agentID: agent?.id,
                label: title
            )

            guard let sessionKey = GatewayWorkspaceParsing.parseSessionKey(created) else {
                errorMessage = "The gateway created a session but did not return a usable session key."
                print("Alchemy Workspace: create channel returned no session key payload=\(created)")
                return
            }

            _ = try await gateway.subscribeSessionMessages(key: sessionKey)
            print("Alchemy Workspace: created and subscribed session=\(sessionKey)")

            let channel = WorkspaceChannel(
                sessionKey: sessionKey,
                title: title,
                agentID: agent?.id,
                status: .live
            )

            channels.append(channel)
            selectChannelID(channel.id)
        } catch {
            if await recoverExistingChannel(title: title) {
                return
            }

            errorMessage = "Could not create channel: \(error.localizedDescription)"
            print("Alchemy Workspace: create channel failed: \(Self.describe(error: error))")
        }
    }

    private func recoverExistingChannel(title: String) async -> Bool {
        print("Alchemy Workspace: looking for existing channel title=\(title)")
        await refreshChannels()

        guard let existing = channels.first(where: { $0.title == title }) else {
            return false
        }

        _ = try? await gateway.subscribeSessionMessages(key: existing.sessionKey)
        selectChannelID(existing.id)
        errorMessage = nil
        print("Alchemy Workspace: selected existing channel session=\(existing.sessionKey)")
        return true
    }

    public func selectChannel(_ channel: WorkspaceChannel) {
        selectChannelID(channel.id)
    }

    public func updateDraft(_ text: String, for channelID: WorkspaceChannel.ID) {
        guard let index = channels.firstIndex(where: { $0.id == channelID }) else {
            return
        }

        channels[index].draftMessage = text
    }

    public func sendDraft(in channel: WorkspaceChannel) async {
        let message = channel.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return
        }

        await sendMessage(message, in: channel)
        updateDraft("", for: channel.id)
    }

    public func perform(_ action: ChannelButtonAction, in channel: WorkspaceChannel) async {
        switch action.intent {
        case .sendMessage(let message):
            await sendMessage(message, in: channel)
        case .resolveExecApproval(let id, let decision):
            do {
                _ = try await gateway.request(
                    method: "exec.approval.resolve",
                    params: .object([
                        "id": .string(id),
                        "decision": .string(decision),
                    ])
                )
            } catch {
                errorMessage = "Could not resolve approval: \(error.localizedDescription)"
            }
        case .resolvePluginApproval(let id, let decision):
            do {
                _ = try await gateway.request(
                    method: "plugin.approval.resolve",
                    params: .object([
                        "id": .string(id),
                        "decision": .string(decision),
                    ])
                )
            } catch {
                errorMessage = "Could not resolve plugin approval: \(error.localizedDescription)"
            }
        }
    }

    private func sendMessage(_ text: String, in channel: WorkspaceChannel) async {
        appendLocalUserMessage(text, to: channel.id)

        do {
            print("Alchemy Workspace: sending message session=\(channel.sessionKey) chars=\(text.count)")
            _ = try await gateway.sendSessionMessage(
                key: channel.sessionKey,
                message: text,
                idempotencyKey: UUID().uuidString.lowercased()
            )
        } catch {
            errorMessage = "Could not send message: \(error.localizedDescription)"
            markChannel(channel.id, status: .error)
            print("Alchemy Workspace: send message failed: \(Self.describe(error: error))")
        }
    }

    private func appendLocalUserMessage(_ text: String, to channelID: WorkspaceChannel.ID) {
        guard let index = channels.firstIndex(where: { $0.id == channelID }) else {
            return
        }

        channels[index].timeline.append(
            ChannelTimelineItem(
                id: "local-user:\(UUID().uuidString.lowercased())",
                kind: .message(
                    ChannelMessage(
                        id: UUID().uuidString.lowercased(),
                        role: .user,
                        text: text,
                        isStreaming: false
                    )
                )
            )
        )
    }

    private func markChannel(_ channelID: WorkspaceChannel.ID, status: WorkspaceChannel.Status) {
        guard let index = channels.firstIndex(where: { $0.id == channelID }) else {
            return
        }

        channels[index].status = status
    }

    private func existingChannel(for agent: AgentSummary?, title: String) -> WorkspaceChannel? {
        if let agent, let existing = channels.first(where: { $0.agentID == agent.id }) {
            return existing
        }

        return channels.first(where: { $0.title == title })
    }

    private func selectChannelID(_ id: WorkspaceChannel.ID) {
        selectedChannelID = id
        UserDefaults.standard.set(id, forKey: Self.selectedSessionKeyDefaultsKey)
    }

    private func startEventLoop() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            let stream = await gateway.events()

            for await event in stream {
                print("Alchemy Gateway event: name=\(event.name) seq=\(event.sequence.map(String.init) ?? "<none>")")
                await self.handle(event: event)
            }
        }
    }

    private func handle(event: GatewayEvent) async {
        guard let envelope = GatewayWorkspaceParsing.parseSessionEvent(event) else {
            print("Alchemy Workspace: ignored event name=\(event.name) payload=\(event.payload ?? .null)")
            return
        }

        let channelIndex: Int
        if let existingIndex = channels.firstIndex(where: { $0.sessionKey == envelope.sessionKey }) {
            channelIndex = existingIndex
        } else {
            channels.append(
                WorkspaceChannel(
                    sessionKey: envelope.sessionKey,
                    title: "# \(envelope.sessionKey)",
                    status: .live
                )
            )
            channelIndex = channels.index(before: channels.endIndex)
        }

        channels[channelIndex].status = .live
        merge(envelope.item, into: &channels[channelIndex])

        if case .message(let message) = envelope.item.kind,
           let options = GatewayWorkspaceParsing.parseEmbeddedOptions(
            sessionKey: envelope.sessionKey,
            message: message,
            payload: event.payload
           ) {
            merge(options, into: &channels[channelIndex])
        }
    }

    private func merge(_ item: ChannelTimelineItem, into channel: inout WorkspaceChannel) {
        if let existingIndex = channel.timeline.firstIndex(where: { $0.id == item.id }) {
            switch (channel.timeline[existingIndex].kind, item.kind) {
            case (.message(let existing), .message(let incoming)):
                channel.timeline[existingIndex].kind = .message(
                    ChannelMessage(
                        id: incoming.id,
                        role: incoming.role,
                        text: mergeText(existing.text, incoming.text, streaming: incoming.isStreaming),
                        isStreaming: incoming.isStreaming
                    )
                )
            case (.tool, .tool):
                channel.timeline[existingIndex] = item
            case (.approval(let existing), .approval(let incoming)):
                channel.timeline[existingIndex].kind = .approval(
                    ChannelApprovalPrompt(
                        id: incoming.id,
                        title: incoming.title,
                        detail: incoming.detail ?? existing.detail,
                        sessionKey: incoming.sessionKey ?? existing.sessionKey,
                        kind: incoming.kind,
                        approveChoices: incoming.approveChoices.isEmpty ? existing.approveChoices : incoming.approveChoices,
                        denyChoice: incoming.denyChoice ?? existing.denyChoice,
                        resolvedChoiceID: incoming.resolvedChoiceID ?? existing.resolvedChoiceID
                    )
                )
            default:
                channel.timeline[existingIndex] = item
            }
            return
        }

        channel.timeline.append(item)
    }

    private func mergeText(_ existing: String, _ incoming: String, streaming: Bool) -> String {
        guard streaming else {
            return incoming
        }

        guard !incoming.isEmpty else {
            return existing
        }

        if existing.isEmpty {
            return incoming
        }

        if incoming.hasPrefix(existing) {
            return incoming
        }

        return existing + incoming
    }

    private func logConnectionDiagnostic(_ message: String) {
        connectionDiagnostics.append(ConnectionDiagnostic(message: message))
    }

    private static func bootstrapConfigurations(
        from setupCode: SetupCodePayload
    ) -> [GatewayConnectionConfiguration] {
        [
            GatewayConnectionConfiguration.bootstrap(from: setupCode),
            GatewayConnectionConfiguration(
                url: setupCode.url,
                client: GatewayClientDescriptor(
                    id: "node-host",
                    version: "0.1.0",
                    platform: "ios",
                    deviceFamily: "phone",
                    mode: .node
                ),
                role: .node,
                bootstrapToken: setupCode.bootstrapToken,
                locale: Locale.current.identifier,
                userAgent: "openclaw-ios/0.1.0"
            ),
            GatewayConnectionConfiguration(
                url: setupCode.url,
                client: GatewayClientDescriptor(
                    id: "ios-node",
                    version: "0.1.0",
                    platform: "ios",
                    deviceFamily: "phone",
                    mode: .node
                ),
                role: .node,
                bootstrapToken: setupCode.bootstrapToken,
                locale: Locale.current.identifier,
                userAgent: "openclaw-ios/0.1.0"
            ),
            GatewayConnectionConfiguration(
                url: setupCode.url,
                client: GatewayClientDescriptor(
                    id: "node",
                    version: "0.1.0",
                    platform: "ios",
                    deviceFamily: "phone",
                    mode: .node
                ),
                role: .node,
                bootstrapToken: setupCode.bootstrapToken,
                locale: Locale.current.identifier,
                userAgent: "openclaw-ios/0.1.0"
            ),
            GatewayConnectionConfiguration(
                url: setupCode.url,
                client: GatewayClientDescriptor(
                    id: "mobile",
                    version: "0.1.0",
                    platform: "ios",
                    deviceFamily: "phone",
                    mode: .node
                ),
                role: .node,
                bootstrapToken: setupCode.bootstrapToken,
                locale: Locale.current.identifier,
                userAgent: "openclaw-ios/0.1.0"
            ),
        ]
    }

    private static func operatorConfigurations(url: URL) -> [GatewayConnectionConfiguration] {
        [
            GatewayConnectionConfiguration.operator(url: url),
            GatewayConnectionConfiguration(
                url: url,
                client: GatewayClientDescriptor(
                    id: "operator",
                    version: "0.1.0",
                    platform: "ios",
                    deviceFamily: "phone",
                    mode: .operator
                ),
                role: .operator,
                scopes: operatorScopes,
                locale: Locale.current.identifier,
                userAgent: "openclaw-ios/0.1.0"
            ),
            GatewayConnectionConfiguration(
                url: url,
                client: GatewayClientDescriptor(
                    id: "ios",
                    version: "0.1.0",
                    platform: "ios",
                    deviceFamily: "phone",
                    mode: .operator
                ),
                role: .operator,
                scopes: operatorScopes,
                locale: Locale.current.identifier,
                userAgent: "openclaw-ios/0.1.0"
            ),
        ]
    }

    private static let operatorScopes = [
        "operator.approvals",
        "operator.read",
        "operator.talk.secrets",
        "operator.write",
    ]

    private static let selectedSessionKeyDefaultsKey = "ai.alchemy.selected-session-key"

    private static func channelTitle(for agent: AgentSummary?) -> String {
        let suffix = UUID().uuidString.prefix(6).lowercased()
        guard let agent else {
            return "# ios-test-\(suffix)"
        }

        let slug = agent.title
            .lowercased()
            .replacingOccurrences(
                of: "[^a-z0-9]+",
                with: "-",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return "# \(slug.isEmpty ? "agent" : slug)-ios-\(suffix)"
    }

    private static func loadSelectedSessionKey() -> String? {
        let value = UserDefaults.standard.string(forKey: selectedSessionKeyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func describeGatewayURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let hasQuery = components?.query != nil
        if hasQuery {
            components?.query = "<redacted>"
        }

        let sanitizedURL = components?.url?.absoluteString ?? url.absoluteString
        let host = url.host(percentEncoded: false) ?? "<missing host>"
        let port = url.port.map(String.init) ?? Self.defaultPort(for: url.scheme)

        return "\(sanitizedURL) [scheme=\(url.scheme ?? "<missing>"), host=\(host), port=\(port)]"
    }

    private static func defaultPort(for scheme: String?) -> String {
        switch scheme?.lowercased() {
        case "ws":
            return "80"
        case "wss":
            return "443"
        default:
            return "<default>"
        }
    }

    private static func describe(error: Error) -> String {
        let nsError = error as NSError
        var parts = [
            String(reflecting: error),
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
        ]

        if let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            parts.append("url=\(describeGatewayURL(failingURL))")
        } else if let failingURLString = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
            parts.append("url=\(failingURLString)")
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=\(underlying.domain)/\(underlying.code)")
        }

        return parts.joined(separator: " | ")
    }
}
