import SwiftUI

public struct AlchemyRootView: View {
    @State private var workspaceModel = ChatWorkspaceViewModel()
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        Group {
            switch workspaceModel.connectionState {
            case .unknown, .connecting:
                connectingView
            case .connected:
                ChatWorkspaceView(model: workspaceModel)
            case .disconnected:
                OnboardingView(
                    onConnect: { setupCode in
                        await workspaceModel.connect(using: setupCode)
                    },
                    connectionStatus: workspaceModel.errorMessage,
                    connectionDiagnostics: workspaceModel.connectionDiagnostics
                )
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await workspaceModel.reconnectIfPossible()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                Task { await workspaceModel.handleForeground() }
            case .background:
                Task { await workspaceModel.handleBackground() }
            default:
                break
            }
        }
    }

    private var connectingView: some View {
        ZStack {
            AlchemyTheme.surfacePrimary
                .ignoresSafeArea()

            VStack(spacing: 6) {
                Text("\u{03B1}")
                    .font(.system(size: 49, weight: .thin, design: .serif))
                    .foregroundStyle(AlchemyTheme.accent)
                Text("alchemy")
                    .font(.system(size: 16, weight: .medium))
                    .tracking(4)
                    .foregroundStyle(.secondary)
            }

            VStack {
                Spacer()
                ProgressView()
                    .tint(AlchemyTheme.accent)
                    .controlSize(.regular)
                    .padding(.bottom, 80)
            }
        }
    }
}

#Preview {
    AlchemyRootView()
}
