import Foundation
import Observation

@Observable
@MainActor
public final class DiscordWorkspaceViewModel {
    public private(set) var channels: [WorkspaceChannel] = []
    public private(set) var selectedChannelID: WorkspaceChannel.ID?
    public private(set) var availableAgents: [AgentSummary] = []
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

            _ = try await gateway.connect(configuration: .bootstrap(from: setupCode))
            await gateway.disconnect()

            let operatorConfiguration = GatewayConnectionConfiguration.operator(url: setupCode.url)
            _ = try await gateway.connect(configuration: operatorConfiguration)
            self.operatorConfiguration = operatorConfiguration
            isConnected = true

            startEventLoop()
            await refreshAgents()
            await refreshChannels()
        } catch {
            isConnected = false
            errorMessage = "Gateway connection failed: \(error.localizedDescription)"
        }
    }

    public func refreshAgents() async {
        guard isConnected else {
            return
        }

        isLoadingAgents = true
        defer { isLoadingAgents = false }

        do {
            availableAgents = GatewayWorkspaceParsing.parseAgentSummaries(try await gateway.listAgents())
        } catch {
            errorMessage = "Could not load agents: \(error.localizedDescription)"
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
            let payload = try await gateway.listSessions(limit: 50)
            let existingChannels = channels
            let parsed = GatewayWorkspaceParsing.parseChannels(payload)

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
                selectedChannelID = channels.first?.id
            }
        } catch {
            errorMessage = "Could not load sessions: \(error.localizedDescription)"
        }
    }

    public func createChannel(for agent: AgentSummary?) async {
        guard isConnected else {
            return
        }

        let title = agent.map { "# \($0.title.lowercased().replacingOccurrences(of: " ", with: "-"))" } ??
            "# new-channel"

        do {
            let created = try await gateway.createSession(
                agentID: agent?.id,
                label: title,
                message: "Start this channel for \(agent?.title ?? "the default agent")."
            )

            guard let sessionKey = GatewayWorkspaceParsing.parseSessionKey(created) else {
                errorMessage = "The gateway created a session but did not return a usable session key."
                return
            }

            _ = try await gateway.subscribeSessionMessages(key: sessionKey)

            let channel = WorkspaceChannel(
                sessionKey: sessionKey,
                title: title,
                agentID: agent?.id,
                status: .live
            )

            channels.append(channel)
            selectedChannelID = channel.id
        } catch {
            errorMessage = "Could not create channel: \(error.localizedDescription)"
        }
    }

    public func selectChannel(_ channel: WorkspaceChannel) {
        selectedChannelID = channel.id
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
            _ = try await gateway.sendSessionMessage(
                key: channel.sessionKey,
                message: text,
                idempotencyKey: UUID().uuidString.lowercased()
            )
        } catch {
            errorMessage = "Could not send message: \(error.localizedDescription)"
            markChannel(channel.id, status: .error)
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

    private func startEventLoop() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            let stream = await gateway.events()

            for await event in stream {
                await self.handle(event: event)
            }
        }
    }

    private func handle(event: GatewayEvent) async {
        guard let envelope = GatewayWorkspaceParsing.parseSessionEvent(event) else {
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
}
