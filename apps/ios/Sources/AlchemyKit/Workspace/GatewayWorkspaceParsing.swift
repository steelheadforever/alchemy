import Foundation

enum GatewayWorkspaceParsing {
    static func parseAgentSummaries(_ value: JSONValue) -> [AgentSummary] {
        let candidates: [JSONValue]
        if let array = value.arrayValue {
            candidates = array
        } else if let array = value["agents"]?.arrayValue {
            candidates = array
        } else if let array = value["items"]?.arrayValue {
            candidates = array
        } else {
            candidates = []
        }

        return candidates.compactMap { item in
            let id = item["id"]?.stringValue ?? item["agentId"]?.stringValue
            let title = item["title"]?.stringValue ?? item["name"]?.stringValue ?? id

            guard let id, let title else {
                return nil
            }

            return AgentSummary(
                id: id,
                title: title,
                subtitle: item["description"]?.stringValue ?? item["identity"]?.stringValue
            )
        }
    }

    static func parseChannels(_ value: JSONValue) -> [WorkspaceChannel] {
        let candidates: [JSONValue]
        if let array = value.arrayValue {
            candidates = array
        } else if let array = value["sessions"]?.arrayValue {
            candidates = array
        } else if let array = value["items"]?.arrayValue {
            candidates = array
        } else if let array = value["entries"]?.arrayValue {
            candidates = array
        } else {
            candidates = []
        }

        return candidates.compactMap { item in
            guard let sessionKey = parseSessionKey(item) else {
                return nil
            }

            let title =
                item["groupChannel"]?.stringValue ??
                item["label"]?.stringValue ??
                item["displayName"]?.stringValue ??
                item["title"]?.stringValue ??
                item["name"]?.stringValue ??
                "# \(sessionKey)"

            var timeline: [ChannelTimelineItem] = []
            if let lastMessage = parseLastMessage(item["lastMessage"] ?? item["lastMessagePreview"], sessionKey: sessionKey) {
                timeline.append(lastMessage)
            }

            return WorkspaceChannel(
                sessionKey: sessionKey,
                title: normalizeChannelTitle(title),
                agentID: item["agentId"]?.stringValue ?? item["agent"]?["id"]?.stringValue,
                status: .live,
                timeline: timeline
            )
        }
    }

    static func parseSessionKey(_ value: JSONValue) -> String? {
        value["key"]?.stringValue ??
        value["sessionKey"]?.stringValue ??
        value["entry"]?["key"]?.stringValue ??
        value["session"]?["key"]?.stringValue
    }

    static func parseSessionEvent(_ event: GatewayEvent) -> SessionStreamEnvelope? {
        switch event.name {
        case "session.message":
            return parseSessionMessage(event.payload)
        case "agent":
            return parseAgentEvent(event.payload)
        case "chat":
            return parseChatEvent(event.payload)
        case "session.tool":
            return parseSessionTool(event.payload)
        case "exec.approval.requested":
            return parseExecApprovalRequest(event.payload)
        case "exec.approval.resolved":
            return parseExecApprovalResolved(event.payload)
        case "plugin.approval.requested":
            return parsePluginApprovalRequest(event.payload)
        case "plugin.approval.resolved":
            return parsePluginApprovalResolved(event.payload)
        default:
            return nil
        }
    }

    private static func parseSessionMessage(_ payload: JSONValue?) -> SessionStreamEnvelope? {
        guard let sessionKey = parseSessionKeyFromPayload(payload) else {
            return nil
        }

        let roleString =
            payload?["role"]?.stringValue ??
            payload?["message"]?["role"]?.stringValue ??
            "assistant"

        let role = ChannelMessage.Role(rawValue: roleString) ?? .assistant
        let content =
            payload?["delta"]?.stringValue ??
            payload?["text"]?.stringValue ??
            payload?["content"]?.stringValue ??
            payload?["message"]?["text"]?.stringValue ??
            payload?["message"]?["content"]?.stringValue ??
            payload?["message"]?["delta"]?.stringValue ??
            ""

        let messageID =
            payload?["messageId"]?.stringValue ??
            payload?["message"]?["id"]?.stringValue ??
            payload?["id"]?.stringValue ??
            UUID().uuidString.lowercased()

        let isStreaming = !(
            payload?["done"]?.boolValue ??
            payload?["message"]?["done"]?.boolValue ??
            false
        )

        let item = ChannelTimelineItem(
            id: "message:\(messageID)",
            kind: .message(
                ChannelMessage(
                    id: messageID,
                    role: role,
                    text: content,
                    isStreaming: isStreaming
                )
            )
        )

        return SessionStreamEnvelope(sessionKey: sessionKey, item: item)
    }

    private static func parseAgentEvent(_ payload: JSONValue?) -> SessionStreamEnvelope? {
        guard
            payload?["stream"]?.stringValue == "assistant",
            let sessionKey = parseSessionKeyFromPayload(payload)
        else {
            return nil
        }

        let text =
            payload?["data"]?["text"]?.stringValue ??
            payload?["data"]?["delta"]?.stringValue

        guard let text else {
            return nil
        }

        let runID = payload?["runId"]?.stringValue ?? UUID().uuidString.lowercased()
        let isStreaming = payload?["data"]?["done"]?.boolValue != true

        let item = ChannelTimelineItem(
            id: "message:agent:\(runID)",
            kind: .message(
                ChannelMessage(
                    id: "agent:\(runID)",
                    role: .assistant,
                    text: text,
                    isStreaming: isStreaming
                )
            )
        )

        return SessionStreamEnvelope(sessionKey: sessionKey, item: item)
    }

    private static func parseChatEvent(_ payload: JSONValue?) -> SessionStreamEnvelope? {
        guard let sessionKey = parseSessionKeyFromPayload(payload) else {
            return nil
        }

        let roleString = payload?["message"]?["role"]?.stringValue ?? "assistant"
        let role = ChannelMessage.Role(rawValue: roleString) ?? .assistant
        let text =
            payload?["message"]?["text"]?.stringValue ??
            payload?["message"]?["content"]?.stringValue ??
            parseContentText(payload?["message"]?["content"])

        guard let text else {
            return nil
        }

        let runID = payload?["runId"]?.stringValue ?? UUID().uuidString.lowercased()
        let isStreaming = payload?["state"]?.stringValue != "complete"

        let item = ChannelTimelineItem(
            id: "message:chat:\(runID)",
            kind: .message(
                ChannelMessage(
                    id: "chat:\(runID)",
                    role: role,
                    text: text,
                    isStreaming: isStreaming
                )
            )
        )

        return SessionStreamEnvelope(sessionKey: sessionKey, item: item)
    }

    private static func parseSessionTool(_ payload: JSONValue?) -> SessionStreamEnvelope? {
        guard let sessionKey = parseSessionKeyFromPayload(payload) else {
            return nil
        }

        let toolID =
            payload?["toolCallId"]?.stringValue ??
            payload?["id"]?.stringValue ??
            UUID().uuidString.lowercased()

        let title =
            payload?["toolName"]?.stringValue ??
            payload?["name"]?.stringValue ??
            payload?["request"]?["toolName"]?.stringValue ??
            "Tool activity"

        let detail =
            payload?["summary"]?.stringValue ??
            payload?["result"]?.stringValue ??
            payload?["output"]?.stringValue ??
            payload?["request"]?["commandText"]?.stringValue ??
            payload?["request"]?["description"]?.stringValue

        let status =
            payload?["status"]?.stringValue ??
            payload?["phase"]?.stringValue ??
            payload?["state"]?.stringValue ??
            "running"

        let isStreaming = !["done", "resolved", "complete", "completed", "failed"].contains(status)

        let item = ChannelTimelineItem(
            id: "tool:\(toolID)",
            kind: .tool(
                ChannelToolActivity(
                    id: toolID,
                    title: title,
                    detail: detail,
                    status: status,
                    isStreaming: isStreaming
                )
            )
        )

        return SessionStreamEnvelope(sessionKey: sessionKey, item: item)
    }

    private static func parseExecApprovalRequest(_ payload: JSONValue?) -> SessionStreamEnvelope? {
        guard
            let approvalID = payload?["id"]?.stringValue,
            let request = payload?["request"]
        else {
            return nil
        }

        let sessionKey = request["sessionKey"]?.stringValue ?? "approvals"
        let title = request["commandPreview"]?.stringValue ?? request["command"]?.stringValue ?? "Execution approval"
        let detail = request["cwd"]?.stringValue ?? request["host"]?.stringValue
        let allowedDecisions = request["allowedDecisions"]?.arrayValue?.compactMap(\.stringValue) ?? ["allow", "deny"]

        let approveChoices = allowedDecisions
            .filter { $0 != "deny" }
            .map { decision in
                ChannelButtonAction(
                    id: "exec:\(approvalID):\(decision)",
                    title: titleForDecision(decision),
                    style: decision == "allow-always" ? .secondary : .success,
                    intent: .resolveExecApproval(id: approvalID, decision: decision)
                )
            }

        let denyChoice: ChannelButtonAction? =
            allowedDecisions.contains("deny")
            ? ChannelButtonAction(
                id: "exec:\(approvalID):deny",
                title: "Deny",
                style: .danger,
                intent: .resolveExecApproval(id: approvalID, decision: "deny")
            )
            : nil

        let item = ChannelTimelineItem(
            id: "approval:exec:\(approvalID)",
            kind: .approval(
                ChannelApprovalPrompt(
                    id: approvalID,
                    title: title,
                    detail: detail,
                    sessionKey: request["sessionKey"]?.stringValue,
                    kind: .exec,
                    approveChoices: approveChoices,
                    denyChoice: denyChoice
                )
            )
        )

        return SessionStreamEnvelope(sessionKey: sessionKey, item: item)
    }

    private static func parsePluginApprovalRequest(_ payload: JSONValue?) -> SessionStreamEnvelope? {
        guard
            let approvalID = payload?["id"]?.stringValue,
            let request = payload?["request"]
        else {
            return nil
        }

        let sessionKey = request["sessionKey"]?.stringValue ?? "approvals"
        let title = request["title"]?.stringValue ?? "Plugin approval"
        let detail = request["description"]?.stringValue

        let approveChoice = ChannelButtonAction(
            id: "plugin:\(approvalID):allow",
            title: "Allow",
            style: .success,
            intent: .resolvePluginApproval(id: approvalID, decision: "allow")
        )
        let denyChoice = ChannelButtonAction(
            id: "plugin:\(approvalID):deny",
            title: "Deny",
            style: .danger,
            intent: .resolvePluginApproval(id: approvalID, decision: "deny")
        )

        let item = ChannelTimelineItem(
            id: "approval:plugin:\(approvalID)",
            kind: .approval(
                ChannelApprovalPrompt(
                    id: approvalID,
                    title: title,
                    detail: detail,
                    sessionKey: request["sessionKey"]?.stringValue,
                    kind: .plugin,
                    approveChoices: [approveChoice],
                    denyChoice: denyChoice
                )
            )
        )

        return SessionStreamEnvelope(sessionKey: sessionKey, item: item)
    }

    private static func parseExecApprovalResolved(_ payload: JSONValue?) -> SessionStreamEnvelope? {
        guard let approvalID = payload?["id"]?.stringValue else {
            return nil
        }

        let sessionKey = payload?["request"]?["sessionKey"]?.stringValue ?? "approvals"
        let title = payload?["request"]?["commandPreview"]?.stringValue ??
            payload?["request"]?["command"]?.stringValue ??
            "Execution approval"
        let detail = "Resolved: \(payload?["decision"]?.stringValue ?? "done")"

        let item = ChannelTimelineItem(
            id: "approval:exec:\(approvalID)",
            kind: .approval(
                ChannelApprovalPrompt(
                    id: approvalID,
                    title: title,
                    detail: detail,
                    sessionKey: payload?["request"]?["sessionKey"]?.stringValue,
                    kind: .exec,
                    approveChoices: [],
                    denyChoice: nil,
                    resolvedChoiceID: payload?["decision"]?.stringValue
                )
            )
        )

        return SessionStreamEnvelope(sessionKey: sessionKey, item: item)
    }

    private static func parsePluginApprovalResolved(_ payload: JSONValue?) -> SessionStreamEnvelope? {
        guard let approvalID = payload?["id"]?.stringValue else {
            return nil
        }

        let sessionKey = payload?["request"]?["sessionKey"]?.stringValue ?? "approvals"
        let title = payload?["request"]?["title"]?.stringValue ?? "Plugin approval"
        let detail = "Resolved: \(payload?["decision"]?.stringValue ?? "done")"

        let item = ChannelTimelineItem(
            id: "approval:plugin:\(approvalID)",
            kind: .approval(
                ChannelApprovalPrompt(
                    id: approvalID,
                    title: title,
                    detail: detail,
                    sessionKey: payload?["request"]?["sessionKey"]?.stringValue,
                    kind: .plugin,
                    approveChoices: [],
                    denyChoice: nil,
                    resolvedChoiceID: payload?["decision"]?.stringValue
                )
            )
        )

        return SessionStreamEnvelope(sessionKey: sessionKey, item: item)
    }

    static func parseEmbeddedOptions(sessionKey: String, message: ChannelMessage, payload: JSONValue?) -> ChannelTimelineItem? {
        let options =
            payload?["suggestedReplies"]?.arrayValue ??
            payload?["options"]?.arrayValue ??
            payload?["choices"]?.arrayValue ??
            payload?["message"]?["suggestedReplies"]?.arrayValue ??
            []

        let actions = options.compactMap(parseOptionAction)
        guard !actions.isEmpty else {
            return nil
        }

        return ChannelTimelineItem(
            id: "options:\(message.id)",
            kind: .options(
                ChannelOptionPrompt(
                    id: message.id,
                    title: "Reply options",
                    detail: "Choose a response or keep typing below.",
                    options: actions
                )
            )
        )
    }

    private static func parseOptionAction(_ value: JSONValue) -> ChannelButtonAction? {
        if let text = value.stringValue {
            return ChannelButtonAction(
                id: "option:\(UUID().uuidString.lowercased())",
                title: text,
                style: .secondary,
                intent: .sendMessage(text)
            )
        }

        guard let object = value.objectValue else {
            return nil
        }

        let title = object["label"]?.stringValue ?? object["title"]?.stringValue ?? object["text"]?.stringValue
        let message = object["message"]?.stringValue ?? object["value"]?.stringValue ?? title

        guard let title, let message else {
            return nil
        }

        return ChannelButtonAction(
            id: object["id"]?.stringValue ?? "option:\(UUID().uuidString.lowercased())",
            title: title,
            style: .secondary,
            intent: .sendMessage(message)
        )
    }

    private static func parseSessionKeyFromPayload(_ payload: JSONValue?) -> String? {
        payload?["sessionKey"]?.stringValue ??
        payload?["key"]?.stringValue ??
        payload?["session"]?["key"]?.stringValue ??
        payload?["request"]?["sessionKey"]?.stringValue
    }

    private static func parseContentText(_ value: JSONValue?) -> String? {
        if let text = value?.stringValue {
            return text
        }

        return value?.arrayValue?
            .compactMap { item in
                item["text"]?.stringValue
            }
            .joined()
    }

    private static func parseLastMessage(_ value: JSONValue?, sessionKey: String) -> ChannelTimelineItem? {
        guard let value else {
            return nil
        }

        if let text = value.stringValue {
            return ChannelTimelineItem(
                id: "message:last:\(sessionKey)",
                kind: .message(
                    ChannelMessage(
                        id: "last:\(sessionKey)",
                        role: .assistant,
                        text: text
                    )
                )
            )
        }

        let role = ChannelMessage.Role(rawValue: value["role"]?.stringValue ?? "assistant") ?? .assistant
        let text =
            value["text"]?.stringValue ??
            value["content"]?.stringValue ??
            value["delta"]?.stringValue

        guard let text else {
            return nil
        }

        return ChannelTimelineItem(
            id: "message:\(value["id"]?.stringValue ?? "last:\(sessionKey)")",
            kind: .message(
                ChannelMessage(
                    id: value["id"]?.stringValue ?? "last:\(sessionKey)",
                    role: role,
                    text: text
                )
            )
        )
    }

    private static func normalizeChannelTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "# channel"
        }

        return trimmed.hasPrefix("#") ? trimmed : "# \(trimmed)"
    }

    private static func titleForDecision(_ decision: String) -> String {
        switch decision {
        case "allow":
            return "Allow"
        case "allow-always":
            return "Always Allow"
        default:
            return decision.capitalized
        }
    }
}
