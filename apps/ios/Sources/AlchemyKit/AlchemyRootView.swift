import SwiftUI

public struct AlchemyRootView: View {
    @State private var workspaceModel = ChatWorkspaceViewModel()
    @State private var showSplash = true
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        ZStack {
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

            if showSplash {
                SplashScreenView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.5)) {
                showSplash = false
            }
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

            VStack(spacing: 16) {
                Text("alchemy")
                    .font(.system(size: 32, weight: .light, design: .default))
                    .tracking(2)
                    .foregroundStyle(AlchemyTheme.accent)

                ProgressView()
                    .tint(AlchemyTheme.accent)
                    .controlSize(.regular)
            }
        }
    }
}

#Preview {
    AlchemyRootView()
}
