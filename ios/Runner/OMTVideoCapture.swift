import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import UIKit

/// Captures camera frames and converts them to UYVY (4:2:2) format
/// for OMT video transmission. Completely independent of NDI camera capture.
class OMTVideoCapture: NSObject {
    
    // MARK: - Configuration
    
    struct Config {
        let width: Int
        let height: Int
        let frameRateN: Int32
        let frameRateD: Int32
        var useFrontCamera: Bool
        
        var fps: Double {
            return Double(frameRateN) / Double(frameRateD)
        }
    }
    
    // MARK: - Callbacks
    
    /// Called on each captured frame with UYVY pixel data and actual dimensions (legacy/fallback)
    var onFrame: ((Data, Int32, Int32) -> Void)?
    /// High-performance zero-copy CVPixelBuffer callback directly from hardware camera buffer
    var onPixelBuffer: ((CVPixelBuffer, Int32, Int32) -> Void)?
    var onError: ((String) -> Void)?
    
    // MARK: - State
    
    /// Exposed for AVCaptureVideoPreviewLayer
    public private(set) var session: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private(set) var config: Config?
    private let captureQueue = DispatchQueue(label: "com.antigravity.omt.capture",
                                             qos: .userInteractive)
    private var frameCount: Int64 = 0
    private var lastStatsTime: Date = Date()
    private var _measuredFPS: Double = 0
    private(set) var actualWidth: Int32 = 0
    private(set) var actualHeight: Int32 = 0
    
    var measuredFPS: Double { return _measuredFPS }
    var isRunning: Bool { return session?.isRunning ?? false }
    
    // MARK: - Public API
    
    /// Start camera capture with the given configuration
    func startCapture(config: Config) {
        self.config = config
        
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch authStatus {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.captureQueue.async {
                        self?.setupCaptureSession(config: config)
                    }
                } else {
                    self?.onError?("Camera access denied by user")
                }
            }
        case .denied, .restricted:
            onError?("Camera access restricted or denied in iOS Settings")
        case .authorized:
            captureQueue.async { [weak self] in
                self?.setupCaptureSession(config: config)
            }
        @unknown default:
            captureQueue.async { [weak self] in
                self?.setupCaptureSession(config: config)
            }
        }
    }
    
    /// Stop camera capture and release resources
    func stopCapture() {
        captureQueue.async { [weak self] in
            self?.session?.stopRunning()
            self?.session = nil
            self?.videoOutput = nil
            self?._measuredFPS = 0
            self?.actualWidth = 0
            self?.actualHeight = 0
        }
    }
    
    /// Switch between front and back camera dynamically
    func switchCamera(useFront: Bool) {
        guard var currentConfig = config else { return }
        currentConfig.useFrontCamera = useFront
        self.config = currentConfig
        
        captureQueue.async { [weak self] in
            guard let self = self, let session = self.session else { return }
            session.beginConfiguration()
            
            // Remove existing inputs
            for input in session.inputs {
                session.removeInput(input)
            }
            
            // Add new camera device
            let position: AVCaptureDevice.Position = useFront ? .front : .back
            if let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
               let input = try? AVCaptureDeviceInput(device: camera) {
                if session.canAddInput(input) {
                    session.addInput(input)
                }
            }
            
            // Update mirroring
            if let output = self.videoOutput, let connection = output.connection(with: .video) {
                connection.isVideoMirrored = useFront
                if currentConfig.width >= currentConfig.height {
                    connection.videoOrientation = .landscapeRight
                } else {
                    connection.videoOrientation = .portrait
                }
            }
            
            session.commitConfiguration()
            NSLog("[OMTCapture] Switched camera to %@", useFront ? "front" : "back")
        }
    }
    
    // MARK: - Private
    
    private func setupCaptureSession(config: Config) {
        let newSession = AVCaptureSession()
        newSession.beginConfiguration()
        
        // Select camera
        let position: AVCaptureDevice.Position = config.useFrontCamera ? .front : .back
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: position) else {
            newSession.commitConfiguration()
            onError?("No camera available")
            return
        }
        
        // Configure camera
        do {
            try camera.lockForConfiguration()
            
            // Set frame rate
            let targetFPS = CMTime(value: CMTimeValue(config.frameRateD),
                                   timescale: CMTimeScale(config.frameRateN))
            camera.activeVideoMinFrameDuration = targetFPS
            camera.activeVideoMaxFrameDuration = targetFPS
            
            // Auto-focus and auto-exposure
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            
            camera.unlockForConfiguration()
        } catch {
            NSLog("[OMTCapture] Camera config error: %@", error.localizedDescription)
        }
        
        // Add camera input
        guard let input = try? AVCaptureDeviceInput(device: camera) else {
            newSession.commitConfiguration()
            onError?("Cannot create camera input")
            return
        }
        
        if newSession.canAddInput(input) {
            newSession.addInput(input)
        }
        
        // Configure video output — request standard iOS biplanar YCbCr format (NV12)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        
        if newSession.canAddOutput(output) {
            newSession.addOutput(output)
        }
        
        // Set resolution preset
        let preset = selectSessionPreset(width: config.width, height: config.height)
        if newSession.canSetSessionPreset(preset) {
            newSession.sessionPreset = preset
        }
        
        // Set video orientation based on aspect ratio
        if let connection = output.connection(with: .video) {
            if config.width >= config.height {
                // Broadcast standard is landscape for 16:9 resolutions (1080p, 720p)
                connection.videoOrientation = .landscapeRight
            } else {
                connection.videoOrientation = .portrait
            }
            if config.useFrontCamera {
                connection.isVideoMirrored = true
            }
        }
        
        newSession.commitConfiguration()
        
        self.session = newSession
        self.videoOutput = output
        
        newSession.startRunning()
        NSLog("[OMTCapture] Session started %dx%d @ %.2f fps (preset: %@)",
              config.width, config.height, config.fps, preset.rawValue)
    }
    
    private func selectSessionPreset(width: Int, height: Int) -> AVCaptureSession.Preset {
        let maxDim = max(width, height)
        if maxDim >= 3840 { return .hd4K3840x2160 }
        if maxDim >= 1920 { return .hd1920x1080 }
        if maxDim >= 1280 { return .hd1280x720 }
        return .vga640x480
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension OMTVideoCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        // Update FPS counter
        frameCount += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(lastStatsTime)
        if elapsed >= 1.0 {
            _measuredFPS = Double(frameCount) / elapsed
            frameCount = 0
            lastStatsTime = now
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        actualWidth = Int32(width)
        actualHeight = Int32(height)
        
        // Fast path: pass CVPixelBuffer directly to sender (< 2ms) bypassing 35ms software loop
        // The sender retains and locks the CVPixelBuffer safely on its serial encoding thread.
        if let onPixelBuffer = self.onPixelBuffer {
            onPixelBuffer(pixelBuffer, Int32(width), Int32(height))
            return
        }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return
        }
        
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        
        // Output UYVY size = width * height * 2 bytes
        var uyvyData = Data(count: width * height * 2)
        uyvyData.withUnsafeMutableBytes { outRaw in
            guard let outPtr = outRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
            let uvPtr = uvBase.assumingMemoryBound(to: UInt8.self)
            
            for y in 0..<height {
                let yRow = yPtr.advanced(by: y * yStride)
                let uvRow = uvPtr.advanced(by: (y >> 1) * uvStride)
                var outRow = outPtr.advanced(by: y * width * 2)
                
                var x = 0
                while x < width {
                    let y0 = yRow[x]
                    let y1 = yRow[x + 1]
                    let u = uvRow[x]
                    let v = uvRow[x + 1]
                    
                    outRow[0] = u
                    outRow[1] = y0
                    outRow[2] = v
                    outRow[3] = y1
                    outRow = outRow.advanced(by: 4)
                    
                    x += 2
                }
            }
        }
        
        onFrame?(uyvyData, Int32(width), Int32(height))
    }
    
    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Frame dropped by AVCapture — normal under high load
    }
}
