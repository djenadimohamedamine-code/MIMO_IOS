import Foundation
import UIKit
import AVFoundation

class NDIManager: NSObject {
    static let shared = NDIManager()

    // Discovery (Finder)
    var findInstance: NDIlib_find_instance_t?
    private var cachedSources = [String]()
    private let discoveryQueue = DispatchQueue(label: "ndi.discovery.queue", qos: .background)
    let sourcesQueue = DispatchQueue(label: "ndi.sources.queue", qos: .userInteractive)

    // NDI Send state (Camera)
    private var sendInstance: NDIlib_send_instance_t?
    private var persistentSendName: UnsafeMutablePointer<CChar>?
    private var captureSession: AVCaptureSession?
    private let captureQueue = DispatchQueue(label: "ndi.capture.queue", qos: .userInitiated)
    private let sendQueue = DispatchQueue(label: "ndi.send.queue", qos: .userInitiated)
    private(set) var currentCameraPosition: AVCaptureDevice.Position = .back
    private var currentFps: Int32 = 30
    private var lastFrameTime = CACurrentMediaTime()
    private var lastSendTime = CACurrentMediaTime() // 🔧 Watchdog NDI
    
    // 🏗️ PRO PIPELINE: LOCK & STATE
    private var outputPixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0
    private let flightLock = DispatchQueue(label: "ndi.flight.lock")

    // 🎬 NDI RELAY SYSTEM (MIMO_NDI_SWITCH → TriCaster)
    private var relaySendInstance: NDIlib_send_instance_t?
    private var relayRecvInstance: NDIlib_recv_instance_t?
    private let relayQueue = DispatchQueue(label: "ndi.relay.queue", qos: .userInteractive)
    private var relayRunning = false
    private var persistentRelaySendName: UnsafeMutablePointer<CChar>?
    private(set) var isRelayActive = false

    // 🛠️ SHARED RESOURCES
    let sharedAudioEngine = AVAudioEngine()
    let sharedCIContext = CIContext(options: [
        .workingColorSpace: NSNull(),
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])

    override init() {
        super.init()
        CrashLogger.log("🎬 NDIManager.init() appelé")

        // 🚨 PATTERN STABLE : Initialisation SYNCHRONE
        CrashLogger.log("🔍 NDI: Initialisation de la librairie (Sync)...")
        if !NDIlib_initialize() { 
            CrashLogger.log("❌ NDI: Échec de l'initialisation de la lib")
            return 
        }

        var findCreate = NDIlib_find_create_t()
        findCreate.show_local_sources = true
        CrashLogger.log("🔍 NDI: Création Finder...")
        self.findInstance = NDIlib_find_create_v2(&findCreate)

        if self.findInstance != nil {
            CrashLogger.log("✅ NDI: Finder prêt")
            self.startBackgroundDiscovery()
        } else {
            CrashLogger.log("❌ NDI: Impossible de créer le Finder")
        }

        // AudioSession (OK sur main thread)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("❌ AVAudioSession FAIL: \(error)")
        }

        // 🏥 LIFECYCLE WATCHDOG : Redémarrer session après background
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleOrientationChange), name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }

    @objc private func handleAppDidBecomeActive() {
        captureQueue.async { [weak self] in
            guard let self = self, let session = self.captureSession else { return }
            if !session.isRunning {
                print("🏥 Watchdog: CaptureSession was stopped, restarting...")
                session.startRunning()
            }
        }
    }

    @objc private func handleOrientationChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let orient = self.currentOrientation()
            self.captureQueue.async { [weak self] in
                guard let self = self, let session = self.captureSession else { return }
                session.outputs.forEach { output in
                    if let conn = output.connection(with: .video), conn.isVideoOrientationSupported {
                        if conn.videoOrientation != orient {
                            conn.videoOrientation = orient
                            print("🔄 NDI orientation mise à jour: \(orient.rawValue)")
                        }
                    }
                }
            }
        }
    }

    private func startBackgroundDiscovery() {
        discoveryQueue.async { [weak self] in
            while true {
                guard let find = self?.findInstance else { break }
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
                self?.cachedSources = names
                sleep(30) // 💤 30 secondes — On ne touche plus au réseau pendant qu'on filme
            }
        }
    }

    func getSources() -> [String] {
        return cachedSources
    }

    // ─────────────────────────────
    // SEND (Camera → NDI)
    // ─────────────────────────────
    func startSend(sourceName: String) {
        // Stop previous instance safely on sendQueue
        if sendInstance != nil { stopSend() }
        if let oldName = persistentSendName { free(oldName) }
        if let utf8str = (sourceName as NSString).utf8String {
            persistentSendName = strdup(utf8str)
        }
        // ✅ Create new sendInstance on sendQueue to avoid race with captureOutput
        sendQueue.async { [weak self] in
            guard let self = self else { return }
            var sendCreate = NDIlib_send_create_t()
            if let namePtr = self.persistentSendName {
                sendCreate.p_ndi_name = UnsafePointer(namePtr)
            }
            sendCreate.p_groups = nil
            sendCreate.clock_video = false
            sendCreate.clock_audio = false
            self.sendInstance = NDIlib_send_create(&sendCreate)
            guard self.sendInstance != nil else { return }
            print("✅ NDI Sender démarré: \(String(cString: self.persistentSendName!))")
            if self.captureSession == nil {
                DispatchQueue.main.async { self.setupCamera() }
            }
        }
    }

    func stopSend() {
        sendQueue.async { [weak self] in
            guard let self = self else { return }
            if let send = self.sendInstance {
                self.sendInstance = nil
                NDIlib_send_destroy(send)
                print("✅ NDI Sender Destroyed Safely")
            }
        }
    }

    func getCaptureSession() -> AVCaptureSession? {
        return captureSession
    }

    func setupCamera(position: AVCaptureDevice.Position = .back, resolution: String = "720p", fps: Int32 = 30) {
        self.currentFps = fps

        captureQueue.async { [weak self] in
            guard let self = self else { return }

            // 🧹 NETTOYAGE RADICAL
            if let oldSession = self.captureSession {
                oldSession.stopRunning()
                self.captureSession = nil
            }

            let session = AVCaptureSession()
            session.beginConfiguration()
            
            // ✅ Retour à 720p fixe pour stabilité maximale
            session.sessionPreset = .hd1280x720
            
            // On s'assure que tout est vierge
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                session.commitConfiguration()
                return
            }
            
            // ✅ Framerate fixe 30 fps
            try? device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
            
            if session.canAddInput(input) { session.addInput(input) }
            
            let output = AVCaptureVideoDataOutput()
            // ✅ Retour au format BGRA (Original)
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: self.captureQueue)
            output.alwaysDiscardsLateVideoFrames = true
            
            if session.canAddOutput(output) {
                session.addOutput(output)
                if let connection = output.connection(with: .video) {
                    if connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .off
                    }
                    if connection.isVideoOrientationSupported {
                        DispatchQueue.main.sync {
                            connection.videoOrientation = self.currentOrientation()
                        }
                    }
                }
            }

            self.outputPixelBufferPool = nil // Reset pool
            
            session.commitConfiguration()
            
            self.captureSession = session
            self.currentCameraPosition = position
            
            // 🧠 Ordre AVFoundation : Configurer AVANT startRunning
            session.automaticallyConfiguresApplicationAudioSession = false
            
            session.startRunning()
            print("🚀 Caméra opérationnelle (State: Ready - 720p RGB)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: NSNotification.Name("CameraReady"), object: nil)
            }
        }
    }

    func switchCamera(toFront: Bool) {
        let newPosition: AVCaptureDevice.Position = toFront ? .front : .back
        guard let session = captureSession else { return }

        captureQueue.async { [weak self] in
            guard let self = self else { return }
            
            session.beginConfiguration()
            for input in session.inputs {
                session.removeInput(input)
            }
            
            guard let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
                  let newInput = try? AVCaptureDeviceInput(device: newDevice) else {
                session.commitConfiguration()
                return
            }
            
            if session.canAddInput(newInput) { 
                session.addInput(newInput) 
            }
            session.commitConfiguration()
            
            // On s'assure que l'orientation est correcte pour la nouvelle connexion
            self.handleOrientationChange()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NotificationCenter.default.post(name: NSNotification.Name("CameraReady"), object: nil)
            }
            
            self.currentCameraPosition = newPosition
        }
    }

    func setZoom(factor: CGFloat) {
        guard let session = captureSession,
              let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
        try? device.lockForConfiguration()
        device.videoZoomFactor = max(1.0, min(factor, device.activeFormat.videoMaxZoomFactor))
        device.unlockForConfiguration()
    }

    func setTorch(on: Bool) {
        guard let session = captureSession,
              let device = (session.inputs.first as? AVCaptureDeviceInput)?.device,
              device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    // ──────────────────────────────────────────────────
    // 🎬 NDI RELAY → TriCaster (MIMO_NDI_SWITCH)
    // ──────────────────────────────────────────────────
    func startRelaySender() {
        guard relaySendInstance == nil else { return }
        if let oldName = persistentRelaySendName { free(oldName) }
        if let utf8 = ("MIMO_NDI_SWITCH" as NSString).utf8String {
            persistentRelaySendName = strdup(utf8)
        }
        var sendCreate = NDIlib_send_create_t()
        if let namePtr = persistentRelaySendName {
            sendCreate.p_ndi_name = UnsafePointer(namePtr)
        }
        sendCreate.clock_video = false
        sendCreate.clock_audio = false
        relaySendInstance = NDIlib_send_create(&sendCreate)
        isRelayActive = true
        print("✅ MIMO_NDI_SWITCH relay sender ready")
    }

    func switchRelay(to sourceName: String) {
        relayRunning = false
        relayQueue.async { [weak self] in
            guard let self = self else { return }
            if let old = self.relayRecvInstance {
                NDIlib_recv_destroy(old)
                self.relayRecvInstance = nil
            }
            guard let find = self.findInstance else { return }
            var noSources: UInt32 = 0
            let sources = NDIlib_find_get_current_sources(find, &noSources)
            var target: NDIlib_source_t?
            if noSources > 0, let sources = sources {
                for i in 0..<Int(noSources) {
                    if String(cString: sources[i].p_ndi_name) == sourceName {
                        target = sources[i]; break
                    }
                }
            }
            guard let source = target else { return }
            var recvCreate = NDIlib_recv_create_v3_t()
            recvCreate.source_to_connect_to = source
            recvCreate.color_format = NDIlib_recv_color_format_BGRX_BGRA
            recvCreate.bandwidth = NDIlib_recv_bandwidth_highest
            recvCreate.allow_video_fields = false
            self.relayRecvInstance = NDIlib_recv_create_v3(&recvCreate)
            self.relayRunning = true
            while self.relayRunning,
                  let recv = self.relayRecvInstance,
                  let send = self.relaySendInstance {
                autoreleasepool {
                    var video = NDIlib_video_frame_v2_t()
                    let type = NDIlib_recv_capture_v2(recv, &video, nil, nil, 16)
                    if type == NDIlib_frame_type_video {
                        NDIlib_send_send_video_v2(send, &video)
                        var mutV = video
                        NDIlib_recv_free_video_v2(recv, &mutV)
                    } else {
                        // 💤 Micro-pause si pas d'image pour éviter 100% CPU
                        usleep(10000) 
                    }
                }
            }
        }
    }

    func stopRelay() {
        relayRunning = false
        relayQueue.async { [weak self] in
            if let recv = self?.relayRecvInstance {
                NDIlib_recv_destroy(recv)
                self?.relayRecvInstance = nil
            }
        }
        if let send = relaySendInstance {
            NDIlib_send_destroy(send)
            relaySendInstance = nil
        }
        isRelayActive = false
        print("🛑 MIMO_NDI_SWITCH relay stopped")
    }

    private func getPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if outputPixelBufferPool == nil || poolWidth != width || poolHeight != height {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &outputPixelBufferPool)
            poolWidth = width
            poolHeight = height
        }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, outputPixelBufferPool!, &pixelBuffer)
        return pixelBuffer
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let find = findInstance { NDIlib_find_destroy(find) }
        if let send = sendInstance { NDIlib_send_destroy(send) }
        if let name = persistentSendName { free(name) }
        NDIlib_destroy()
    }
}

extension NDIManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let send = sendInstance else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
        guard let data = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        var videoFrame = NDIlib_video_frame_v2_t()
        videoFrame.xres = Int32(width)
        videoFrame.yres = Int32(height)
        // ✅ Format BGRA natif (RGB)
        videoFrame.FourCC = NDIlib_FourCC_video_type_BGRA
        videoFrame.frame_rate_N = 30000
        videoFrame.frame_rate_D = 1001
        videoFrame.picture_aspect_ratio = Float(width) / Float(height)
        videoFrame.frame_format_type = NDIlib_frame_format_type_progressive
        videoFrame.timecode = Int64.max
        videoFrame.line_stride_in_bytes = Int32(stride)
        videoFrame.p_data = data.bindMemory(to: UInt8.self, capacity: stride * height)

        NDIlib_send_send_video_v2(send, &videoFrame)
        self.lastSendTime = CACurrentMediaTime()
    }

    private func currentOrientation() -> AVCaptureVideoOrientation {
        // On utilise l'orientation physique du device, car l'interface Flutter peut être bloquée en Portrait
        let deviceOrient = UIDevice.current.orientation
        switch deviceOrient {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight // ⚠ Inversé par rapport à l'UI
        case .landscapeRight: return .landscapeLeft
        default: return .portrait
        }
    }
}
