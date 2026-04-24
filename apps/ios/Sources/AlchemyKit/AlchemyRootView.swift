import SwiftUI

public struct AlchemyRootView: View {
    @State private var workspaceModel = ChatWorkspaceViewModel()
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        Group {
            switch workspaceModel.connectionState {
            case .unknown, .connecting:
                ProgressView("Connecting...")
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
}

#Preview {
    AlchemyRootView()
}
