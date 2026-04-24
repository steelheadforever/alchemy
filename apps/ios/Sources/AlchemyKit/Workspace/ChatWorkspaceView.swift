import SwiftUI

public struct ChatWorkspaceView: View {
    @State private var model: ChatWorkspaceViewModel

    public init(model: ChatWorkspaceViewModel = ChatWorkspaceViewModel()) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { model.selectedChannelID },
            set: { newValue in
                guard
                    let id = newValue,
                    let channel = model.channels.first(where: { $0.id == id })
                else { return }
                model.selectChannel(channel)
            }
        )) {
            Section("Agents") {
                if model.isLoadingAgents {
                    ProgressView("Loading agents...")
                } else if model.availableAgents.isEmpty {
                    Text("No agents loaded")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.availableAgents) { agent in
                        Button {
                            Task { await model.createChannel(for: agent) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.title)
                                if let subtitle = agent.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            Section("Channels") {
                ForEach(model.channels) { channel in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(color(for: channel.status))
                            .frame(width: 8, height: 8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(channel.title)
                            Text(channel.sessionKey)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(channel.id)
                }
            }

            Section("Connection") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 8, height: 8)
                    Text(connectionLabel)

                    if model.connectionState == .connecting {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button(role: .destructive) {
                    Task { await model.unpair() }
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            }
        }
        .navigationTitle("Channels")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    Task {
                        await model.refreshAgents()
                        await model.refreshChannels()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!model.isConnected)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.createChannel(for: model.availableAgents.first) }
                } label: {
                    Label("Add Channel", systemImage: "plus")
                }
                .disabled(!model.isConnected || model.availableAgents.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let channel = model.selectedChannel {
            ChannelChatView(
                channel: channel,
                onDraftChanged: { model.updateDraft($0, for: channel.id) },
                onSend: { Task { await model.sendDraft(in: channel) } },
                onAction: { action in Task { await model.perform(action, in: channel) } }
            )
            .navigationTitle(channel.title)
        } else {
            ContentUnavailableView(
                "No Channel Selected",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Create a channel for an agent from the left sidebar.")
            )
        }
    }

    private var connectionColor: Color {
        switch model.connectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected, .unknown: return .red
        }
    }

    private var connectionLabel: String {
        switch model.connectionState {
        case .connected: return "Connected"
        case .connecting: return "Reconnecting…"
        case .disconnected: return "Disconnected"
        case .unknown: return "Unknown"
        }
    }

    private func color(for status: WorkspaceChannel.Status) -> Color {
        switch status {
        case .idle:
            return .secondary
        case .connecting:
            return .orange
        case .live:
            return .green
        case .error:
            return .red
        }
    }
}

private struct ChannelChatView: View {
    let channel: WorkspaceChannel
    let onDraftChanged: @MainActor (String) -> Void
    let onSend: @MainActor () -> Void
    let onAction: @MainActor (ChannelButtonAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(channel.timeline) { item in
                            TimelineItemView(item: item, onAction: onAction)
                                .id(item.id)
                        }
                    }
                    .padding(16)
                }
                .background(Color.secondary.opacity(0.06))
                .onChange(of: channel.timeline.count) { _, _ in
                    if let last = channel.timeline.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            HStack(alignment: .bottom, spacing: 12) {
                TextField("Message \(channel.title)", text: .init(
                    get: { channel.draftMessage },
                    set: { newValue in
                        onDraftChanged(newValue)
                    }
                ), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)

                Button("Send", action: onSend)
                    .buttonStyle(.borderedProminent)
                    .disabled(channel.status == .connecting)
            }
            .padding(16)
            .background(.thinMaterial)
        }
    }
}

private struct TimelineItemView: View {
    let item: ChannelTimelineItem
    let onAction: @MainActor (ChannelButtonAction) -> Void

    var body: some View {
        switch item.kind {
        case .message(let message):
            MessageBubbleView(message: message)
        case .tool(let tool):
            ToolActivityView(tool: tool)
        case .approval(let approval):
            ApprovalPromptView(prompt: approval, onAction: onAction)
        case .options(let prompt):
            OptionPromptView(prompt: prompt, onAction: onAction)
        }
    }
}

private struct MessageBubbleView: View {
    let message: ChannelMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(message.text.isEmpty && message.isStreaming ? "…" : message.text)
                    .textSelection(.enabled)
                if message.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(12)
            .frame(maxWidth: 580, alignment: .leading)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            if message.role != .user {
                Spacer(minLength: 40)
            }
        }
    }

    private var title: String {
        switch message.role {
        case .assistant:
            return "Agent"
        case .user:
            return "You"
        case .system:
            return "System"
        }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .assistant:
            return Color.secondary.opacity(0.12)
        case .user:
            return Color.blue.opacity(0.15)
        case .system:
            return Color.orange.opacity(0.15)
        }
    }
}

private struct ToolActivityView: View {
    let tool: ChannelToolActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(tool.title, systemImage: "wrench.and.screwdriver")
                .font(.subheadline.weight(.semibold))

            if let detail = tool.detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text(tool.status)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: Capsule())

                if tool.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 580, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ApprovalPromptView: View {
    let prompt: ChannelApprovalPrompt
    let onAction: @MainActor (ChannelButtonAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(prompt.title, systemImage: prompt.kind == .exec ? "shield.lefthalf.filled" : "puzzlepiece.extension")
                .font(.headline)

            if let detail = prompt.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
            }

            if let resolved = prompt.resolvedChoiceID {
                Text("Resolved: \(resolved)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    ForEach(prompt.approveChoices) { action in
                        ApprovalActionButton(action: action, onAction: onAction)
                    }

                    if let denyChoice = prompt.denyChoice {
                        ApprovalActionButton(action: denyChoice, onAction: onAction)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 620, alignment: .leading)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct OptionPromptView: View {
    let prompt: ChannelOptionPrompt
    let onAction: @MainActor (ChannelButtonAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt.title)
                .font(.headline)

            if let detail = prompt.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
            }

            FlowLayout(spacing: 8) {
                ForEach(prompt.options) { option in
                    Button(option.title) { onAction(option) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 620, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ApprovalActionButton: View {
    let action: ChannelButtonAction
    let onAction: @MainActor (ChannelButtonAction) -> Void

    var body: some View {
        switch action.style {
        case .primary:
            Button(action.title) { onAction(action) }
                .buttonStyle(.borderedProminent)
        case .success:
            Button(action.title) { onAction(action) }
                .buttonStyle(.borderedProminent)
                .tint(.green)
        case .secondary:
            Button(action.title) { onAction(action) }
                .buttonStyle(.bordered)
        case .danger:
            Button(action.title) { onAction(action) }
                .buttonStyle(.bordered)
                .tint(.red)
        }
    }
}

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
    }
}

#Preview {
    let model = ChatWorkspaceViewModel()
    return ChatWorkspaceView(model: model)
}
