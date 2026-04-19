import Foundation
import UIKit
import AVFoundation

class NDIManager: NSObject {
    static let shared = NDIManager()

    // Discovery (Finder)
    private var findInstance: NDIlib_find_instance_t?
    private var cachedSources = [String]()
    private let discoveryQueue = DispatchQueue(label: "ndi.discovery.queue", qos: .background)
    private var currentExtraIps: String? // 🌐 IPs Tailscale/Distantes
    let sourcesQueue = DispatchQueue(label: "ndi.sources.queue", qos: .userInteractive)

    // NDI Send state (Camera)
    private var sendInstance: NDIlib_send_instance_t?
    private var persistentSendName: UnsafeMutablePointer<CChar>?
    private var captureSession: AVCaptureSession?
    private let captureQueue = DispatchQueue(label: "ndi.capture.queue", qos: .userInitiated)
    private let sendQueue = DispatchQueue(label: "ndi.send.queue", qos: .userInitiated)
    private(set) var currentCameraPosition: AVCaptureDevice.Position = .back

    // 🎬 NDI RELAY SYSTEM (MIMO_NDI_SWITCH → TriCaster)
    private var relaySendInstance: NDIlib_send_instance_t?
    private var relayRecvInstance: NDIlib_recv_instance_t?
    private let relayQueue = DispatchQueue(label: "ndi.relay.queue", qos: .userInteractive)
    private var relayRunning = false
    private var persistentRelaySendName: UnsafeMutablePointer<CChar>?
    private(set) var isRelayActive = false

    override init() {
        super.init()
        if !NDIlib_initialize() { return }

        // Audio Setup
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("❌ AVAudioSession FAIL: \(error)")
        }

        recreateFinder()
    }

    func setExtraIps(_ ips: String) {
        if self.currentExtraIps == ips { return }
        self.currentExtraIps = ips.isEmpty ? nil : ips
        recreateFinder()
    }

    private func recreateFinder() {
        discoveryQueue.sync {
            if let old = self.findInstance {
                NDIlib_find_destroy(old)
                self.findInstance = nil
            }
            var findCreate = NDIlib_find_create_t()
            findCreate.show_local_sources = true
            if let extra = self.currentExtraIps {
                findCreate.p_extra_ips = (extra as NSString).utf8String
            }
            self.findInstance = NDIlib_find_create_v2(&findCreate)
        }
        if !discoveryRunning { startBackgroundDiscovery() }
    }

    private var discoveryRunning = false
    private func startBackgroundDiscovery() {
        guard !discoveryRunning else { return }
        discoveryRunning = true
        discoveryQueue.async { [weak self] in
            while true {
                guard let self = self else { break }
                guard let find = self.findInstance else { sleep(1); continue }
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
                self.cachedSources = names
                usleep(500_000)
            }
        }
    }

    func getSources() -> [String] { return cachedSources }

    func startSend(sourceName: String) {
        if sendInstance != nil { stopSend() }
        if let oldName = persistentSendName { free(oldName) }
        if let utf8str = (sourceName as NSString).utf8String {
            persistentSendName = strdup(utf8str)
        }
        sendQueue.async { [weak self] in
            guard let self = self else { return }
            var sendCreate = NDIlib_send_create_t()
            if let namePtr = self.persistentSendName {
                sendCreate.p_ndi_name = UnsafePointer(namePtr)
            }
            self.sendInstance = NDIlib_send_create(&sendCreate)
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
            }
        }
    }

    func getCaptureSession() -> AVCaptureSession? { return captureSession }

    func setupCamera(position: AVCaptureDevice.Position = .back) {
        let session = AVCaptureSession()
        session.sessionPreset = .hd1280x720 // Stable for TriCaster (March 28)
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: sendQueue)
        output.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(output) { session.addOutput(output) }

        if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = self.currentOrientation()
        }

        captureSession = session
        currentCameraPosition = position
        session.startRunning()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: NSNotification.Name("CameraReady"), object: nil)
        }
    }

    func switchCamera(toFront: Bool) {
        let newPosition: AVCaptureDevice.Position = toFront ? .front : .back
        guard let session = captureSession,
              let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
              let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if session.canAddInput(newInput) { session.addInput(newInput) }
        session.commitConfiguration()
        currentCameraPosition = newPosition
    }

    // 🎬 RELAY SYSTEM
    func startRelaySender() {
        guard relaySendInstance == nil else { return }
        if let utf8 = ("MIMO_NDI_SWITCH" as NSString).utf8String {
            if let old = persistentRelaySendName { free(old) }
            persistentRelaySendName = strdup(utf8)
        }
        var sendCreate = NDIlib_send_create_t()
        sendCreate.p_ndi_name = UnsafePointer(persistentRelaySendName)
        relaySendInstance = NDIlib_send_create(&sendCreate)
        isRelayActive = true
    }

    func switchRelay(to sourceName: String) {
        relayRunning = false
        relayQueue.async { [weak self] in
            guard let self = self else { return }
            if let old = self.relayRecvInstance { NDIlib_recv_destroy(old) }
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
            self.relayRecvInstance = NDIlib_recv_create_v3(&recvCreate)
            self.relayRunning = true
            while self.relayRunning, let recv = self.relayRecvInstance, let send = self.relaySendInstance {
                autoreleasepool {
                    var video = NDIlib_video_frame_v2_t()
                    if NDIlib_recv_capture_v2(recv, &video, nil, nil, 16) == NDIlib_frame_type_video {
                        NDIlib_send_send_video_v2(send, &video)
                        NDIlib_recv_free_video_v2(recv, &video)
                    } else { usleep(10000) }
                }
            }
        }
    }

    func stopRelay() {
        relayRunning = false
        isRelayActive = false
        if let recv = relayRecvInstance { NDIlib_recv_destroy(recv); relayRecvInstance = nil }
        if let send = relaySendInstance { NDIlib_send_destroy(send); relaySendInstance = nil }
    }
}

extension NDIManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // ✅ Hardware orientation (from March 28 stability)
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
        videoFrame.xres = Int32(width)
        videoFrame.yres = Int32(height)
        videoFrame.picture_aspect_ratio = Float(width) / Float(height)
        videoFrame.FourCC = NDIlib_FourCC_video_type_BGRA
        videoFrame.frame_rate_N = 30000
        videoFrame.frame_rate_D = 1001
        videoFrame.frame_format_type = NDIlib_frame_format_type_progressive
        videoFrame.timecode = Int64.max
        videoFrame.line_stride_in_bytes = Int32(stride)
        videoFrame.p_data = data?.bindMemory(to: UInt8.self, capacity: stride * height)

        NDIlib_send_send_video_v2(send, &videoFrame)
    }

    private func currentOrientation() -> AVCaptureVideoOrientation {
        let orientation: UIInterfaceOrientation
        if #available(iOS 13.0, *) {
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
