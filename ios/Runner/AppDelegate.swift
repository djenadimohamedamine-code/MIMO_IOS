import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 🛡️ Install crash logger FIRST (before anything else)
        CrashLogger.install()
        
        let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
        let ndiChannel = FlutterMethodChannel(name: "com.antigravity/ndi",
                                              binaryMessenger: controller.binaryMessenger)
        
        ndiChannel.setMethodCallHandler({
            (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
            if call.method == "getSources" {
                let sources = NDIManager.shared.getSources()
                result(sources)
            } else if call.method == "startSend" {
                if let args = call.arguments as? [String: Any],
                   let name = args["name"] as? String {
                    NDIManager.shared.startSend(sourceName: name)
                    result(true)
                } else {
                    NDIManager.shared.startSend(sourceName: "MIMO_NDI Camera")
                    result(true)
                }
            } else if call.method == "stopSend" {
                NDIManager.shared.stopSend()
                result(true)
            } else {
                result(FlutterMethodNotImplemented)
            }
        })
        
        // Register NDI Native View (Récepteur)
        let registrar = self.registrar(forPlugin: "NDIPlugin")
        let factory = NDIViewFactory(messenger: controller.binaryMessenger)
        registrar?.register(factory, withId: "ndi-view")
        
        // Register Camera Preview (Émetteur)
        let cameraFactory = NdiCameraPreviewFactory()
        registrar?.register(cameraFactory, withId: "ndi-camera-preview")
        
        let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
        
        // 📋 Show last crash report if app crashed previously
        CrashLogger.showLastCrashIfNeeded(in: controller)
        
        return result
    }
}
