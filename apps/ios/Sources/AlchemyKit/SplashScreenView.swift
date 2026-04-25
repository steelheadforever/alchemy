import SwiftUI

struct SplashScreenView: View {
    var body: some View {
        ZStack {
            AlchemyTheme.surfacePrimary
                .ignoresSafeArea()

            Text("alchemy")
                .font(.system(size: 32, weight: .light, design: .default))
                .tracking(2)
                .foregroundStyle(AlchemyTheme.accent)
        }
    }
}

#Preview {
    SplashScreenView()
}
