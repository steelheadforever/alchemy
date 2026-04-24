import SwiftUI

public struct OnboardingView: View {
    @State private var model = OnboardingViewModel()
    let onConnect: ((SetupCodePayload) async -> Void)?
    let connectionStatus: String?
    let connectionDiagnostics: [ConnectionDiagnostic]
    @State private var isConnecting = false
    @State private var isPresentingScanner = false

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
        NavigationStack {
            Form {
                Section("Setup Code") {
                    TextField("Paste or scan setup code", text: $model.setupCodeText, axis: .vertical)

                    HStack {
                        Button("Import") {
                            model.importSetupCode()
                        }

                        #if os(iOS) && canImport(AVFoundation) && canImport(UIKit)
                        Button("Scan QR Code") {
                            isPresentingScanner = true
                        }
                        #endif
                    }
                }

                if let bootstrap = model.bootstrap {
                    Section("Connection") {
                        LabeledContent("Name", value: bootstrap.displayName)
                        LabeledContent("Gateway", value: bootstrap.gatewayURL.absoluteString)
                        LabeledContent("Bootstrap", value: bootstrap.bootstrapToken)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let setupCode = model.setupCode, let onConnect {
                            Button {
                                Task {
                                    isConnecting = true
                                    await onConnect(setupCode)
                                    isConnecting = false
                                }
                            } label: {
                                if isConnecting {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Text("Connect to Gateway")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .disabled(isConnecting)
                        }
                    }
                }

                if let errorMessage = connectionStatus ?? model.errorMessage {
                    Section("Status") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                if !connectionDiagnostics.isEmpty {
                    Section("Connection Diagnostics") {
                        ForEach(connectionDiagnostics) { diagnostic in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(diagnostic.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(diagnostic.message)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Connection")
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

#Preview {
    OnboardingView()
}
