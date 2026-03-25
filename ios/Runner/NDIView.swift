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
    private var imageView: UIImageView
    private var isRunning = true
    private var channel: FlutterMethodChannel?
    
    // NDI Receiver
    private var recvInstance: NDIlib_recv_instance_t?
    private let receiveQueue = DispatchQueue(label: "ndi.receive.queue", qos: .userInteractive)
    private var currentSourceName: String?
    private var currentQuality: String = "Lowest"
    
    // Rendering & Throttling
    private var lastFrameTime: TimeInterval = 0
    private var frameInterval: TimeInterval = 0.033 // ~30 FPS
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull(), .useSoftwareRenderer: false])
    
    // Audio Player
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    private var isMuted = false

    // Recording (AVAssetWriter)
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var isRecording = false
    private var startTime: CMTime?
    private let recordingQueue = DispatchQueue(label: "ndi.record.queue", qos: .utility)

    init(frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?, binaryMessenger messenger: FlutterBinaryMessenger?) {
        _view = UIView(frame: frame)
        _view.backgroundColor = .black
        imageView = UIImageView(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        _view.addSubview(imageView)
        
        super.init()
        
        // Setup Channel
        if let messenger = messenger {
            self.channel = FlutterMethodChannel(name: "com.antigravity/ndi_view_\(viewId)", binaryMessenger: messenger)
            self.channel?.setMethodCallHandler(handle)
        }
        
        if let params = args as? [String: Any] {
            self.isMuted = params["muted"] as? Bool ?? false
            if !isMuted { setupAudioEngine() }
            
            if let name = params["name"] as? String {
                self.currentSourceName = name
                // DÉMARRAGE EN PROXY PAR DÉFAUT (Lowest)
                self.currentQuality = params["quality"] as? String ?? "Lowest"
                self.startReceive(sourceName: name, quality: self.currentQuality)
            }
        }
        startCaptureLoop()
    }

    func view() -> UIView { return _view }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "toggleRecord":
            isRecording ? stopRecording() : startRecording()
            result(isRecording)
        case "switchQuality":
            if let q = call.arguments as? String {
                self.currentQuality = q
                if let name = currentSourceName {
                    startReceive(sourceName: name, quality: q)
                }
                result(true)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
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
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            node.play()
        } catch { print("❌ Audio Error: \(error)") }
    }

    private func startReceive(sourceName: String, quality: String) {
        // IMPORTANT: On fait le switch sur la file d'attente NDI, pas sur l'UI Thread
        receiveQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Si une instance existe déjà, on la libère proprement
            if let old = self.recvInstance { 
                NDIlib_recv_destroy(old)
                self.recvInstance = nil 
            }

            var recvCreate = NDIlib_recv_create_v3_t()
            guard let find = NDIManager.shared.findInstance else { return }
            
            var noSources: UInt32 = 0
            let currentSources = NDIlib_find_get_current_sources(find, &noSources)
            var targetSource: NDIlib_source_t?
            
            if noSources > 0, let sources = currentSources {
                for i in 0..<Int(noSources) {
                    if String(cString: sources[i].p_ndi_name) == sourceName {
                        targetSource = sources[i]; break
                    }
                }
            }
            
            guard let source = targetSource else { 
                print("⚠️ Source NDI introuvable")
                return 
            }
            
            recvCreate.source_to_connect_to = source
            recvCreate.color_format = NDIlib_recv_color_format_BGRX_BGRA
            
            // Si on reçoit "480p" ou "Lowest" de Flutter, on active le mode Proxy
            if quality == "480p" || quality == "Lowest" {
                recvCreate.bandwidth = NDIlib_recv_bandwidth_lowest
                print("📺 Mode Proxy (480p) activé")
            } else {
                recvCreate.bandwidth = NDIlib_recv_bandwidth_highest
                print("📺 Mode HD activé")
            }
            
            recvCreate.allow_video_fields = false
            self.recvInstance = NDIlib_recv_create_v3(&recvCreate)
        }
    }

    private func startCaptureLoop() {
        receiveQueue.async { [weak self] in
            while let self = self, self.isRunning {
                autoreleasepool {
                    guard let recv = self.recvInstance else {
                        usleep(50000); return
                    }

                    var v = NDIlib_video_frame_v2_t()
                    var a = NDIlib_audio_frame_v2_t()
                    var m = NDIlib_metadata_frame_t()
                    
                    let type = NDIlib_recv_capture_v2(recv, &v, &a, &m, 16)
                    
                    if type == NDIlib_frame_type_video {
                        let now = CACurrentMediaTime()
                        if now - self.lastFrameTime >= self.frameInterval {
                            self.lastFrameTime = now
                            self.renderAndDisplay(v)
                        }
                        var mutV = v
                        NDIlib_recv_free_video_v2(recv, &mutV)
                    } else if type == NDIlib_frame_type_audio {
                        if !self.isMuted { self.playAudio(a) }
                        var mutA = a
                        NDIlib_recv_free_audio_v2(recv, &mutA)
                    } else if type == NDIlib_frame_type_metadata {
                        var mutM = m
                        NDIlib_recv_free_metadata(recv, &mutM)
                    } else {
                        usleep(4000)
                    }
                }
            }
        }
    }

    private func renderAndDisplay(_ frame: NDIlib_video_frame_v2_t) {
        let width = Int(frame.xres)
        let height = Int(frame.yres)
        let stride = Int(frame.line_stride_in_bytes)
        guard let p_data = frame.p_data else { return }
        
        let ciImage = CIImage(
            bitmapData: Data(bytesNoCopy: p_data, count: stride * height, deallocator: .none),
            bytesPerRow: stride,
            size: CGSize(width: width, height: height),
            format: .BGRA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        
        if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
            let uiImage = UIImage(cgImage: cgImage)
            DispatchQueue.main.async { [weak self] in
                self?.imageView.image = uiImage
            }
            // RECORDING logic
            if isRecording {
                writeFrameToVideo(cgImage: cgImage)
            }
        }
    }

    private func playAudio(_ frame: NDIlib_audio_frame_v2_t) {
        let noSamples = Int(frame.no_samples)
        let noChannels = Int(frame.no_channels)
        guard let data = frame.p_data, noSamples > 0, let node = playerNode, let format = audioFormat else { return }
        
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(noSamples)) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(noSamples)
        let channels = pcmBuffer.floatChannelData
        let stride = Int(frame.channel_stride_in_bytes) / 4
        for ch in 0..<min(noChannels, 2) {
            if let dest = channels?[ch] { memcpy(dest, data.advanced(by: ch * stride), noSamples * 4) }
        }
        node.scheduleBuffer(pcmBuffer, at: nil, options: [])
    }

    // ─────────────────────────────
    // RECORDING LOGIC
    // ─────────────────────────────
    private func startRecording() {
        let path = NSTemporaryDirectory() + "ndi_record.mp4"
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        
        do {
            assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1280,
                AVVideoHeightKey: 720
            ]
            assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            assetWriterInput?.expectsMediaDataInRealTime = true
            
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 1280,
                kCVPixelBufferHeightKey as String: 720
            ]
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: assetWriterInput!, sourcePixelBufferAttributes: attributes)
            
            if assetWriter!.canAdd(assetWriterInput!) {
                assetWriter!.add(assetWriterInput!)
                assetWriter!.startWriting()
                assetWriter!.startSession(atSourceTime: .zero)
                isRecording = true
                startTime = nil
                print("🔴 Recording Started")
            }
        } catch { print("❌ Record error: \(error)") }
    }

    private func stopRecording() {
        isRecording = false
        assetWriterInput?.markAsFinished()
        assetWriter?.finishWriting { [weak self] in
            if let url = self?.assetWriter?.outputURL {
                UISaveVideoAtPathToSavedPhotosAlbum(url.path, nil, nil, nil)
                print("✅ Video Saved to Photos")
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
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1280, height: 720))
            adaptor.append(buffer, withPresentationTime: timestamp)
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
    }

    deinit {
        isRunning = false
        if isRecording { stopRecording() }
        playerNode?.stop()
        audioEngine?.stop()
        if let recv = recvInstance { NDIlib_recv_destroy(recv) }
    }
}
