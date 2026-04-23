import Foundation
import Testing
@testable import AlchemyKit

struct WorkspaceParsingTests {
    @Test
    func parsesAgentListPayload() throws {
        let payload = try JSONValue.decode(
            from: #"{"agents":[{"id":"agent-alpha","title":"Alpha","description":"Writes code"}]}"#
        )

        let agents = GatewayWorkspaceParsing.parseAgentSummaries(payload)

        #expect(agents.count == 1)
        #expect(agents.first?.id == "agent-alpha")
        #expect(agents.first?.title == "Alpha")
    }

    @Test
    func parsesSessionCreateResponseKey() throws {
        let payload = try JSONValue.decode(from: #"{"entry":{"key":"session-123"}}"#)
        #expect(GatewayWorkspaceParsing.parseSessionKey(payload) == "session-123")
    }

    @Test
    func parsesSessionListIntoChannels() throws {
        let payload = try JSONValue.decode(
            from: #"""
            {
              "sessions": [
                {
                  "key": "session-123",
                  "label": "build-bot",
                  "agentId": "agent-alpha",
                  "lastMessage": {
                    "id": "message-9",
                    "role": "assistant",
                    "text": "Build finished successfully."
                  }
                }
              ]
            }
            """#
        )

        let channels = GatewayWorkspaceParsing.parseChannels(payload)

        #expect(channels.count == 1)
        #expect(channels.first?.sessionKey == "session-123")
        #expect(channels.first?.title == "# build-bot")
        #expect(channels.first?.agentID == "agent-alpha")

        if case .message(let message)? = channels.first?.timeline.first?.kind {
            #expect(message.text == "Build finished successfully.")
            #expect(message.role == .assistant)
        } else {
            Issue.record("Expected the last message to hydrate channel history")
        }
    }

    @Test
    func parsesSessionMessageStreamingEvent() throws {
        let payload = try JSONValue.decode(
            from: #"{"key":"session-1","messageId":"m-1","role":"assistant","delta":"hello","done":false}"#
        )

        let envelope = GatewayWorkspaceParsing.parseSessionEvent(
            GatewayEvent(name: "session.message", payload: payload, sequence: 1)
        )

        #expect(envelope?.sessionKey == "session-1")
        if case .message(let message)? = envelope?.item.kind {
            #expect(message.text == "hello")
            #expect(message.isStreaming == true)
            #expect(message.role == .assistant)
        } else {
            Issue.record("Expected a message timeline item")
        }
    }

    @Test
    func parsesExecApprovalIntoButtons() throws {
        let payload = try JSONValue.decode(
            from: #"""
            {
              "id":"approval-1",
              "request":{
                "sessionKey":"session-approvals",
                "command":"rm -rf /tmp/demo",
                "allowedDecisions":["allow","allow-always","deny"]
              }
            }
            """#
        )

        let envelope = GatewayWorkspaceParsing.parseSessionEvent(
            GatewayEvent(name: "exec.approval.requested", payload: payload, sequence: 2)
        )

        #expect(envelope?.sessionKey == "session-approvals")
        if case .approval(let prompt)? = envelope?.item.kind {
            #expect(prompt.approveChoices.count == 2)
            #expect(prompt.denyChoice?.title == "Deny")
        } else {
            Issue.record("Expected an approval timeline item")
        }
    }

    @Test
    func parsesSuggestedRepliesIntoOptionPrompt() throws {
        let message = ChannelMessage(id: "message-1", role: .assistant, text: "Choose one", isStreaming: false)
        let payload = try JSONValue.decode(
            from: #"{"suggestedReplies":["Ship it","Tell me more"]}"#
        )

        let item = GatewayWorkspaceParsing.parseEmbeddedOptions(
            sessionKey: "session-1",
            message: message,
            payload: payload
        )

        if case .options(let prompt)? = item?.kind {
            #expect(prompt.options.count == 2)
            #expect(prompt.options.first?.title == "Ship it")
        } else {
            Issue.record("Expected an option prompt")
        }
    }
}
