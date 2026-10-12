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
        let useFrontCamera: Bool
        
        var fps: Double {
            return Double(frameRateN) / Double(frameRateD)
        }
    }
    
    // MARK: - Callbacks
    
    /// Called on each captured frame with UYVY pixel data and actual dimensions
    var onFrame: ((Data, Int32, Int32) -> Void)?
    var onError: ((String) -> Void)?
    
    // MARK: - State
    
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var config: Config?
    private let captureQueue = DispatchQueue(label: "com.antigravity.omt.capture",
                                             qos: .userInteractive)
    private var frameCount: Int64 = 0
    private var lastStatsTime: Date = Date()
    private var _measuredFPS: Double = 0
    
    var measuredFPS: Double { return _measuredFPS }
    
    // MARK: - Public API
    
    /// Start camera capture with the given configuration
    func startCapture(config: Config) {
        self.config = config
        
        captureQueue.async { [weak self] in
            self?.setupCaptureSession(config: config)
        }
    }
    
    /// Stop camera capture and release resources
    func stopCapture() {
        captureQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
            self?.captureSession = nil
            self?.videoOutput = nil
        }
    }
    
    // MARK: - Private
    
    private func setupCaptureSession(config: Config) {
        let session = AVCaptureSession()
        
        // Select camera
        let position: AVCaptureDevice.Position = config.useFrontCamera ? .front : .back
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: position) else {
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
            onError?("Cannot create camera input")
            return
        }
        
        if session.canAddInput(input) {
            session.addInput(input)
        }
        
        // Configure video output — request standard iOS biplanar YCbCr format (NV12)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        
        // Set resolution preset
        let preset = selectSessionPreset(width: config.width, height: config.height)
        if session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
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
        
        self.captureSession = session
        self.videoOutput = output
        
        session.startRunning()
        NSLog("[OMTCapture] Session started %dx%d @ %.2f fps",
              config.width, config.height, config.fps)
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
        
        // Extract NV12 planes and convert to UYVY (4:2:2) format for OMT
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
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
                let yRow = yPtr + (y * yStride)
                let uvRow = uvPtr + ((y / 2) * uvStride)
                let outRow = outPtr + (y * width * 2)
                
                var x = 0
                while x < width - 1 {
                    let y0 = yRow[x]
                    let y1 = yRow[x + 1]
                    let u = uvRow[x]
                    let v = uvRow[x + 1]
                    
                    let outIdx = x * 2
                    outRow[outIdx]     = u
                    outRow[outIdx + 1] = y0
                    outRow[outIdx + 2] = v
                    outRow[outIdx + 3] = y1
                    
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
