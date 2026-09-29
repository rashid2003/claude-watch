import AVFoundation
import SwiftUI
import UIKit

/// Camera preview that reports the first QR code it sees (and again only after `reset`).
struct QRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }

    func updateUIViewController(_ c: ScannerController, context: Context) {
        c.onCode = onCode
    }

    static var isAvailable: Bool { AVCaptureDevice.default(for: .video) != nil }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var lastCode: String?
    private var lastAt = Date.distantPast
    private let sessionQueue = DispatchQueue(label: "qr-scanner")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard QRScanner.isAvailable else {
            showMessage("no camera here · enter the details below")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async { ok ? self?.configure() : self?.showDenied() }
            }
        default: showDenied()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let s = session
        sessionQueue.async { if s.isRunning { s.stopRunning() } }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard preview != nil else { return }
        let s = session
        sessionQueue.async { if !s.isRunning { s.startRunning() } }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            showMessage("no camera here · enter the details below")
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
        let s = session
        sessionQueue.async { s.startRunning() }
    }

    private func showDenied() {
        showMessage("camera access is off · allow it in Settings, or enter the details below")
    }

    private func showMessage(_ text: String) {
        let label = UILabel()
        label.text = text
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        // The same code keeps arriving every frame; report it at most every 3 s.
        if code == lastCode, Date().timeIntervalSince(lastAt) < 3 { return }
        lastCode = code
        lastAt = Date()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onCode?(code)
    }
}
