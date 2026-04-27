import SwiftUI

struct SplashScreenView: View {
    var body: some View {
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
        }
    }
}

#Preview {
    SplashScreenView()
}
