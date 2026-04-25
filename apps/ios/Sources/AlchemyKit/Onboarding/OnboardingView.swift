import SwiftUI

public struct OnboardingView: View {
    @State private var model = OnboardingViewModel()
    let onConnect: ((SetupCodePayload) async -> Void)?
    let connectionStatus: String?
    let connectionDiagnostics: [ConnectionDiagnostic]
    @State private var isConnecting = false
    @State private var isPresentingScanner = false
    @State private var showDiagnostics = false

    public init(
        onConnect: ((SetupCodePayload) async -> Void)? = nil,
        connectionStatus: String? = nil,
        connectionDiagnostics: [ConnectionDiagnostic] = []
    ) {
        self.onConnect = onConnect
        self.connectionStatus = connectionStatus
        self.connectionDiagnostics = connectionDiagnostics
    }

    public var body: some View {
        ZStack {
            AlchemyTheme.surfacePrimary
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // Branding
                    Text("alchemy")
                        .font(.system(size: 28, weight: .light))
                        .tracking(2)
                        .foregroundStyle(AlchemyTheme.accent)
                        .padding(.top, 60)
                        .padding(.bottom, 8)

                    Text("Connect to your gateway")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 40)

                    // Actions
                    VStack(spacing: 12) {
                        #if os(iOS) && canImport(AVFoundation) && canImport(UIKit)
                        Button {
                            isPresentingScanner = true
                        } label: {
                            Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                                .font(.callout.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AlchemyTheme.accent)
                        .foregroundStyle(.black)
                        #endif

                        Button {
                            model.importSetupCode()
                        } label: {
                            Label("Paste Setup Code", systemImage: "doc.on.clipboard")
                                .font(.callout.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                    }
                    .padding(.horizontal, 24)

                    // Manual entry
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Or enter manually")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        TextField("Setup code", text: $model.setupCodeText, axis: .vertical)
                            .font(.caption.monospaced())
                            .lineLimit(3...6)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(AlchemyTheme.surfaceSecondary)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                            )
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 28)

                    // Parsed connection info + connect button
                    if let bootstrap = model.bootstrap {
                        VStack(alignment: .leading, spacing: 10) {
                            Divider()
                                .padding(.vertical, 4)

                            InfoRow(label: "Name", value: bootstrap.displayName)
                            InfoRow(label: "Gateway", value: bootstrap.gatewayURL.host(percentEncoded: false) ?? bootstrap.gatewayURL.absoluteString)

                            if let setupCode = model.setupCode, let onConnect {
                                Button {
                                    Task {
                                        isConnecting = true
                                        await onConnect(setupCode)
                                        isConnecting = false
                                    }
                                } label: {
                                    Group {
                                        if isConnecting {
                                            ProgressView()
                                                .tint(.black)
                                        } else {
                                            Text("Connect")
                                                .font(.callout.weight(.medium))
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(AlchemyTheme.accent)
                                .foregroundStyle(.black)
                                .disabled(isConnecting)
                                .padding(.top, 4)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                    }

                    // Error
                    if let errorMessage = connectionStatus ?? model.errorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.caption2)
                            Text(errorMessage)
                                .font(.caption)
                        }
                        .foregroundStyle(.red)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                    }

                    // Diagnostics
                    if !connectionDiagnostics.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showDiagnostics.toggle()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Diagnostics")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .rotationEffect(.degrees(showDiagnostics ? 90 : 0))
                                }
                            }
                            .buttonStyle(.plain)

                            if showDiagnostics {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(connectionDiagnostics) { diagnostic in
                                        Text(diagnostic.message)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                                .padding(.top, 8)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 20)
                    }

                    Spacer(minLength: 40)
                }
            }
        }
        #if os(iOS) && canImport(AVFoundation) && canImport(UIKit)
        .sheet(isPresented: $isPresentingScanner) {
            NavigationStack {
                QRCodeScannerView { scannedCode in
                    model.applySetupCode(scannedCode)
                    isPresentingScanner = false
                }
                .ignoresSafeArea()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            isPresentingScanner = false
                        }
                    }
                }
            }
        }
        #endif
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

#Preview {
    OnboardingView()
}
