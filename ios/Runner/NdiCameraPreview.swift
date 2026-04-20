import Flutter
import UIKit
import AVFoundation

class NdiCameraPreviewFactory: NSObject, FlutterPlatformViewFactory {
    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { return FlutterStandardMessageCodec.sharedInstance() }
    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        return NdiCameraPreview(frame: frame, viewIdentifier: viewId, arguments: args)
    }
}

class NdiCameraPreview: NSObject, FlutterPlatformView {
    private var previewView: CameraPreviewView

    init(frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) {
        self.previewView = CameraPreviewView(frame: frame)
        super.init()
    }

    func view() -> UIView { return previewView }
}

// ✅ Classe dédiée pour gérer le redimensionnement automatique (Rotation iPhone)
class CameraPreviewView: UIView {
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.backgroundColor = .black
        setupPreview()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupPreview() {
        self.backgroundColor = .black
        NotificationCenter.default.addObserver(self, selector: #selector(onCameraReady), name: NSNotification.Name("CameraReady"), object: nil)
        attachSession()
    }

    private func attachSession() {
        guard let session = NDIManager.shared.getCaptureSession() else { return }
        
        // Nettoyage ancien
        previewLayer?.removeFromSuperlayer()
        
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = self.bounds
        self.layer.addSublayer(layer)
        self.previewLayer = layer
    }

    @objc private func onCameraReady() {
        DispatchQueue.main.async {
            print("👁️ PreviewView: Camera is ready, attaching session...")
            self.attachSession()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // ✅ Ajuste le calque vidéo dès que l'iPhone tourne ou change de taille
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer?.frame = self.bounds
        
        // ✅ Correction de l'orientation pour éviter que l'image reste en Portrait quand on tourne
        if let connection = previewLayer?.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = self.currentVideoOrientation()
        }
        CATransaction.commit()
    }

    private func currentVideoOrientation() -> AVCaptureVideoOrientation {
        // Détecte l'orientation actuelle de l'interface pour synchroniser le flux vidéo
        let orientation: UIInterfaceOrientation
        if #available(iOS 13.0, *) {
            orientation = self.window?.windowScene?.interfaceOrientation ?? .portrait
        } else {
            orientation = UIApplication.shared.statusBarOrientation
        }
        
        switch orientation {
        case .portrait: return .portrait
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }
}
