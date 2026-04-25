import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        CrashLogger.install()
        
        // 1️⃣ INITIALISATION RÉSEAU/FLUTTER (Gemini Fix)
        let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
        
        // 2️⃣ RÉCUPÉRATION DU CONTROLLER (Sécurisée après super.application)
        guard let controller = window?.rootViewController as? FlutterViewController else {
            return result
        }
        
        // 🔄 Inscription des plugins Flutter de base
        GeneratedPluginRegistrant.register(with: self)
        
        // 📡 Setup Canal NDI
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
                let args = call.arguments as? [String: Any]
                let res = args?["resolution"] as? String ?? "720p"
                // ✅ Correction du cast Int32 (Flutter envoie du Int 64-bit)
                let fpsRaw = args?["fps"] as? Int ?? 30
                let fps = Int32(fpsRaw)
                NDIManager.shared.setupCamera(resolution: res, fps: fps)
                result(true)
            } else {
                result(FlutterMethodNotImplemented)
            }
        })
        
        // 🎨 Inscription des vues natives (Pattern Stable)
        let registrar = self.registrar(forPlugin: "NDIPlugin")
        let factory = NDIViewFactory(messenger: controller.binaryMessenger)
        registrar?.register(factory, withId: "ndi-view")
        
        let cameraFactory = NdiCameraPreviewFactory()
        registrar?.register(cameraFactory, withId: "ndi-camera-preview")
        
        // 📑 Affichage du crash log si besoin
        CrashLogger.showLastCrashIfNeeded(in: controller)
        
        return result
    }
}
