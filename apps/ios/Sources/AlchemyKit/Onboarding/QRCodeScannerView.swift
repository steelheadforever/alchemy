#if os(iOS) && canImport(AVFoundation) && canImport(UIKit)
import AVFoundation
import AudioToolbox
import SwiftUI
import UIKit

struct QRCodeScannerView: UIViewControllerRepresentable {
    let onCodeScanned: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned)
    }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

protocol ScannerViewControllerDelegate: AnyObject {
    @MainActor func scannerViewController(_ controller: ScannerViewController, didScan code: String)
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: (any ScannerViewControllerDelegate)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let statusLabel = UILabel()
    private var didDeliverCode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureStatusLabel()
        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        statusLabel.frame = CGRect(x: 20, y: view.bounds.height - 96, width: view.bounds.width - 40, height: 52)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !session.isRunning else {
            return
        }

        Task { @MainActor in
            await requestAccessAndStart()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    @MainActor
    private func requestAccessAndStart() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            startSession()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            granted ? startSession() : showStatus("Camera access is required to scan the setup QR.")
        case .denied, .restricted:
            showStatus("Camera access is disabled. Enable it in Settings to scan the setup QR.")
        @unknown default:
            showStatus("Camera access is unavailable on this device.")
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            showStatus("No camera is available on this device.")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                showStatus("The camera input could not be configured.")
                return
            }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                showStatus("The QR scanner output could not be configured.")
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.insertSublayer(layer, at: 0)
            previewLayer = layer

            showStatus("Center the OpenClaw QR code in view.")
        } catch {
            showStatus("The camera could not be initialized.")
        }
    }

    private func configureStatusLabel() {
        statusLabel.textAlignment = .center
        statusLabel.textColor = .white
        statusLabel.numberOfLines = 0
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        statusLabel.layer.cornerRadius = 12
        statusLabel.layer.masksToBounds = true
        view.addSubview(statusLabel)
    }

    @MainActor
    private func startSession() {
        guard !session.isRunning else {
            return
        }
        session.startRunning()
    }

    private func showStatus(_ message: String) {
        statusLabel.text = message
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard
            !didDeliverCode,
            let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            object.type == .qr,
            let value = object.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return
        }

        didDeliverCode = true
        session.stopRunning()
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        Task { @MainActor in
            delegate?.scannerViewController(self, didScan: value)
        }
    }
}

final class Coordinator: NSObject, ScannerViewControllerDelegate {
    private let onCodeScanned: @MainActor (String) -> Void

    init(onCodeScanned: @escaping @MainActor (String) -> Void) {
        self.onCodeScanned = onCodeScanned
    }

    @MainActor
    func scannerViewController(_ controller: ScannerViewController, didScan code: String) {
        onCodeScanned(code)
    }
}
#endif
