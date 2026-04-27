import Foundation

public struct ConnectionDiagnostic: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), message: String) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
    }
}

public struct AgentSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?

    public init(id: String, title: String, subtitle: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

public struct WorkspaceChannel: Identifiable, Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case idle
        case connecting
        case live
        case error
    }

    public var id: String { sessionKey }
    public var sessionKey: String
    public var title: String
    public var agentID: String?
    public var status: Status
    public var timeline: [ChannelTimelineItem]
    public var draftMessage: String

    public var displayName: String {
        title.hasPrefix("# ") ? String(title.dropFirst(2)) : title
    }

    public init(
        sessionKey: String,
        title: String,
        agentID: String? = nil,
        status: Status = .idle,
        timeline: [ChannelTimelineItem] = [],
        draftMessage: String = ""
    ) {
        self.sessionKey = sessionKey
        self.title = title
        self.agentID = agentID
        self.status = status
        self.timeline = timeline
        self.draftMessage = draftMessage
    }
}

public struct ChannelTimelineItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case message(ChannelMessage)
        case tool(ChannelToolActivity)
        case approval(ChannelApprovalPrompt)
        case options(ChannelOptionPrompt)
    }

    public var id: String
    public var createdAt: Date
    public var kind: Kind

    public init(id: String, createdAt: Date = Date(), kind: Kind) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
    }
}

public struct ChannelMessage: Equatable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case user
        case assistant
        case system
    }

    public var id: String
    public var role: Role
    public var text: String
    public var isStreaming: Bool

    public init(id: String, role: Role, text: String, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
    }
}

public struct ChannelToolActivity: Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String?
    public var status: String
    public var isStreaming: Bool

    public init(
        id: String,
        title: String,
        detail: String? = nil,
        status: String,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.isStreaming = isStreaming
    }
}

public struct ChannelApprovalPrompt: Equatable, Sendable {
    public enum ApprovalKind: Equatable, Sendable {
        case exec
        case plugin
    }

    public var id: String
    public var title: String
    public var detail: String?
    public var sessionKey: String?
    public var kind: ApprovalKind
    public var approveChoices: [ChannelButtonAction]
    public var denyChoice: ChannelButtonAction?
    public var resolvedChoiceID: String?

    public init(
        id: String,
        title: String,
        detail: String? = nil,
        sessionKey: String? = nil,
        kind: ApprovalKind,
        approveChoices: [ChannelButtonAction],
        denyChoice: ChannelButtonAction? = nil,
        resolvedChoiceID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.sessionKey = sessionKey
        self.kind = kind
        self.approveChoices = approveChoices
        self.denyChoice = denyChoice
        self.resolvedChoiceID = resolvedChoiceID
    }
}

public struct ChannelOptionPrompt: Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String?
    public var options: [ChannelButtonAction]

    public init(id: String, title: String, detail: String? = nil, options: [ChannelButtonAction]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.options = options
    }
}

public struct ChannelButtonAction: Identifiable, Equatable, Sendable {
    public enum Style: String, Equatable, Sendable {
        case primary
        case secondary
        case success
        case danger
    }

    public enum Intent: Equatable, Sendable {
        case sendMessage(String)
        case resolveExecApproval(id: String, decision: String)
        case resolvePluginApproval(id: String, decision: String)
    }

    public var id: String
    public var title: String
    public var style: Style
    public var intent: Intent

    public init(id: String, title: String, style: Style, intent: Intent) {
        self.id = id
        self.title = title
        self.style = style
        self.intent = intent
    }
}

// MARK: - Folders

public struct ChannelFolder: Identifiable, Equatable, Sendable, Codable {
    public var id: String
    public var name: String
    public var isArchive: Bool
    public var isCollapsed: Bool

    public init(id: String, name: String, isArchive: Bool = false, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.isArchive = isArchive
        self.isCollapsed = isCollapsed
    }

    public static let archive = ChannelFolder(
        id: "archive",
        name: "Archive",
        isArchive: true,
        isCollapsed: true
    )
}

public struct FolderConfiguration: Codable, Equatable, Sendable {
    public var folders: [ChannelFolder]
    public var channelFolderMap: [String: String]
    public var channelNameOverrides: [String: String]

    public init(
        folders: [ChannelFolder] = [.archive],
        channelFolderMap: [String: String] = [:],
        channelNameOverrides: [String: String] = [:]
    ) {
        self.folders = folders
        self.channelFolderMap = channelFolderMap
        self.channelNameOverrides = channelNameOverrides
    }
}

public struct SessionStreamEnvelope: Equatable, Sendable {
    public var sessionKey: String
    public var item: ChannelTimelineItem

    public init(sessionKey: String, item: ChannelTimelineItem) {
        self.sessionKey = sessionKey
        self.item = item
    }
}
