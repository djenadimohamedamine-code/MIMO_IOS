import Flutter
import UIKit
import CoreGraphics

/// Factory for native iOS OMT receiver video display PlatformView.
/// Registered as 'com.antigravity/omt_receiver_view'.
/// Completely separate from NDI views.
class OMTReceiverViewFactory: NSObject, FlutterPlatformViewFactory {
    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
    
    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        return OMTReceiverView(frame: frame, viewIdentifier: viewId, arguments: args)
    }
}

/// FlutterPlatformView wrapper for OMTReceiverDisplayUIView.
class OMTReceiverView: NSObject, FlutterPlatformView {
    private var displayView: OMTReceiverDisplayUIView

    init(frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) {
        self.displayView = OMTReceiverDisplayUIView(frame: frame)
        super.init()
    }

    func view() -> UIView {
        return displayView
    }
}

/// Native UIView rendering decoded OMT frames (VMX1 / UYVY) via CoreAnimation CALayer.
/// Provides zero-copy, hardware-accelerated presentation of 30-60 FPS broadcast streams.
class OMTReceiverDisplayUIView: UIView {
    private let displayLayer = CALayer()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }
    
    private func setupView() {
        self.backgroundColor = .black
        self.clipsToBounds = true
        
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.contentsGravity = .resizeAspect
        displayLayer.frame = self.bounds
        self.layer.addSublayer(displayLayer)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onFrameDecoded(_:)),
            name: NSNotification.Name("OMTFrameDecoded"),
            object: nil
        )
    }
    
    @objc private func onFrameDecoded(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let cgImage = userInfo["image"] as? CGImage else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.displayLayer.contents = cgImage
            CATransaction.commit()
        }
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = self.bounds
        CATransaction.commit()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        displayLayer.removeFromSuperlayer()
    }
}
