import Flutter
import UIKit
import CoreImage
import AVFoundation
import Photos

class NDIViewFactory: NSObject, FlutterPlatformViewFactory {
    private var messenger: FlutterBinaryMessenger
    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { return FlutterStandardMessageCodec.sharedInstance() }

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        return NDIView(frame: frame, viewIdentifier: viewId, arguments: args, binaryMessenger: messenger)
    }
}

class NDIView: NSObject, FlutterPlatformView {
    private var _view: UIView
    private var displayLayer: CALayer?
    private var isRunning = true
    private var channel: FlutterMethodChannel?
    
    // NDI Receiver
    private var recvInstance: NDIlib_recv_instance_t?
    private let receiveQueue = DispatchQueue(label: "ndi.receive.queue", qos: .userInteractive)
    private var currentSourceName: String?
    private var currentQuality: String = "480p"
    
    // Auto-Recovery (Auto-Healing)
    private var lastCaptureTime: TimeInterval = CACurrentMediaTime()
    private var isRecovering = false
    private let recoveryQueue = DispatchQueue(label: "ndi.recovery.queue", qos: .background)
    
    // Rendering & Throttling
    private var lastFrameTime: TimeInterval = 0
    private var frameInterval: TimeInterval = 0.033 // ~30 FPS
    private let ciContext = CIContext(options: [
        .workingColorSpace: NSNull(),
        .useSoftwareRenderer: false,
        .cacheIntermediates: false // 🛠️ CRITICAL FIX: Pour vider la RAM immédiatement
    ])
    
    // Audio Player
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    private var isMuted = false

    // Recording (AVAssetWriter) - ULTRA OPTIMIZED 500k
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var isRecording = false
    private var startTime: CMTime?
    private let recordingQueue = DispatchQueue(label: "ndi.record.queue", qos: .utility)

    // Jitter Buffer (Shield)
    private var videoBuffer: [CGImage] = []
    private let targetBufferCount = 6  // 6 images de réserve (0.2s)
    private let maxBufferSafety = 12   // On jette l'ancien si on dépasse
    private var displayTimer: Timer?
    private let bufferLock = NSLock()

    init(frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?, binaryMessenger messenger: FlutterBinaryMessenger?) {
        _view = UIView(frame: frame)
        _view.backgroundColor = .black
        
        // SETUP CALAYER FOR VIDEO
        // Note: frame will be set properly in layoutSubviews, not here (bounds is zero at init)
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        _view.layer.addSublayer(layer)
        self.displayLayer = layer
        
        super.init()
        
        if let messenger = messenger {
            self.channel = FlutterMethodChannel(name: "com.antigravity/ndi_view_\(viewId)", binaryMessenger: messenger)
            self.channel?.setMethodCallHandler(handle)
        }
        
        if let params = args as? [String: Any] {
            self.isMuted = params["muted"] as? Bool ?? false
            if !isMuted { setupAudioEngine() }
            
            if let name = params["name"] as? String {
                self.currentSourceName = name
                self.currentQuality = params["quality"] as? String ?? "Lowest"
                self.startReceive(sourceName: name, quality: self.currentQuality)
            }
        }
        
        startDisplayTimer()
        startCaptureLoop()
    }

    private func startDisplayTimer() {
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            self?.displayNextFrame()
        }
    }

    private func displayNextFrame() {
        bufferLock.lock()
        guard !videoBuffer.isEmpty else { 
            bufferLock.unlock()
            return 
        }
        let nextFrame = videoBuffer.removeFirst()
        bufferLock.unlock()
        
        DispatchQueue.main.async { [weak self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.displayLayer?.contents = nextFrame
            CATransaction.commit()
        }
    }

    func view() -> UIView { 
        // Update layer frame every time the view is requested
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.displayLayer?.frame = self._view.bounds
        }
        return _view 
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "toggleRecord":
            isRecording ? stopRecording() : startRecording()
            result(isRecording)
        case "switchQuality":
            if let q = call.arguments as? String {
                self.currentQuality = q
                if let name = currentSourceName { self.startReceive(sourceName: name, quality: q) }
                result(true)
            }
        case "refreshSources":
            refreshSources()
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func refreshSources() {
        print("🔄 Nettoyage du cache mDNS et recherche de nouvelles sources...")
        guard let find = NDIManager.shared.findInstance else { return }
        // On force un rafraîchissement réseau (1s) pour retrouver les caméras PTZ
        NDIlib_find_wait_for_sources(find, 1000)
        var noSources: UInt32 = 0
        let _ = NDIlib_find_get_current_sources(find, &noSources)
        print("✅ Refresh terminé : \(noSources) sources détectées sur le plateau.")
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        guard let engine = audioEngine, let node = playerNode else { return }
        
        engine.attach(node)
        audioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)
        
        if let format = audioFormat { 
            engine.connect(node, to: engine.mainMixerNode, format: format) 
        }
        
        do {
            let session = AVAudioSession.sharedInstance()
            // PLAYBACK ONLY - no microphone needed for NDI monitoring
            // Using .playAndRecord causes immediate crash if microphone not permitted
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
            
            engine.prepare() 
            try engine.start()
            node.play()
            print("✅ Audio Engine Ready")
        } catch { 
            print("❌ Audio Session Error: \(error)") 
        }
    }

    private func startReceive(sourceName: String, quality: String) {
        receiveQueue.async { [weak self] in
            guard let self = self else { return }
            if let old = self.recvInstance { NDIlib_recv_destroy(old); self.recvInstance = nil }
            var recvCreate = NDIlib_recv_create_v3_t()
            guard let find = NDIManager.shared.findInstance else { return }
            var noSources: UInt32 = 0
            let currentSources = NDIlib_find_get_current_sources(find, &noSources)
            var targetSource: NDIlib_source_t?
            if noSources > 0, let sources = currentSources {
                for i in 0..<Int(noSources) {
                    if String(cString: sources[i].p_ndi_name) == sourceName { targetSource = sources[i]; break }
                }
            }
            guard let source = targetSource else { return }
            recvCreate.source_to_connect_to = source
            recvCreate.color_format = NDIlib_recv_color_format_BGRX_BGRA
            recvCreate.bandwidth = (quality == "480p") ? NDIlib_recv_bandwidth_lowest : NDIlib_recv_bandwidth_highest
            recvCreate.allow_video_fields = false
            self.recvInstance = NDIlib_recv_create_v3(&recvCreate)
        }
    }

    private func startCaptureLoop() {
        receiveQueue.async { [weak self] in
            while let self = self, self.isRunning {
                autoreleasepool {
                    guard let recv = self.recvInstance else { usleep(50000); return }
                    var v = NDIlib_video_frame_v2_t()
                    var a = NDIlib_audio_frame_v2_t()
                    var m = NDIlib_metadata_frame_t()
                    let type = NDIlib_recv_capture_v2(recv, &v, &a, &m, 16)
                    
                    if type == NDIlib_frame_type_video {
                        self.lastCaptureTime = CACurrentMediaTime()
                        let now = CACurrentMediaTime()
                        if now - self.lastFrameTime >= self.frameInterval {
                            self.lastFrameTime = now
                            self.renderAndDisplay(v)
                        }
                        var mutV = v
                        NDIlib_recv_free_video_v2(recv, &mutV)
                    } else if type == NDIlib_frame_type_audio {
                        // Heartbeat based on audio too is safer
                        self.lastCaptureTime = CACurrentMediaTime()
                        if !self.isMuted { self.playAudio(a) }
                        var mutA = a
                        NDIlib_recv_free_audio_v2(recv, &mutA)
                    } else if type == NDIlib_frame_type_metadata {
                        var mutM = m
                        NDIlib_recv_free_metadata(recv, &mutM)
                    } else {
                        // Check for Auto-Recovery if no frame received
                        if CACurrentMediaTime() - self.lastCaptureTime > 2.0 {
                            self.performAutoRecovery()
                        }
                        usleep(4000)
                    }
                }
            }
        }
    }

    private func performAutoRecovery() {
        guard !isRecovering, let name = currentSourceName else { return }
        isRecovering = true
        print("⚠️ Flux NDI perdu (Heartbeat Timeout). Tentative de reconnexion automatique...")
        
        recoveryQueue.async { [weak self] in
            guard let self = self else { return }
            // Reset discovery manually to refresh network targets
            self.refreshSources()
            
            // Restart receiver (Always keeping Proxy/Current quality priority)
            self.startReceive(sourceName: name, quality: self.currentQuality)
            
            // Wait a bit before resetting flag to avoid recovery-loop
            usleep(2000000) // 2s
            self.lastCaptureTime = CACurrentMediaTime()
            self.isRecovering = false
        }
    }

    private func renderAndDisplay(_ frame: NDIlib_video_frame_v2_t) {
        let width = Int(frame.xres)
        let height = Int(frame.yres)
        let stride = Int(frame.line_stride_in_bytes)
        guard let p_data = frame.p_data else { return }
        
        // AGGRESSIVE MEMORY CLEANUP: Move all objects inside the pool
        autoreleasepool {
            let data = Data(bytes: p_data, count: stride * height)
            
            let ciImage = CIImage(
                bitmapData: data,
                bytesPerRow: stride,
                size: CGSize(width: width, height: height),
                format: .BGRA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
            
            if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
                // Shield Buffer: au lieu d'afficher, on stocke
                bufferLock.lock()
                // Si le réseau accélère trop, on vide le surplus pour rester à 0.2s
                if videoBuffer.count > maxBufferSafety {
                    videoBuffer.removeFirst(videoBuffer.count - targetBufferCount)
                }
                videoBuffer.append(cgImage)
                bufferLock.unlock()
                
                if isRecording {
                    recordingQueue.async { [weak self] in 
                        self?.writeFrameToVideo(cgImage: cgImage) 
                    }
                }
            }
        }
    }

    private func playAudio(_ frame: NDIlib_audio_frame_v2_t) {
        guard let engine = audioEngine, engine.isRunning,
              let node = playerNode, node.isPlaying,
              let format = audioFormat, !isMuted else { return }

        let noSamples = Int(frame.no_samples)
        let noChannels = Int(frame.no_channels)
        guard let data = frame.p_data, noSamples > 0 else { return }
              
        // AGGRESSIVE MEMORY CLEANUP for Audio Buffers
        autoreleasepool {
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(noSamples)) else { return }
            pcmBuffer.frameLength = AVAudioFrameCount(noSamples)
            
            let floatStride = Int(frame.channel_stride_in_bytes) / 4
            
            if let floatChannels = pcmBuffer.floatChannelData {
                for ch in 0..<min(noChannels, 2) {
                    let dest = floatChannels[ch]
                    let srcChannelData = data.advanced(by: ch * floatStride)
                    memcpy(dest, srcChannelData, noSamples * 4) 
                }
            }
            node.scheduleBuffer(pcmBuffer, at: nil, options: .interruptsAtLoop, completionHandler: nil)
        }
    }


    // ─────────────────────────────
    // RECORDING LOGIC (OPTIMIZED 500k)
    // ─────────────────────────────
    private func startRecording() {
        let path = NSTemporaryDirectory() + "ndi_record.mp4"
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        do {
            assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
            // RÉGLAGES PRO BROADCAST (500 kbps) POUR STABILITÉ MAXIMALE
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 960,  // Résolution optimisée pour le monitoring
                AVVideoHeightKey: 540,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 500000, // 500 kbps (Hard-limit)
                    AVVideoMaxKeyFrameIntervalKey: 30, // Structure spatiale stable
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoExpectedSourceFrameRateKey: 25 // Standard Broadcast
                ]
            ]
            assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            assetWriterInput?.expectsMediaDataInRealTime = true
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 960,
                kCVPixelBufferHeightKey as String: 540
            ]
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: assetWriterInput!, sourcePixelBufferAttributes: attributes)
            if assetWriter!.canAdd(assetWriterInput!) {
                assetWriter!.add(assetWriterInput!)
                assetWriter!.startWriting()
                assetWriter!.startSession(atSourceTime: .zero)
                isRecording = true
                startTime = nil
                print("🔴 Recording Started (500kbps)")
            }
        } catch { print("❌ Record error: \(error)") }
    }

    private func stopRecording() {
        isRecording = false
        recordingQueue.async { [weak self] in
            self?.assetWriterInput?.markAsFinished()
            self?.assetWriter?.finishWriting { [weak self] in
                if let url = self?.assetWriter?.outputURL {
                    UISaveVideoAtPathToSavedPhotosAlbum(url.path, nil, nil, nil)
                    print("✅ Record Saved @ 500kbps to Gallery")
                }
            }
        }
    }

    private func writeFrameToVideo(cgImage: CGImage) {
        guard let adaptor = pixelBufferAdaptor, let input = assetWriterInput, input.isReadyForMoreMediaData else { return }
        let now = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)
        if startTime == nil { startTime = now }
        let timestamp = CMTimeSubtract(now, startTime!)
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
        if status == kCVReturnSuccess, let buffer = pixelBuffer {
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 960, height: 540, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: 960, height: 540))
            adaptor.append(buffer, withPresentationTime: timestamp)
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
    }

    deinit {
        isRunning = false
        displayTimer?.invalidate()
        displayTimer = nil
        bufferLock.lock()
        videoBuffer.removeAll()
        bufferLock.unlock()
        
        if isRecording { stopRecording() }
        playerNode?.stop()
        audioEngine?.stop()
        if let recv = recvInstance { NDIlib_recv_destroy(recv) }
    }
}
