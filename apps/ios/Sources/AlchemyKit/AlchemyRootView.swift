import SwiftUI

public struct AlchemyRootView: View {
    @State private var workspaceModel = DiscordWorkspaceViewModel()

    public init() {}

    public var body: some View {
        Group {
            if workspaceModel.isConnected {
                DiscordWorkspaceView(model: workspaceModel)
            } else {
                OnboardingView(
                    onConnect: { setupCode in
                        await workspaceModel.connect(using: setupCode)
                    },
                    connectionStatus: workspaceModel.errorMessage
                )
            }
        }
    }
}

#Preview {
    AlchemyRootView()
}
