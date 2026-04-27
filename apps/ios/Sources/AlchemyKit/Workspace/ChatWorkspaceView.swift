import SwiftUI

public struct ChatWorkspaceView: View {
    @State private var model: ChatWorkspaceViewModel

    // Folder dialog state
    @State private var showNewFolderDialog = false
    @State private var newFolderName = ""
    @State private var renamingFolderID: String?
    @State private var renamingFolderText = ""
    @State private var renamingChannelKey: String?
    @State private var renamingChannelText = ""

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
            // Ungrouped channels
            Section {
                ForEach(model.ungroupedChannels) { channel in
                    channelRow(channel)
                }
            } header: {
                Text("CHANNELS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.tertiary)
            }

            // User folders
            ForEach(model.userFolders) { folder in
                Section {
                    if !folder.isCollapsed {
                        ForEach(model.channels(in: folder)) { channel in
                            channelRow(channel)
                        }
                    }
                } header: {
                    folderHeader(folder)
                }
            }

            // Archive folder
            if let archive = model.archiveFolder {
                Section {
                    if !archive.isCollapsed {
                        ForEach(model.channels(in: archive)) { channel in
                            channelRow(channel)
                        }
                    }
                } header: {
                    folderHeader(archive)
                }
            }

            // Agents
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
                                Text("\u{03B1}")
                                    .font(.system(size: 13, weight: .regular, design: .serif))
                                    .foregroundStyle(AlchemyTheme.accent.opacity(0.5))
                                    .frame(width: 14)
                                Text(agent.title)
                                    .font(.system(size: 14))
                            }
                        }
                    }
                }
            } header: {
                Text("AGENTS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.tertiary)
            }

            // Connection status
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(connectionColor)
                            .frame(width: 5, height: 5)
                        Text(connectionLabel)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)

                        if model.connectionState == .connecting {
                            Spacer()
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }

                    if let errorMessage = model.errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                }

                Button(role: .destructive) {
                    Task { await model.unpair() }
                } label: {
                    Text("Disconnect")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 5) {
                    Text("\u{03B1}")
                        .font(.system(size: 19, weight: .regular, design: .serif))
                    Text("alchemy")
                        .font(.system(size: 16, weight: .medium))
                        .tracking(1.5)
                }
                .foregroundStyle(AlchemyTheme.accent)
            }

            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        Task { await model.createChannel(for: model.availableAgents.first) }
                    } label: {
                        Label("New Channel", systemImage: "plus")
                    }
                    .disabled(!model.isConnected || model.availableAgents.isEmpty)

                    Button {
                        newFolderName = ""
                        showNewFolderDialog = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }

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
                        .foregroundStyle(AlchemyTheme.accent)
                }
            }
        }
        .alert("New Folder", isPresented: $showNewFolderDialog) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    model.createFolder(name: name)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Folder",
               isPresented: Binding(
                   get: { renamingFolderID != nil },
                   set: { if !$0 { renamingFolderID = nil } }
               )
        ) {
            TextField("Folder name", text: $renamingFolderText)
            Button("Rename") {
                if let folderID = renamingFolderID {
                    let name = renamingFolderText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        model.renameFolder(folderID, to: name)
                    }
                }
                renamingFolderID = nil
            }
            Button("Cancel", role: .cancel) { renamingFolderID = nil }
        }
        .alert("Rename Channel",
               isPresented: Binding(
                   get: { renamingChannelKey != nil },
                   set: { if !$0 { renamingChannelKey = nil } }
               )
        ) {
            TextField("Channel name", text: $renamingChannelText)
            Button("Rename") {
                if let key = renamingChannelKey {
                    model.renameChannel(key, to: renamingChannelText)
                }
                renamingChannelKey = nil
            }
            Button("Reset to Default", role: .destructive) {
                if let key = renamingChannelKey {
                    model.clearChannelRename(key)
                }
                renamingChannelKey = nil
            }
            Button("Cancel", role: .cancel) { renamingChannelKey = nil }
        }
    }

    // MARK: - Channel Row

    private func channelRow(_ channel: WorkspaceChannel) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color(for: channel.status))
                .frame(width: 3, height: 14)

            Text(model.displayName(for: channel))
                .font(.system(size: 14))
                .lineLimit(1)
                .foregroundStyle(
                    model.channelFolderMap[channel.sessionKey] == model.archiveFolder?.id
                        ? .tertiary : .primary
                )
        }
        .tag(channel.id)
        .contextMenu {
            Button {
                renamingChannelText = model.displayName(for: channel)
                renamingChannelKey = channel.sessionKey
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            if !model.userFolders.isEmpty {
                Menu {
                    ForEach(model.userFolders) { folder in
                        Button(folder.name) {
                            model.moveChannel(channel.sessionKey, toFolder: folder.id)
                        }
                    }
                } label: {
                    Label("Move to Folder", systemImage: "folder")
                }
            }

            if model.channelFolderMap[channel.sessionKey] == model.archiveFolder?.id {
                Button {
                    model.unarchiveChannel(channel.sessionKey)
                } label: {
                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                }
            } else {
                Button {
                    model.archiveChannel(channel.sessionKey)
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
            }

            if let folderID = model.channelFolderMap[channel.sessionKey],
               folderID != model.archiveFolder?.id {
                Button {
                    model.removeChannelFromFolder(channel.sessionKey)
                } label: {
                    Label("Remove from Folder", systemImage: "folder.badge.minus")
                }
            }
        }
    }

    // MARK: - Folder Header

    private func folderHeader(_ folder: ChannelFolder) -> some View {
        Button {
            model.toggleFolderCollapsed(folder.id)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: folder.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.quaternary)
                    .frame(width: 10)

                Image(systemName: folder.isArchive ? "archivebox" : "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Text(folder.name.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.tertiary)

                let count = model.channels(in: folder).count
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !folder.isArchive {
                Button {
                    renamingFolderText = folder.name
                    renamingFolderID = folder.id
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    model.deleteFolder(folder.id)
                } label: {
                    Label("Delete Folder", systemImage: "trash")
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
            .navigationTitle(model.displayName(for: channel))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } else {
            ZStack {
                AlchemyTheme.surfacePrimary
                    .ignoresSafeArea()
                VStack(spacing: 10) {
                    Text("\u{03B1}")
                        .font(.system(size: 57, weight: .thin, design: .serif))
                        .foregroundStyle(AlchemyTheme.accent.opacity(0.15))
                    Text("Select or create a channel")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
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
    @State private var autoScrollEnabled = true

    private var pendingApproval: ChannelApprovalPrompt? {
        channel.timeline.lazy.compactMap { item in
            guard case .approval(let prompt) = item.kind,
                  prompt.resolvedChoiceID == nil else { return nil }
            return prompt
        }.first
    }

    private enum SenderGroup {
        case user, assistant
    }

    private func senderGroup(of item: ChannelTimelineItem) -> SenderGroup {
        switch item.kind {
        case .message(let msg):
            return msg.role == .user ? .user : .assistant
        case .tool, .approval, .options:
            return .assistant
        }
    }

    /// Changes whenever the last timeline item's content grows (streaming text) or a new item appears.
    private var scrollTrigger: String {
        let count = channel.timeline.count
        guard let last = channel.timeline.last else { return "0" }
        switch last.kind {
        case .message(let msg):
            return "\(count):\(msg.text.count)"
        default:
            return "\(count)"
        }
    }

    private func topPadding(for item: ChannelTimelineItem, at offset: Int) -> CGFloat {
        guard offset > 0 else { return 0 }
        let previous = channel.timeline[offset - 1]
        if senderGroup(of: previous) == senderGroup(of: item) {
            return AlchemyTheme.sameSenderSpacing
        }
        return AlchemyTheme.turnSpacing
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(channel.timeline.enumerated()), id: \.element.id) { offset, item in
                            TimelineItemView(item: item, onAction: onAction)
                                .id(item.id)
                                .padding(.top, topPadding(for: item, at: offset))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 5).onChanged { _ in
                        autoScrollEnabled = false
                    }
                )
                .onChange(of: scrollTrigger) { _, _ in
                    guard autoScrollEnabled else { return }
                    scrollTask?.cancel()
                    scrollTask = Task {
                        try? await Task.sleep(for: .milliseconds(50))
                        guard !Task.isCancelled else { return }
                        if let last = channel.timeline.last {
                            withAnimation(.easeOut(duration: 0.15)) {
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
                onSend: {
                    autoScrollEnabled = true
                    onSend()
                }
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
                    .font(.system(size: 15))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        AlchemyTheme.surfaceTertiary,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
            }

        case .assistant:
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\u{03B1}")
                    .font(.system(size: 15, weight: .regular, design: .serif))
                    .foregroundStyle(AlchemyTheme.accent.opacity(0.7))

                TypewriterText(text: message.text, isStreaming: message.isStreaming)
                    .font(.system(size: 15))

                Spacer(minLength: 0)
            }

        case .system:
            Text(message.text)
                .font(.system(size: 12))
                .foregroundStyle(.quaternary)
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
            RoundedRectangle(cornerRadius: 1)
                .fill(tool.isStreaming ? AlchemyTheme.accent.opacity(0.6) : .green.opacity(0.5))
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if tool.isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green.opacity(0.7))
                    }
                }

                if let detail = tool.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            .padding(.leading, 8)
            .padding(.vertical, 3)
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
            RoundedRectangle(cornerRadius: 1)
                .fill(AlchemyTheme.accent.opacity(0.6))
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 2) {
                Label(
                    prompt.title,
                    systemImage: prompt.kind == .exec
                        ? "shield.lefthalf.filled"
                        : "puzzlepiece.extension"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

                if let detail = prompt.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                }

                if prompt.resolvedChoiceID != nil {
                    Label("Resolved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green.opacity(0.7))
                }
            }
            .padding(.leading, 8)
            .padding(.vertical, 3)
        }
        .padding(.leading, AlchemyTheme.agentIndent)
    }
}

// MARK: - Approval Footer

private struct ApprovalFooterBar: View {
    let prompt: ChannelApprovalPrompt
    let onAction: @MainActor (ChannelButtonAction) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: prompt.kind == .exec
                ? "shield.lefthalf.filled"
                : "puzzlepiece.extension")
                .foregroundStyle(AlchemyTheme.accent.opacity(0.8))
                .font(.system(size: 14))

            Text(prompt.title)
                .font(.system(size: 14))
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Spacer()

            ForEach(prompt.approveChoices) { action in
                Button { onAction(action) } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green.opacity(0.8))
                .controlSize(.small)
            }

            if let deny = prompt.denyChoice {
                Button { onAction(deny) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(.red.opacity(0.8))
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(AlchemyTheme.surfaceSecondary)
    }
}

// MARK: - Option Prompt

private struct OptionPromptView: View {
    let prompt: ChannelOptionPrompt
    let onAction: @MainActor (ChannelButtonAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let detail = prompt.detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }

            WrappingHStack(spacing: 5) {
                ForEach(prompt.options) { option in
                    Button(option.title) { onAction(option) }
                        .font(.system(size: 13))
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .tint(AlchemyTheme.accent)
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
                .font(.system(size: 15))
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(canSend ? AlchemyTheme.accent : Color.secondary.opacity(0.3))
            }
            .disabled(!canSend)
            .padding(.trailing, 8)
            .padding(.bottom, 5)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AlchemyTheme.surfaceSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
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
