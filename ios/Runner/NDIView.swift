import Flutter
import UIKit
import CoreImage
import AVFoundation

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
    
    // NDI Receiver
    private var recvInstance: NDIlib_recv_instance_t?
    private let receiveQueue = DispatchQueue(label: "ndi.receive.queue", qos: .userInteractive)
    
    // Throttling (30 fps / 0.033s)
    private var lastFrameTime: TimeInterval = 0
    private var frameInterval: TimeInterval = 0.033
    
    // Contexte CIContext PERSISTANT pour rendu GPU Haute Performance
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull(), .useSoftwareRenderer: false])
    
    // Audio Player
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    private var isMuted = false

    init(frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?, binaryMessenger messenger: FlutterBinaryMessenger?) {
        _view = UIView(frame: frame)
        _view.backgroundColor = .black
        imageView = UIImageView(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        _view.addSubview(imageView)
        
        super.init()
        
        if let params = args as? [String: Any] {
            self.isMuted = params["muted"] as? Bool ?? false
            if !isMuted { setupAudioEngine() }
            
            if let name = params["name"] as? String {
                let quality = params["quality"] as? String ?? "Highest"
                self.startReceive(sourceName: name, quality: quality)
            }
        }
        startCaptureLoop()
    }

    func view() -> UIView { return _view }

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
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers, .duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            node.play()
        } catch { print("❌ Audio Error: \(error)") }
    }

    private func startReceive(sourceName: String, quality: String) {
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
        
        guard let source = targetSource else { return }
        recvCreate.source_to_connect_to = source
        recvCreate.color_format = NDIlib_recv_color_format_BGRX_BGRA
        recvCreate.bandwidth = (quality == "Lowest") ? NDIlib_recv_bandwidth_lowest : NDIlib_recv_bandwidth_highest
        recvCreate.allow_video_fields = true
        recvInstance = NDIlib_recv_create_v3(&recvCreate)
    }

    private func startCaptureLoop() {
        receiveQueue.async { [weak self] in
            while self?.isRunning == true {
                guard let recv = self?.recvInstance else {
                    usleep(50000); continue
                }

                var v = NDIlib_video_frame_v2_t()
                var a = NDIlib_audio_frame_v2_t()
                var m = NDIlib_metadata_frame_t()
                
                // Timeout 16ms pour ne pas saturer le CPU
                let type = NDIlib_recv_capture_v2(recv, &v, &a, &m, 16)
                
                if type == NDIlib_frame_type_video {
                    let now = CACurrentMediaTime()
                    if now - (self?.lastFrameTime ?? 0) >= (self?.frameInterval ?? 0.033) {
                        self?.lastFrameTime = now
                        // On lance le rendu et on attend qu'il soit "figé" dans le GPU
                        // avant de libérer le buffer NDI (SÉCURITÉ MAXIMALE)
                        self?.renderAndDisplay(v)
                    }
                    var mutV = v
                    NDIlib_recv_free_video_v2(recv, &mutV)
                } else if type == NDIlib_frame_type_audio {
                    if !(self?.isMuted ?? true) {
                        self?.playAudio(a)
                    }
                    var mutA = a
                    NDIlib_recv_free_audio_v2(recv, &mutA)
                } else if type == NDIlib_frame_type_metadata {
                    NDIlib_recv_free_metadata(recv, &m)
                } else {
                    usleep(4000)
                }
            }
        }
    }

    private func playAudio(_ frame: NDIlib_audio_frame_v2_t) {
        let noSamples = Int(frame.no_samples)
        let noChannels = Int(frame.no_channels)
        guard let data = frame.p_data, noSamples > 0, let player = playerNode, let format = audioFormat else { return }
        
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(noSamples)) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(noSamples)
        
        let channels = pcmBuffer.floatChannelData
        let stride = Int(frame.channel_stride_in_bytes) / 4
        
        for ch in 0..<min(noChannels, 2) {
            if let dest = channels?[ch] {
                memcpy(dest, data.advanced(by: ch * stride), noSamples * 4)
            }
        }
        player.scheduleBuffer(pcmBuffer, at: nil, options: [])
    }

    private func renderAndDisplay(_ frame: NDIlib_video_frame_v2_t) {
        let width = Int(frame.xres)
        let height = Int(frame.yres)
        let stride = Int(frame.line_stride_in_bytes)
        guard let p_data = frame.p_data else { return }
        
        // --- RENDU GPU DIRECT (ZÉRO COPY SÉCURISÉ) ---
        // On crée la CIImage sans copie mémoire
        let ciImage = CIImage(
            bitmapData: Data(bytesNoCopy: p_data, count: stride * height, deallocator: .none),
            bytesPerRow: stride,
            size: CGSize(width: width, height: height),
            format: .BGRA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        
        // --- LA CORRECTION "BÉTON" ---
        // On force le GPU à "figer" l'image dans sa mémoire AVANT de rendre la main.
        // Une fois createCGImage terminé, on peut libérer la frame NDI en toute sécurité.
        if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
            let uiImage = UIImage(cgImage: cgImage)
            DispatchQueue.main.async { [weak self] in
                self?.imageView.image = uiImage
            }
        }
    }

    deinit {
        isRunning = false
        playerNode?.stop()
        audioEngine?.stop()
        if let recv = recvInstance { NDIlib_recv_destroy(recv) }
    }
}
