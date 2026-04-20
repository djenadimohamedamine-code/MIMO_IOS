import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        CrashLogger.install()
        
        // 1´©ÅÔâú INITIALISATION R├ëSEAU/FLUTTER (Gemini Fix)
        let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
        
        // 2´©ÅÔâú R├ëCUP├ëRATION DU CONTROLLER (S├®curis├®e apr├¿s super.application)
        guard let controller = window?.rootViewController as? FlutterViewController else {
            return result
        }
        
        // ­ƒöä Inscription des plugins Flutter de base
        GeneratedPluginRegistrant.register(with: self)
        
        // ­ƒôí Setup Canal NDI
        let ndiChannel = FlutterMethodChannel(name: "com.antigravity/ndi",
                                              binaryMessenger: controller.binaryMessenger)
        
        ndiChannel.setMethodCallHandler({ (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
            if call.method == "getSources" {
                result(NDIManager.shared.getSources())
            } else if call.method == "startSend" {
                let name = (call.arguments as? [String: Any])?["name"] as? String ?? "MIMO_NDI Camera"
                NDIManager.shared.startSend(sourceName: name)
                result(true)
            } else if call.method == "stopSend" {
                NDIManager.shared.stopSend()
                result(true)
            } else if call.method == "startRelay" {
                NDIManager.shared.startRelaySender()
                result(true)
            } else if call.method == "switchRelay" {
                if let source = call.arguments as? String {
                    NDIManager.shared.switchRelay(to: source)
                    result(true)
                } else { result(false) }
            } else if call.method == "stopRelay" {
                NDIManager.shared.stopRelay()
                result(true)
            } else if call.method == "setupCamera" {
                NDIManager.shared.setupCamera()
                result(true)
            } else {
                result(FlutterMethodNotImplemented)
            }
        })
        
        // ­ƒº® Inscription des vues natives (Pattern Stable)
        let registrar = self.registrar(forPlugin: "NDIPlugin")
        let factory = NDIViewFactory(messenger: controller.binaryMessenger)
        registrar?.register(factory, withId: "ndi-view")
        
        let cameraFactory = NdiCameraPreviewFactory()
        registrar?.register(cameraFactory, withId: "ndi-camera-preview")
        
        // ­ƒôï Affichage du crash log si besoin
        CrashLogger.showLastCrashIfNeeded(in: controller)
        
        return result
    }
}
