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
    private var _view: UIView
    private var previewLayer: AVCaptureVideoPreviewLayer?

    init(frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) {
        _view = UIView(frame: frame)
        _view.backgroundColor = .black
        super.init()
        setupPreview()
    }

    func view() -> UIView { return _view }

    private func setupPreview() {
        guard let session = NDIManager.shared.getCaptureSession() else { return }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = _view.bounds
        _view.layer.addSublayer(layer)
        self.previewLayer = layer
    }
}
