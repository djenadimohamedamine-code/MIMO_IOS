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
        let nameBytes = sourceName.utf8CString
        var sendCreate = NDIlib_send_create_t()
        nameBytes.withUnsafeBufferPointer { ptr in
            sendCreate.p_ndi_name = ptr.baseAddress
            sendInstance = NDIlib_send_create(&sendCreate)
        }
        guard sendInstance != nil else { return }
        setupCamera()
    }
    
    func stopSend() {
        captureSession?.stopRunning()
        captureSession = nil
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
}
