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

    // MARK: - Sidebar (unchanged — polish is a separate pass)

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
        case .connecting: return "Reconnecting\u{2026}"
        case .disconnected: return "Disconnected"
        case .unknown: return "Unknown"
        }
    }

    private func color(for status: WorkspaceChannel.Status) -> Color {
        switch status {
        case .idle: return .secondary
        case .connecting: return .orange
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
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(channel.timeline) { item in
                            TimelineItemView(item: item, onAction: onAction)
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: channel.timeline.count) { _, _ in
                    if let last = channel.timeline.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            if let approval = pendingApproval {
                ApprovalFooterBar(prompt: approval, onAction: onAction)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            InputCapsule(
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
            MessageBubbleView(message: message)
        case .tool(let tool):
            ToolActivityView(tool: tool)
        case .approval(let approval):
            ApprovalContextView(prompt: approval)
        case .options(let prompt):
            OptionPromptView(prompt: prompt, onAction: onAction)
        }
    }
}

// MARK: - Messages (asymmetric layout)

private struct MessageBubbleView: View {
    let message: ChannelMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Color.blue.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
            }

        case .assistant:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.secondary.opacity(0.08), in: Circle())

                TypewriterText(text: message.text, isStreaming: message.isStreaming)
                    .font(.callout)

                Spacer(minLength: 20)
            }

        case .system:
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Typewriter + Blinking Cursor

private struct TypewriterText: View {
    let text: String
    let isStreaming: Bool

    @State private var revealedCount = 0
    @State private var cursorVisible = true

    var body: some View {
        let displayText: String = if !isStreaming {
            text
        } else if text.isEmpty {
            ""
        } else {
            String(text.prefix(revealedCount))
        }

        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(displayText)
                .textSelection(.enabled)

            if isStreaming {
                Text("\u{258E}")
                    .foregroundStyle(.secondary)
                    .opacity(cursorVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.4), value: cursorVisible)
                    .task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(530))
                            cursorVisible.toggle()
                        }
                    }
            }
        }
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
                cursorVisible = true
            }
        }
    }
}

// MARK: - Tool Activity (compact chip)

private struct ToolActivityView: View {
    let tool: ChannelToolActivity

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tool.isStreaming ? Color.orange : Color.green)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

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
            .padding(.vertical, 6)
            .padding(.trailing, 10)
        }
        .padding(.leading, 34)
    }
}

// MARK: - Approval Context (inline, no buttons)

private struct ApprovalContextView: View {
    let prompt: ChannelApprovalPrompt

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.orange)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                Label(
                    prompt.title,
                    systemImage: prompt.kind == .exec
                        ? "shield.lefthalf.filled"
                        : "puzzlepiece.extension"
                )
                .font(.subheadline.weight(.medium))

                if let detail = prompt.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                if prompt.resolvedChoiceID != nil {
                    Label("Resolved", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
            .padding(.leading, 10)
            .padding(.vertical, 6)
        }
        .padding(.leading, 34)
    }
}

// MARK: - Approval Footer (pinned above input, thumb-friendly)

private struct ApprovalFooterBar: View {
    let prompt: ChannelApprovalPrompt
    let onAction: @MainActor (ChannelButtonAction) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: prompt.kind == .exec
                ? "shield.lefthalf.filled"
                : "puzzlepiece.extension")
                .foregroundStyle(.orange)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.08))
    }
}

// MARK: - Option Prompt

private struct OptionPromptView: View {
    let prompt: ChannelOptionPrompt
    let onAction: @MainActor (ChannelButtonAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prompt.title)
                .font(.subheadline.weight(.medium))

            if let detail = prompt.detail {
                Text(detail)
                    .font(.caption)
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
        .padding(.leading, 34)
    }
}

// MARK: - Input Capsule

private struct InputCapsule: View {
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
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(canSend ? .blue : .secondary)
            }
            .disabled(!canSend)
            .padding(.trailing, 8)
            .padding(.bottom, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
