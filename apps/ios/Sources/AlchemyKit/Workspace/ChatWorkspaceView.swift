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

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding(
            get: { model.selectedChannelID },
            set: { newValue in
                guard
                    let id = newValue,
                    let channel = model.channels.first(where: { $0.id == id })
                else {
                    model.deselectChannel()
                    return
                }
                model.selectChannel(channel)
            }
        )) {
            Section {
                ForEach(model.channels) { channel in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(color(for: channel.status))
                            .frame(width: 6, height: 6)

                        Text(channel.displayName)
                            .font(.callout)
                            .lineLimit(1)
                    }
                    .tag(channel.id)
                }
            } header: {
                Text("Channels")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Section {
                if model.isLoadingAgents {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(model.availableAgents) { agent in
                        Button {
                            Task { await model.createChannel(for: agent) }
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(AlchemyTheme.accent.opacity(0.3))
                                    .frame(width: 6, height: 6)
                                Text(agent.title)
                                    .font(.callout)
                            }
                        }
                    }
                }
            } header: {
                Text("Agents")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 6, height: 6)
                    Text(connectionLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if model.connectionState == .connecting {
                        Spacer()
                        ProgressView()
                            .controlSize(.mini)
                    }
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                Button(role: .destructive) {
                    Task { await model.unpair() }
                } label: {
                    Text("Disconnect")
                        .font(.caption)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("alchemy")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        Task { await model.createChannel(for: model.availableAgents.first) }
                    } label: {
                        Label("New Channel", systemImage: "plus")
                    }
                    .disabled(!model.isConnected || model.availableAgents.isEmpty)

                    Button {
                        Task {
                            await model.refreshAgents()
                            await model.refreshChannels()
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(!model.isConnected)
                } label: {
                    Image(systemName: "plus")
                        .font(.callout.weight(.medium))
                }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let channel = model.selectedChannel {
            ChannelChatView(
                channel: channel,
                onDraftChanged: { model.updateDraft($0, for: channel.id) },
                onSend: { Task { await model.sendDraft(in: channel) } },
                onAction: { action in Task { await model.perform(action, in: channel) } }
            )
            .navigationTitle(channel.displayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } else {
            ZStack {
                AlchemyTheme.surfacePrimary
                    .ignoresSafeArea()
                VStack(spacing: 8) {
                    Text(">")
                        .font(.title.monospaced().weight(.bold))
                        .foregroundStyle(AlchemyTheme.accent.opacity(0.3))
                    Text("Select or create a channel")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var connectionColor: Color {
        switch model.connectionState {
        case .connected: return .green
        case .connecting: return AlchemyTheme.accent
        case .disconnected, .unknown: return .red
        }
    }

    private var connectionLabel: String {
        switch model.connectionState {
        case .connected: return "Connected"
        case .connecting: return "Reconnecting\u{2026}"
        case .disconnected: return "Disconnected"
        case .unknown: return "Unknown"
        }
    }

    private func color(for status: WorkspaceChannel.Status) -> Color {
        switch status {
        case .idle: return .secondary
        case .connecting: return AlchemyTheme.accent
        case .live: return .green
        case .error: return .red
        }
    }
}

// MARK: - Channel Chat

private struct ChannelChatView: View {
    let channel: WorkspaceChannel
    let onDraftChanged: @MainActor (String) -> Void
    let onSend: @MainActor () -> Void
    let onAction: @MainActor (ChannelButtonAction) -> Void

    @State private var scrollTask: Task<Void, Never>?

    private var pendingApproval: ChannelApprovalPrompt? {
        channel.timeline.lazy.compactMap { item in
            guard case .approval(let prompt) = item.kind,
                  prompt.resolvedChoiceID == nil else { return nil }
            return prompt
        }.first
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AlchemyTheme.feedSpacing) {
                        ForEach(channel.timeline) { item in
                            TimelineItemView(item: item, onAction: onAction)
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: channel.timeline.count) { _, _ in
                    scrollTask?.cancel()
                    scrollTask = Task {
                        try? await Task.sleep(for: .milliseconds(100))
                        guard !Task.isCancelled else { return }
                        if let last = channel.timeline.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            if let approval = pendingApproval {
                ApprovalFooterBar(prompt: approval, onAction: onAction)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            InputBar(
                placeholder: "Message",
                text: .init(
                    get: { channel.draftMessage },
                    set: { onDraftChanged($0) }
                ),
                isDisabled: channel.status == .connecting,
                onSend: onSend
            )
        }
        .animation(.easeInOut(duration: 0.25), value: pendingApproval?.id)
    }
}

// MARK: - Timeline

private struct TimelineItemView: View {
    let item: ChannelTimelineItem
    let onAction: @MainActor (ChannelButtonAction) -> Void

    var body: some View {
        switch item.kind {
        case .message(let message):
            MessageView(message: message)
        case .tool(let tool):
            ToolActivityView(tool: tool)
        case .approval(let approval):
            ApprovalContextView(prompt: approval)
        case .options(let prompt):
            OptionPromptView(prompt: prompt, onAction: onAction)
        }
    }
}

// MARK: - Messages

private struct MessageView: View {
    let message: ChannelMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        AlchemyTheme.surfaceTertiary,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
            }

        case .assistant:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(">")
                    .font(.callout.monospaced().weight(.bold))
                    .foregroundStyle(AlchemyTheme.accent)

                TypewriterText(text: message.text, isStreaming: message.isStreaming)
                    .font(.callout)

                Spacer(minLength: 0)
            }

        case .system:
            HStack(spacing: 4) {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Typewriter

private struct TypewriterText: View {
    let text: String
    let isStreaming: Bool

    @State private var revealedCount = 0

    var body: some View {
        let displayText: String = if !isStreaming {
            text
        } else if text.isEmpty {
            ""
        } else {
            String(text.prefix(revealedCount))
        }

        Text(displayText)
            .textSelection(.enabled)
            .task(id: isStreaming ? text.count : -1) {
                guard isStreaming, revealedCount < text.count else { return }
                while revealedCount < text.count {
                    let pending = text.count - revealedCount
                    let step = max(1, pending / 6)
                    revealedCount = min(revealedCount + step, text.count)
                    try? await Task.sleep(for: .milliseconds(16))
                    guard !Task.isCancelled else { return }
                }
            }
            .onChange(of: isStreaming) { _, streaming in
                if !streaming {
                    revealedCount = text.count
                }
            }
    }
}

// MARK: - Tool Activity

private struct ToolActivityView: View {
    let tool: ChannelToolActivity

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tool.isStreaming ? AlchemyTheme.accent : .green)
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.title)
                        .font(.caption.weight(.medium))

                    Spacer()

                    Text(tool.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if tool.isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }

                if let detail = tool.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.leading, 8)
            .padding(.vertical, 4)
            .padding(.trailing, 8)
        }
        .padding(.leading, AlchemyTheme.agentIndent)
    }
}

// MARK: - Approval Context

private struct ApprovalContextView: View {
    let prompt: ChannelApprovalPrompt

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(AlchemyTheme.accent)
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 3) {
                Label(
                    prompt.title,
                    systemImage: prompt.kind == .exec
                        ? "shield.lefthalf.filled"
                        : "puzzlepiece.extension"
                )
                .font(.caption.weight(.medium))

                if let detail = prompt.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                if prompt.resolvedChoiceID != nil {
                    Label("Resolved", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
            .padding(.leading, 8)
            .padding(.vertical, 4)
        }
        .padding(.leading, AlchemyTheme.agentIndent)
    }
}

// MARK: - Approval Footer

private struct ApprovalFooterBar: View {
    let prompt: ChannelApprovalPrompt
    let onAction: @MainActor (ChannelButtonAction) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: prompt.kind == .exec
                ? "shield.lefthalf.filled"
                : "puzzlepiece.extension")
                .foregroundStyle(AlchemyTheme.accent)
                .font(.subheadline)

            Text(prompt.title)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            ForEach(prompt.approveChoices) { action in
                Button { onAction(action) } label: {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
            }

            if let deny = prompt.denyChoice {
                Button { onAction(deny) } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AlchemyTheme.accent.opacity(0.08))
    }
}

// MARK: - Option Prompt

private struct OptionPromptView: View {
    let prompt: ChannelOptionPrompt
    let onAction: @MainActor (ChannelButtonAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prompt.title)
                .font(.caption.weight(.medium))

            if let detail = prompt.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            WrappingHStack(spacing: 6) {
                ForEach(prompt.options) { option in
                    Button(option.title) { onAction(option) }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                }
            }
        }
        .padding(.leading, AlchemyTheme.agentIndent)
    }
}

// MARK: - Input Bar

private struct InputBar: View {
    let placeholder: String
    @Binding var text: String
    let isDisabled: Bool
    let onSend: @MainActor () -> Void

    private var canSend: Bool {
        !isDisabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(canSend ? AlchemyTheme.accent : .secondary)
            }
            .disabled(!canSend)
            .padding(.trailing, 8)
            .padding(.bottom, 4)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Wrapping Layout

private struct WrappingHStack: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(in: bounds.width, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private struct ArrangeResult {
        var size: CGSize
        var positions: [CGPoint]
    }

    private func arrange(in maxWidth: CGFloat, subviews: Subviews) -> ArrangeResult {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x + size.width > maxWidth, x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }

            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x - spacing)
        }

        return ArrangeResult(
            size: CGSize(width: totalWidth, height: y + rowHeight),
            positions: positions
        )
    }
}

#Preview {
    let model = ChatWorkspaceViewModel()
    return ChatWorkspaceView(model: model)
}
