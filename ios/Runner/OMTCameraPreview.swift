import Flutter
import UIKit
import AVFoundation

/// Factory for native iOS OMT camera preview PlatformView.
/// Registered as 'com.antigravity/omt_camera_preview'.
/// Completely separate from NDI preview views.
class OMTCameraPreviewFactory: NSObject, FlutterPlatformViewFactory {
    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
    
    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        return OMTCameraPreview(frame: frame, viewIdentifier: viewId, arguments: args)
    }
}

/// FlutterPlatformView wrapper for OMTCameraPreviewView.
class OMTCameraPreview: NSObject, FlutterPlatformView {
    private var previewView: OMTCameraPreviewView

    init(frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) {
        self.previewView = OMTCameraPreviewView(frame: frame)
        super.init()
    }

    func view() -> UIView {
        return previewView
    }
}

/// Custom UIView hosting the AVCaptureVideoPreviewLayer connected to OMTVideoCapture's session.
class OMTCameraPreviewView: UIView {
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var checkTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.backgroundColor = .black
        self.clipsToBounds = true
        setupPreview()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.backgroundColor = .black
        self.clipsToBounds = true
        setupPreview()
    }

    private func setupPreview() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onCameraReady),
            name: NSNotification.Name("OMTCameraSessionReady"),
            object: nil
        )
        
        attachSession()
        
        // If session is not ready yet, poll briefly
        checkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.previewLayer == nil {
                self.attachSession()
            } else {
                timer.invalidate()
            }
        }
    }

    private func attachSession() {
        guard #available(iOS 13.0, *) else { return }
        guard let session = OMTManager.shared.activeCaptureSession else { return }
        
        previewLayer?.removeFromSuperlayer()
        
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = self.bounds
        
        // Match device orientation
        if let connection = layer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        
        self.layer.addSublayer(layer)
        self.previewLayer = layer
        checkTimer?.invalidate()
        checkTimer = nil
        NSLog("[OMTCameraPreviewView] Attached AVCaptureVideoPreviewLayer to OMT session")
    }

    @objc private func onCameraReady() {
        DispatchQueue.main.async { [weak self] in
            self?.attachSession()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer?.frame = self.bounds
        CATransaction.commit()
    }

    deinit {
        checkTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        previewLayer?.removeFromSuperlayer()
    }
}
