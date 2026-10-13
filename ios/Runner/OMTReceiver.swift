import Foundation
import Network
import CoreGraphics
import UIKit
import AVFoundation

/// High-performance Open Media Transport (OMT) video and audio receiver for iOS.
/// Connects to an OMT source (such as vMix 29) over TCP, negotiates subscription
/// with <OMTSubscribe Video="true" /> and <OMTSubscribe Audio="true" />, defragments incoming TCP frames,
/// decodes VMX1 compressed video using libvmx (ARM NEON) into BGRA,
/// plays back FPA1 planar 32-bit floating-point audio with low-latency via AVAudioEngine,
/// and produces CGImage frames for real-time rendering at 30-60 FPS.
class OMTReceiver {
    
    // MARK: - Properties
    
    let host: String
    let port: UInt16
    let sourceName: String
    
    private(set) var isRunning: Bool = false
    private var connection: NWConnection?
    private let receiveQueue = DispatchQueue(label: "com.antigravity.omt.receiver", qos: .userInteractive)
    private let decodeQueue = DispatchQueue(label: "com.antigravity.omt.receiver.decode", qos: .userInteractive)
    
    // VMX Decoder
    private var vmxBridge: OMTVMXBridge?
    private var currentWidth: Int32 = 0
    private var currentHeight: Int32 = 0
    
    // Defragmentation buffer
    private var receiveBuffer = Data()
    private var parsedFrameCount = 0
    
    // Audio Player & Receiver (matching libomtnet dual-connection architecture)
    private var audioConnection: NWConnection?
    private let audioReceiveQueue = DispatchQueue(label: "com.antigravity.omt.receiver.audio", qos: .userInteractive)
    private var audioReceiveBuffer = Data()
    private var audioPlayer: OMTAudioPlayer?
    
    // Callbacks
    var onFrameDecoded: ((CGImage, Int32, Int32) -> Void)?
    var onStateChanged: ((OMTManager.State) -> Void)?
    var onError: ((String) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    var onStatsUpdated: (([String: Any]) -> Void)?
    
    // Telemetry Statistics
    private(set) var framesReceived: Int64 = 0
    private(set) var framesDecoded: Int64 = 0
    private(set) var framesDropped: Int64 = 0
    private(set) var bytesReceived: Int64 = 0
    private(set) var actualWidth: Int32 = 0
    private(set) var actualHeight: Int32 = 0
    private(set) var codecName: String = "VMX1"
    private(set) var currentFps: Double = 0.0
    private(set) var currentBitrateKbps: Double = 0.0
    
    // Audio Telemetry
    private(set) var audioFramesReceived: Int64 = 0
    private(set) var audioSampleRate: Int32 = 0
    private(set) var audioChannels: Int32 = 0
    private(set) var audioCodecName: String = "FPA1"
    
    private var lastStatTime = Date()
    private var bytesSinceLastStat: Int64 = 0
    private var framesSinceLastStat: Int = 0
    
    // MARK: - Initialization
    
    init(host: String, port: UInt16, sourceName: String) {
        self.host = host
        self.port = port
        self.sourceName = sourceName
    }
    
    deinit {
        stop()
    }
    
    // MARK: - Lifecycle
    
    func start() {
        guard !isRunning else { return }
        isRunning = true
        
        receiveBuffer.removeAll(keepingCapacity: true)
        parsedFrameCount = 0
        framesReceived = 0
        framesDecoded = 0
        framesDropped = 0
        bytesReceived = 0
        bytesSinceLastStat = 0
        framesSinceLastStat = 0
        lastStatTime = Date()
        
        audioFramesReceived = 0
        audioSampleRate = 0
        audioChannels = 0
        audioReceiveBuffer.removeAll(keepingCapacity: true)
        audioPlayer = OMTAudioPlayer()
        
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onError?("Port invalide: \(port)")
            onStateChanged?(.error)
            return
        }
        
        let cleanHost = host.components(separatedBy: "%").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? host
        guard !cleanHost.isEmpty else {
            onError?("Hôte non valide ou vide: \(host)")
            onStateChanged?(.error)
            return
        }
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(cleanHost), port: nwPort)
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true // Disable Nagle's algorithm for low-latency broadcast
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 5
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 3
        
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.prohibitExpensivePaths = false
        
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn
        
        conn.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            NSLog("[OMTReceiver][TCP] %@:%d state=%@", self.host, self.port, String(describing: newState))
            self.onDiagnostic?("TCP \(self.host):\(self.port) state=\(newState)")
            switch newState {
            case .ready:
                NSLog("[OMTReceiver] Connected to %@:%d (%@)", self.host, self.port, self.sourceName)
                // TCP ready does not mean OMT subscription or video is established.
                self.sendSubscription()
                self.scheduleReceive()
                
            case .failed(let error):
                NSLog("[OMTReceiver] Connection failed at %@:%d: %@", self.host, self.port, String(describing: error))
                self.onDiagnostic?("TCP failed after \(self.bytesReceived) bytes: \(error)")
                self.onError?("Erreur réseau: \(error.localizedDescription)")
                self.stop()
                self.onStateChanged?(.error)
                
            case .cancelled:
                NSLog("[OMTReceiver] Connection cancelled")
                // Ignore cancellation from stop() after an error or user action.
                // The manager owns the final idle/error state.
                self.onDiagnostic?("TCP cancelled (receiver running=\(self.isRunning))")
                
            case .waiting(let error):
                NSLog("[OMTReceiver] Connection waiting at %@:%d: %@", self.host, self.port, String(describing: error))
                
            default:
                break
            }
        }
        
        conn.start(queue: receiveQueue)
        NSLog("[OMTReceiver] Connecting to %@:%d...", host, port)
        
        // Start dedicated audio connection (dual-socket architecture matching libomtnet)
        let audioTcpOptions = NWProtocolTCP.Options()
        audioTcpOptions.noDelay = true
        audioTcpOptions.enableKeepalive = true
        audioTcpOptions.keepaliveIdle = 5
        audioTcpOptions.keepaliveInterval = 5
        audioTcpOptions.keepaliveCount = 3
        let audioParams = NWParameters(tls: nil, tcp: audioTcpOptions)
        audioParams.prohibitExpensivePaths = false
        self.startAudioConnection(endpoint: endpoint, params: audioParams)
    }
    
    func stop() {
        guard isRunning else { return }
        isRunning = false
        
        connection?.cancel()
        connection = nil
        
        audioConnection?.cancel()
        audioConnection = nil
        audioReceiveBuffer.removeAll(keepingCapacity: false)
        
        audioPlayer?.stop()
        audioPlayer = nil
        
        vmxBridge?.destroy()
        vmxBridge = nil
        currentWidth = 0
        currentHeight = 0
        
        receiveBuffer.removeAll(keepingCapacity: false)
        NSLog("[OMTReceiver] Stopped receiver for %@", sourceName)
    }
    
    // MARK: - OMT Protocol Handshake
    
    private func sendSubscription() {
        guard let conn = connection else { return }
        
        // Build official libomtnet handshake sequence (OMTReceive.cs lines 424-434):
        // 1. <OMTSubscribe Metadata="true" />  (subscribes to metadata channel)
        // 2. <OMTSubscribe Video="true" />     (subscribes to video stream)
        // 3. <OMTSettings Quality="Default" /> (suggested encoding quality)
        // 4. <OMTTally Preview="true" Program=="true" /> (signals active viewer tally)
        var handshakeData = Data()
        
        let metaSub = OMTFrameBuilder.buildMetadataFrame(xmlString: OMTMetadataCommand.subscribeMetadata)
        let videoSub = OMTFrameBuilder.buildMetadataFrame(xmlString: OMTMetadataCommand.subscribeVideo)
        let qualitySet = OMTFrameBuilder.buildMetadataFrame(xmlString: OMTMetadataCommand.qualityDefault)
        let tallySet = OMTFrameBuilder.buildMetadataFrame(xmlString: OMTMetadataCommand.tallyPreviewProgram)
        
        handshakeData.append(metaSub)
        handshakeData.append(videoSub)
        handshakeData.append(qualitySet)
        handshakeData.append(tallySet)
        
        conn.send(content: handshakeData, completion: .contentProcessed { [weak self] error in
            if let error = error {
                NSLog("[OMTReceiver] Failed to send handshake (%d bytes): %@", handshakeData.count, String(describing: error))
                self?.onError?("Abonnement vidéo échoué: \(error.localizedDescription)")
            } else {
                NSLog("[OMTReceiver] Full OMT handshake sent (%d bytes): MetaSub(%d), VideoSub(%d), Quality(%d), Tally(%d)",
                      handshakeData.count, metaSub.count, videoSub.count, qualitySet.count, tallySet.count)
                self?.onDiagnostic?("OMT handshake sent (\(handshakeData.count) bytes: meta(\(metaSub.count))+video(\(videoSub.count))+quality(\(qualitySet.count))+tally(\(tallySet.count)))")
            }
        })
    }
    
    // MARK: - TCP Reception & Defragmentation
    
    private func scheduleReceive() {
        guard let conn = connection, isRunning else { return }
        
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, context, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[OMTReceiver] Receive error after %lld bytes: %@", self.bytesReceived, String(describing: error))
                self.onDiagnostic?("Receive error after \(self.bytesReceived) bytes: \(error)")
                self.onError?(error.localizedDescription)
                self.stop()
                self.onStateChanged?(.error)
                return
            }
            
            if let data = content, !data.isEmpty {
                // DEBUG: log first chunk received from vMix
                if self.bytesReceived == 0 {
                    let hexStr = data.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " ")
                    NSLog("[OMTReceiver] FIRST BYTES FROM VMIX (%d bytes): %@", data.count, hexStr)
                    self.onDiagnostic?("First TCP payload: \(data.count) bytes, hex=\(hexStr)")
                    if let ascii = String(data: data.prefix(128), encoding: .utf8) {
                        NSLog("[OMTReceiver] AS ASCII: %@", ascii)
                    }
                }
                self.processIncomingBytes(data)
            }
            
            if isComplete {
                NSLog("[OMTReceiver] TCP stream closed by remote host")
                self.onDiagnostic?("Remote closed TCP after \(self.bytesReceived) bytes")
                self.stop()
                self.onStateChanged?(.idle)
                return
            }
            
            if self.isRunning {
                self.scheduleReceive()
            }
        }
    }
    
    private func processIncomingBytes(_ chunk: Data) {
        bytesSinceLastStat += Int64(chunk.count)
        bytesReceived += Int64(chunk.count)
        receiveBuffer.append(chunk)
        
        // Process complete OMT frames
        // Each frame has a 16-byte Main Header:
        // [0]: Version (1)
        // [1]: FrameType (1=Metadata, 2=Video, 4=Audio)
        // [2..9]: Timestamp (Int64 LE)
        // [10..11]: MetadataLength (UInt16 LE)
        // [12..15]: DataLength (Int32 LE)
        while receiveBuffer.count >= 16 {
            let frameType = receiveBuffer[1]
            let version = receiveBuffer[0]
            let metadataLen = Int(receiveBuffer[10]) | (Int(receiveBuffer[11]) << 8)
            
            // Data storage is not guaranteed to be aligned for Int32.load.
            let dataLen = receiveBuffer.readLEInt32(offset: 12)
            
            // Sanity check dataLen (protect against corrupt stream / desync)
            guard dataLen >= 0 && dataLen <= 60_000_000 else {
                NSLog("[OMTReceiver] Stream desync detected: invalid dataLen %d, skipping 1 byte", dataLen)
                receiveBuffer.remove(at: 0)
                continue
            }
            
            if parsedFrameCount < 8 {
                onDiagnostic?("OMT header: version=\(version) type=\(frameType) metadataLen=\(metadataLen) dataLen=\(dataLen) buffered=\(receiveBuffer.count)")
            }
            let totalFrameLength = 16 + Int(dataLen)
            if receiveBuffer.count < totalFrameLength {
                // Incomplete frame, wait for more data from TCP
                break
            }
            
            // Extract complete payload and slice buffer
            let payload = receiveBuffer.subdata(in: 16..<totalFrameLength)
            receiveBuffer.removeSubrange(0..<totalFrameLength)
            parsedFrameCount += 1
            
            if frameType == OMTFrameType.video.rawValue {
                handleVideoPayload(payload)
            } else if frameType == OMTFrameType.metadata.rawValue {
                handleMetadataPayload(payload)
            } else if frameType == OMTFrameType.audio.rawValue {
                handleAudioPayload(payload)
            }
        }
        
        if framesReceived == 0 && bytesReceived > 0 && parsedFrameCount < 8 {
            onDiagnostic?("OMT parser waiting: bytesTotal=\(bytesReceived) framesParsed=\(parsedFrameCount) buffered=\(receiveBuffer.count)")
        }
        updateStatsIfNeeded()
    }
    
    // MARK: - Video Parsing & VMX1 Decoding
    
    private func handleVideoPayload(_ payload: Data) {
        framesReceived += 1
        if framesReceived == 1 {
            NSLog("[OMTReceiver] First complete OMT video frame: %d payload bytes", payload.count)
            onDiagnostic?("First OMT video frame: \(payload.count) bytes")
            onStateChanged?(.receiving)
        }
        
        // Video payload begins with 32-byte Video Extended Header:
        // [0..3]:   Codec FourCC (Int32 LE) e.g. 0x31584D56 ('VMX1')
        // [4..7]:   Width (Int32 LE)
        // [8..11]:  Height (Int32 LE)
        // [12..15]: FrameRateN (Int32 LE)
        // [16..19]: FrameRateD (Int32 LE)
        // [20..23]: AspectRatio (Float32 LE)
        // [24..27]: Flags (Int32 LE)
        // [28..31]: ColorSpace (Int32 LE)
        guard payload.count >= 32 else {
            framesDropped += 1
            return
        }
        
        let codec = payload.readLEInt32(offset: 0)
        let width = payload.readLEInt32(offset: 4)
        let height = payload.readLEInt32(offset: 8)
        
        guard width > 0 && width <= 4096 && height > 0 && height <= 4096 else {
            framesDropped += 1
            return
        }
        
        self.actualWidth = width
        self.actualHeight = height
        
        let videoData = payload.subdata(in: 32..<payload.count)
        guard !videoData.isEmpty else {
            framesDropped += 1
            return
        }
        
        // Dispatch frame decoding to concurrent decode queue
        decodeQueue.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            
            if codec == OMTVideoCodec.vmx1 {
                self.codecName = "VMX1"
                self.decodeVMX1Frame(videoData: videoData, width: width, height: height)
            } else if codec == OMTVideoCodec.uyvy {
                self.codecName = "UYVY"
                self.decodeUYVYFrame(videoData: videoData, width: width, height: height)
            } else {
                // Unknown codec FourCC
                self.codecName = String(format: "0x%08X", codec)
                self.framesDropped += 1
            }
        }
    }
    
    private func decodeVMX1Frame(videoData: Data, width: Int32, height: Int32) {
        // Initialize or update VMX bridge if resolution changed
        if vmxBridge == nil || currentWidth != width || currentHeight != height {
            vmxBridge?.destroy()
            vmxBridge = OMTVMXBridge(width: width, height: height)
            currentWidth = width
            currentHeight = height
            NSLog("[OMTReceiver] Initialized VMX1 decoder instance for %dx%d", width, height)
        }
        
        guard let bridge = vmxBridge else {
            framesDropped += 1
            return
        }
        
        let stride = Int(width) * 4 // BGRA 32-bit: 4 bytes per pixel
        let bufferSize = stride * Int(height)
        var bgraData = Data(count: bufferSize)
        
        let success: Bool = bgraData.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return bridge.decodeVMX(videoData, toBGRA: base, stride: Int32(stride))
        }
        
        if success {
            if let cgImage = createCGImage(from: bgraData, width: Int(width), height: Int(height), stride: stride) {
                framesDecoded += 1
                framesSinceLastStat += 1
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.onFrameDecoded?(cgImage, width, height)
                    NotificationCenter.default.post(
                        name: NSNotification.Name("OMTFrameDecoded"),
                        object: nil,
                        userInfo: ["image": cgImage, "width": width, "height": height]
                    )
                }
            } else {
                framesDropped += 1
            }
        } else {
            framesDropped += 1
            if let err = bridge.lastError {
                NSLog("[OMTReceiver] VMX decode error: %@", err)
            }
        }
    }
    
    private func decodeUYVYFrame(videoData: Data, width: Int32, height: Int32) {
        let numPixels = Int(width * height)
        guard videoData.count >= numPixels * 2 else {
            framesDropped += 1
            return
        }
        
        var bgraData = Data(count: numPixels * 4)
        videoData.withUnsafeBytes { srcPtr in
            bgraData.withUnsafeMutableBytes { dstPtr in
                guard let src = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let dst = dstPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                
                let pairs = numPixels / 2
                for i in 0..<pairs {
                    let u = Int(src[i * 4 + 0]) - 128
                    let y0 = Int(src[i * 4 + 1])
                    let v = Int(src[i * 4 + 2]) - 128
                    let y1 = Int(src[i * 4 + 3])
                    
                    // Pixel 0
                    let r0 = max(0, min(255, y0 + (359 * v) / 256))
                    let g0 = max(0, min(255, y0 - (88 * u + 183 * v) / 256))
                    let b0 = max(0, min(255, y0 + (454 * u) / 256))
                    
                    // Pixel 1
                    let r1 = max(0, min(255, y1 + (359 * v) / 256))
                    let g1 = max(0, min(255, y1 - (88 * u + 183 * v) / 256))
                    let b1 = max(0, min(255, y1 + (454 * u) / 256))
                    
                    // BGRA output
                    dst[i * 8 + 0] = UInt8(b0)
                    dst[i * 8 + 1] = UInt8(g0)
                    dst[i * 8 + 2] = UInt8(r0)
                    dst[i * 8 + 3] = 255
                    
                    dst[i * 8 + 4] = UInt8(b1)
                    dst[i * 8 + 5] = UInt8(g1)
                    dst[i * 8 + 6] = UInt8(r1)
                    dst[i * 8 + 7] = 255
                }
            }
        }
        
        if let cgImage = createCGImage(from: bgraData, width: Int(width), height: Int(height), stride: Int(width) * 4) {
            framesDecoded += 1
            framesSinceLastStat += 1
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onFrameDecoded?(cgImage, width, height)
                NotificationCenter.default.post(
                    name: NSNotification.Name("OMTFrameDecoded"),
                    object: nil,
                    userInfo: ["image": cgImage, "width": width, "height": height]
                )
            }
        } else {
            framesDropped += 1
        }
    }
    
    // MARK: - Metadata Handling
    
    private func handleMetadataPayload(_ payload: Data) {
        if let str = String(data: payload, encoding: .utf8) {
            let clean = str.trimmingCharacters(in: CharacterSet(charactersIn: "\0 \r\n"))
            NSLog("[OMTReceiver] Received metadata: %@", clean)
            onDiagnostic?("OMT metadata: \(String(clean.prefix(300)))")
        }
    }
    
    // MARK: - CGImage Generation
    
    private func createCGImage(from bgraData: Data, width: Int, height: Int, stride: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = [
            CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue),
            .byteOrder32Little
        ]
        guard let provider = CGDataProvider(data: bgraData as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: stride,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
    
    // MARK: - Statistics
    
    private func updateStatsIfNeeded() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastStatTime)
        if elapsed >= 1.0 {
            currentBitrateKbps = Double(bytesSinceLastStat * 8) / elapsed / 1000.0
            currentFps = Double(framesSinceLastStat) / elapsed
            bytesSinceLastStat = 0
            framesSinceLastStat = 0
            lastStatTime = now
            
            let stats = getStatsDict()
            DispatchQueue.main.async { [weak self] in
                self?.onStatsUpdated?(stats)
            }
        }
    }
    
    // MARK: - Audio TCP Reception & Subscription
    
    private func startAudioConnection(endpoint: NWEndpoint, params: NWParameters) {
        let conn = NWConnection(to: endpoint, using: params)
        self.audioConnection = conn
        
        conn.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            NSLog("[OMTReceiver][AudioTCP] %@:%d state=%@", self.host, self.port, String(describing: newState))
            switch newState {
            case .ready:
                NSLog("[OMTReceiver][AudioTCP] Audio socket connected to %@:%d", self.host, self.port)
                self.sendAudioSubscription()
                self.scheduleAudioReceive()
                
            case .failed(let error):
                // If remote source (e.g. Desktop Capture) doesn't accept a 2nd connection or has no audio,
                // quietly close without failing or interrupting the video stream.
                NSLog("[OMTReceiver][AudioTCP] Audio socket failed: %@ (video unaffected)", error.localizedDescription)
                self.onDiagnostic?("Audio TCP socket failed: \(error.localizedDescription) (video unaffected)")
                self.audioConnection?.cancel()
                self.audioConnection = nil
                
            case .cancelled:
                NSLog("[OMTReceiver][AudioTCP] Audio socket cancelled")
                
            default:
                break
            }
        }
        
        conn.start(queue: audioReceiveQueue)
    }
    
    private func sendAudioSubscription() {
        guard let conn = audioConnection else { return }
        
        // Match libomtnet dual-connection subscription (OMTReceive.cs lines 364-373):
        var audioHandshake = Data()
        let metaSub = OMTFrameBuilder.buildMetadataFrame(xmlString: OMTMetadataCommand.subscribeMetadata)
        let audioSub = OMTFrameBuilder.buildMetadataFrame(xmlString: OMTMetadataCommand.subscribeAudio)
        audioHandshake.append(metaSub)
        audioHandshake.append(audioSub)
        
        conn.send(content: audioHandshake, completion: .contentProcessed { [weak self] error in
            if let error = error {
                NSLog("[OMTReceiver][AudioTCP] Failed to send audio subscription: %@", error.localizedDescription)
            } else {
                NSLog("[OMTReceiver][AudioTCP] OMT audio subscription sent (%d bytes)", audioHandshake.count)
                self?.onDiagnostic?("OMT audio subscription sent (\(audioHandshake.count) bytes)")
            }
        })
    }
    
    private func scheduleAudioReceive() {
        guard let conn = audioConnection, isRunning else { return }
        
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, context, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[OMTReceiver][AudioTCP] Audio receive error: %@ (video unaffected)", error.localizedDescription)
                self.audioConnection?.cancel()
                self.audioConnection = nil
                return
            }
            
            if let data = content, !data.isEmpty {
                self.processIncomingAudioBytes(data)
            }
            
            if isComplete {
                NSLog("[OMTReceiver][AudioTCP] Remote closed audio socket (video unaffected)")
                self.audioConnection?.cancel()
                self.audioConnection = nil
                return
            }
            
            if self.isRunning && self.audioConnection != nil {
                self.scheduleAudioReceive()
            }
        }
    }
    
    private func processIncomingAudioBytes(_ chunk: Data) {
        audioReceiveBuffer.append(chunk)
        
        while audioReceiveBuffer.count >= 16 {
            let frameType = audioReceiveBuffer[1]
            let dataLen = audioReceiveBuffer.readLEInt32(offset: 12)
            
            guard dataLen >= 0 && dataLen <= 10_000_000 else {
                NSLog("[OMTReceiver][AudioTCP] Desync: invalid dataLen %d, skipping 1 byte", dataLen)
                audioReceiveBuffer.remove(at: 0)
                continue
            }
            
            let totalFrameLength = 16 + Int(dataLen)
            if audioReceiveBuffer.count < totalFrameLength {
                break
            }
            
            let payload = audioReceiveBuffer.subdata(in: 16..<totalFrameLength)
            audioReceiveBuffer.removeSubrange(0..<totalFrameLength)
            
            if frameType == OMTFrameType.audio.rawValue {
                handleAudioPayload(payload)
            } else if frameType == OMTFrameType.metadata.rawValue {
                handleMetadataPayload(payload)
            } else if frameType == OMTFrameType.video.rawValue {
                handleVideoPayload(payload)
            }
        }
    }
    
    private func handleAudioPayload(_ payload: Data) {
        audioFramesReceived += 1
        guard payload.count >= 24 else { return }
        guard let audioHdr = OMTAudioHeader(from: payload) else { return }
        
        self.audioSampleRate = audioHdr.sampleRate
        self.audioChannels = audioHdr.channels
        if audioHdr.codec == OMTAudioCodec.fpa1 {
            self.audioCodecName = "FPA1"
        } else {
            self.audioCodecName = String(format: "0x%08X", audioHdr.codec)
        }
        
        if audioFramesReceived == 1 {
            NSLog("[OMTReceiver] First OMT audio frame: %d Hz, %d ch, codec=%@", audioHdr.sampleRate, audioHdr.channels, self.audioCodecName)
            onDiagnostic?("First OMT audio frame: \(audioHdr.sampleRate) Hz, \(audioHdr.channels) ch, mask=0x\(String(audioHdr.activeChannels, radix: 16))")
        }
        
        let audioData = payload.subdata(in: 24..<payload.count)
        audioPlayer?.playAudioFrame(
            sampleRate: audioHdr.sampleRate,
            channels: audioHdr.channels,
            samplesPerChannel: audioHdr.samplesPerChannel,
            activeChannelsMask: audioHdr.activeChannels,
            audioData: audioData
        )
    }
    
    func getStatsDict() -> [String: Any] {
        return [
            "isReceiver": true,
            "sourceName": sourceName,
            "host": host,
            "port": Int(port),
            "actualWidth": actualWidth,
            "actualHeight": actualHeight,
            "codec": codecName,
            "fps": String(format: "%.1f", currentFps),
            "bitrateKbps": Int(currentBitrateKbps),
            "framesDecoded": framesDecoded,
            "framesReceived": framesReceived,
            "framesDropped": framesDropped,
            "bytesReceived": bytesReceived,
            "audioFramesReceived": audioFramesReceived,
            "audioSampleRate": audioSampleRate,
            "audioChannels": audioChannels,
            "audioCodec": audioCodecName,
            "state": isRunning ? "receiving" : "idle"
        ]
    }
}

// MARK: - OMTAudioPlayer

/// Real-time low-latency audio player for OMT streams using AVAudioEngine.
/// Decodes FPA1 planar 32-bit floating-point PCM audio (matching official libomtnet specification).
/// Handles arbitrary active channel bitmasks, filling silent channels with zeros,
/// and streaming non-interleaved float32 buffers directly to the iOS audio hardware.
class OMTAudioPlayer {
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var currentFormat: AVAudioFormat?
    private let audioQueue = DispatchQueue(label: "com.antigravity.omt.audioplayer", qos: .userInteractive)
    
    init() {
        audioQueue.async { [weak self] in
            self?.setupEngine()
        }
    }
    
    private func setupEngine() {
        audioEngine.attach(playerNode)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try? session.overrideOutputAudioPort(.speaker)
            try session.setActive(true)
        } catch {
            NSLog("[OMTAudioPlayer] AVAudioSession warning: %@", error.localizedDescription)
        }
    }
    
    func playAudioFrame(
        sampleRate: Int32,
        channels: Int32,
        samplesPerChannel: Int32,
        activeChannelsMask: UInt32,
        audioData: Data
    ) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            guard sampleRate >= 8000 && sampleRate <= 192000,
                  channels >= 1 && channels <= 16,
                  samplesPerChannel > 0 && samplesPerChannel <= 48000 else {
                return
            }
            
            let sr = Double(sampleRate)
            let chCount = AVAudioChannelCount(channels)
            
            // Reconfigure engine graph if format parameters change
            if self.currentFormat == nil ||
               self.currentFormat?.sampleRate != sr ||
               self.currentFormat?.channelCount != chCount {
                self.reconfigure(sampleRate: sr, channels: chCount)
            }
            
            guard let format = self.currentFormat,
                  let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samplesPerChannel)) else {
                return
            }
            pcmBuffer.frameLength = AVAudioFrameCount(samplesPerChannel)
            
            guard let floatChannelData = pcmBuffer.floatChannelData else { return }
            
            let channelByteCount = Int(samplesPerChannel) * MemoryLayout<Float>.size
            var dataOffset = 0
            
            for ch in 0..<Int(channels) {
                let channelPtr = floatChannelData[ch]
                let isActive = (activeChannelsMask & (UInt32(1) << ch)) != 0
                
                if isActive && (dataOffset + channelByteCount <= audioData.count) {
                    audioData.withUnsafeBytes { rawPtr in
                        if let src = rawPtr.baseAddress?.advanced(by: dataOffset) {
                            channelPtr.update(from: src.assumingMemoryBound(to: Float.self), count: Int(samplesPerChannel))
                        }
                    }
                    dataOffset += channelByteCount
                } else {
                    // Muted or silent channel: zero fill
                    memset(channelPtr, 0, channelByteCount)
                }
            }
            
            if !self.audioEngine.isRunning {
                do {
                    try self.audioEngine.start()
                } catch {
                    NSLog("[OMTAudioPlayer] Failed to start AVAudioEngine: %@", error.localizedDescription)
                    return
                }
            }
            
            if !self.playerNode.isPlaying {
                self.playerNode.play()
            }
            
            self.playerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)
        }
    }
    
    private func reconfigure(sampleRate: Double, channels: AVAudioChannelCount) {
        playerNode.stop()
        audioEngine.stop()
        
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else { return }
        
        self.currentFormat = format
        audioEngine.disconnectNodeOutput(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        
        do {
            try audioEngine.start()
            playerNode.play()
            NSLog("[OMTAudioPlayer] Reconfigured for %.0f Hz, %d channels", sampleRate, channels)
        } catch {
            NSLog("[OMTAudioPlayer] Engine start error: %@", error.localizedDescription)
        }
    }
    
    func stop() {
        audioQueue.sync {
            playerNode.stop()
            audioEngine.stop()
            audioEngine.disconnectNodeOutput(playerNode)
            currentFormat = nil
        }
    }
    
    deinit {
        playerNode.stop()
        audioEngine.stop()
        audioEngine.detach(playerNode)
    }
}
