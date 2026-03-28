import Foundation
import UIKit
import AVFoundation

class NDIManager: NSObject {
    static let shared = NDIManager()
    
    // Discovery (Finder)
    var findInstance: NDIlib_find_instance_t?
    private var cachedSources = [String]()
    private let discoveryQueue = DispatchQueue(label: "ndi.discovery.queue", qos: .background)
    
    // NDI Send state (Camera)
    private var sendInstance: NDIlib_send_instance_t?
    private var persistentSendName: UnsafeMutablePointer<CChar>?
    private var captureSession: AVCaptureSession?
    private var sendQueue = DispatchQueue(label: "ndi.send.queue", qos: .userInitiated)
    
    override init() {
        super.init()
        if !NDIlib_initialize() { return }
        
        var findCreate = NDIlib_find_create_t()
        findCreate.show_local_sources = true
        findInstance = NDIlib_find_create_v2(&findCreate)
        
        // Démarrage de la découverte en tâche de fond (Loop infinie légère)
        startBackgroundDiscovery()
        print("✅ NDI Manager initialized (Background Discovery Started)")
    }
    
    private func startBackgroundDiscovery() {
        discoveryQueue.async { [weak self] in
            while true {
                guard let find = self?.findInstance else { break }
                
                // On attend les sources sans bloquer l'UI
                NDIlib_find_wait_for_sources(find, 1000)
                
                var noSources: UInt32 = 0
                let sources = NDIlib_find_get_current_sources(find, &noSources)
                
                var names = [String]()
                if noSources > 0, let sources = sources {
                    for i in 0..<Int(noSources) {
                        let name = String(cString: sources[i].p_ndi_name)
                        if !name.isEmpty { names.append(name) }
                    }
                }
                
                // On met à jour le cache (thread-safe simple car lecture seule pour le reste)
                self?.cachedSources = names
                
                // On dort un peu pour ne pas saturer le CPU
                sleep(10)
            }
        }
    }
    
    func getSources() -> [String] {
        // Retourne IMMEDIATEMENT le cache (Zéro blocage d'UI)
        return cachedSources
    }
    
    // ─────────────────────────────
    // SEND (Camera → NDI)
    // ─────────────────────────────
    func startSend(sourceName: String) {
        if sendInstance != nil { stopSend() }
        
        // 🛠️ CRITICAL FIX 1: NDI sender name pointer MUST persist indefinitely. 
        // withCString destroys the string too early, causing an invisible ghost source on the network.
        if let oldName = persistentSendName { free(oldName) }
        persistentSendName = strdup(sourceName)
        
        var sendCreate = NDIlib_send_create_t()
        if let namePtr = persistentSendName {
            sendCreate.p_ndi_name = UnsafePointer(namePtr)
        }
        sendInstance = NDIlib_send_create(&sendCreate)
        
        guard sendInstance != nil else { return }
        
        // 🛠️ CRITICAL FIX 2: Never recreate the camera if it's already running!
        // Doing so rips the camera away from the PreviewLayer and freezes the UI.
        if captureSession == nil {
            setupCamera()
        }
    }
    
    func stopSend() {
        // 🚨 Do NOT stop the captureSession here! 
        // We want the screen preview to keep running smoothly even if we stop pushing to NDI.
        if let send = sendInstance {
            NDIlib_send_destroy(send)
            sendInstance = nil
        }
    }
    
    func getCaptureSession() -> AVCaptureSession? {
        if captureSession == nil { setupCamera() }
        return captureSession
    }
    
    private func setupCamera() {
        let session = AVCaptureSession()
        session.sessionPreset = .hd1280x720
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: sendQueue)
        output.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(output) { session.addOutput(output) }
        captureSession = session
        sendQueue.async { session.startRunning() }
    }
}

extension NDIManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // ✅ On s'assure que le flux NDI tourne aussi si l'iPhone tourne
        if connection.isVideoOrientationSupported {
            let current = currentOrientation()
            if connection.videoOrientation != current {
                connection.videoOrientation = current
            }
        }
        
        guard let send = sendInstance, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let data = CVPixelBufferGetBaseAddress(pixelBuffer)
        
        var videoFrame = NDIlib_video_frame_v2_t()
        videoFrame.xres = Int32(width); videoFrame.yres = Int32(height)
        videoFrame.FourCC = NDIlib_FourCC_type_BGRA
        videoFrame.frame_rate_N = 30000; videoFrame.frame_rate_D = 1001
        videoFrame.frame_format_type = NDIlib_frame_format_type_progressive
        videoFrame.line_stride_in_bytes = Int32(stride)
        videoFrame.p_data = data?.bindMemory(to: UInt8.self, capacity: stride * height)
        NDIlib_send_send_video_v2(send, &videoFrame)
    }
    
    private func currentOrientation() -> AVCaptureVideoOrientation {
        let orientation: UIInterfaceOrientation
        if #available(iOS 13.0, *) {
            // Sur iOS 13+, on récupère l'orientation de la scène active (plus précis que UIDevice)
            orientation = UIApplication.shared.windows.first { $0.isKeyWindow }?.windowScene?.interfaceOrientation ?? .portrait
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
