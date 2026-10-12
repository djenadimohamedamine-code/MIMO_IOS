import Foundation
import Network
import CoreGraphics
import UIKit

/// High-performance Open Media Transport (OMT) video receiver for iOS.
/// Connects to an OMT source (such as vMix 29) over TCP, negotiates subscription
/// with <OMTSubscribe Video="true" />, defragments incoming TCP frames,
/// decodes VMX1 compressed video using libvmx (ARM NEON) into BGRA,
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
    // Limit outstanding decode work to one frame to protect RAM and latency.
    private let decodeGate = NSLock()
    private var decodePending = false

    // VMX Decoder
    private var vmxBridge: OMTVMXBridge?
    private var currentWidth: Int32 = 0
    private var currentHeight: Int32 = 0
    
    // Defragmentation buffer
    private var receiveBuffer = Data()
    
    // Callbacks
    var onFrameDecoded: ((CGImage, Int32, Int32) -> Void)?
    var onStateChanged: ((OMTManager.State) -> Void)?
    var onError: ((String) -> Void)?
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
        framesReceived = 0
        framesDecoded = 0
        framesDropped = 0
        bytesReceived = 0
        bytesSinceLastStat = 0
        framesSinceLastStat = 0
        lastStatTime = Date()
        
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onError?("Port invalide: \(port)")
            onStateChanged?(.error)
            return
        }
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true // Disable Nagle's algorithm for low-latency broadcast
        
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.prohibitExpensivePaths = false
        
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn
        
        conn.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            switch newState {
            case .ready:
                NSLog("[OMTReceiver] Connected to %@:%d (%@)", self.host, self.port, self.sourceName)
                self.onStateChanged?(.receiving)
                self.sendSubscription()
                self.scheduleReceive()
                
            case .failed(let error):
                NSLog("[OMTReceiver] Connection failed: %@", error.localizedDescription)
                self.onError?("Erreur réseau: \(error.localizedDescription)")
                self.onStateChanged?(.error)
                self.stop()
                
            case .cancelled:
                NSLog("[OMTReceiver] Connection cancelled")
                self.onStateChanged?(.idle)
                
            case .waiting(let error):
                NSLog("[OMTReceiver] Connection waiting: %@", error.localizedDescription)
                
            default:
                break
            }
        }
        
        conn.start(queue: receiveQueue)
        NSLog("[OMTReceiver] Connecting to %@:%d...", host, port)
    }
    
    func stop() {
        guard isRunning else { return }
        isRunning = false
        
        connection?.cancel()
        connection = nil
        
        // The decoder may still be processing its last frame. Destroy it on
        // its own serial queue rather than racing VMX_DecodeBGRA on another thread.
        decodeQueue.async { [weak self] in
            self?.vmxBridge?.destroy()
            self?.vmxBridge = nil
            self?.currentWidth = 0
            self?.currentHeight = 0
        }

        receiveBuffer.removeAll(keepingCapacity: false)
        NSLog("[OMTReceiver] Stopped receiver for %@", sourceName)
    }
    
    // MARK: - OMT Protocol Handshake
    
    private func sendSubscription() {
        guard let conn = connection else { return }
        
        // Build official OMT subscription metadata frame: <OMTSubscribe Video="true" />\0
        let subscribeXml = OMTMetadataCommand.subscribeVideo
        let frameData = OMTFrameBuilder.buildMetadataFrame(xmlString: subscribeXml)
        
        conn.send(content: frameData, completion: .contentProcessed { [weak self] error in
            if let error = error {
                NSLog("[OMTReceiver] Failed to send subscription: %@", error.localizedDescription)
                self?.onError?("Abonnement vidéo échoué: \(error.localizedDescription)")
            } else {
                NSLog("[OMTReceiver] Subscription sent: %@", subscribeXml)
            }
        })
    }
    
    // MARK: - TCP Reception & Defragmentation
    
    private func scheduleReceive() {
        guard let conn = connection, isRunning else { return }
        
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, context, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                NSLog("[OMTReceiver] Receive error: %@", error.localizedDescription)
                self.onError?(error.localizedDescription)
                self.stop()
                return
            }
            
            if let data = content, !data.isEmpty {
                self.processIncomingBytes(data)
            }
            
            if isComplete {
                NSLog("[OMTReceiver] TCP stream closed by remote host")
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
            // Reject corrupt headers rather than trusting random lengths or
            // performing a potentially unaligned Int32 pointer load on ARM64.
            guard receiveBuffer[0] == 1 else {
                receiveBuffer.removeFirst()
                continue
            }
            let frameType = receiveBuffer[1]
            let dataLen = receiveBuffer.readLEInt32(offset: 12)
            let metadataLen = Int(receiveBuffer.readLEUInt16(offset: 10))

            guard dataLen >= 0, dataLen <= 60_000_000,
                  metadataLen <= Int(dataLen) else {
                NSLog("[OMTReceiver] Invalid OMT header, resynchronizing TCP stream")
                receiveBuffer.removeFirst()
                continue
            }

            let totalFrameLength = 16 + Int(dataLen)
            if receiveBuffer.count < totalFrameLength {
                break
            }

            // DataLength includes optional per-frame XML metadata at the end.
            // Do not pass those XML bytes to the VMX decoder.
            if frameType == OMTFrameType.video.rawValue {
                let videoEnd = totalFrameLength - metadataLen
                if videoEnd >= 16 + 32 {
                    let payload = receiveBuffer.subdata(in: 16..<videoEnd)
                    handleVideoPayload(payload)
                } else {
                    framesDropped += 1
                }
            } else if frameType == OMTFrameType.metadata.rawValue {
                let payload = receiveBuffer.subdata(in: 16..<totalFrameLength)
                handleMetadataPayload(payload)
            }
            receiveBuffer.removeSubrange(0..<totalFrameLength)
        }
        
        updateStatsIfNeeded()
    }
    
    // MARK: - Video Parsing & VMX1 Decoding
    
    private func handleVideoPayload(_ payload: Data) {
        framesReceived += 1
        
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
        
        // Do not queue unlimited full-resolution frames when VMX decoding
        // cannot keep up with the incoming TCP stream.
        decodeGate.lock()
        guard !decodePending else {
            decodeGate.unlock()
            framesDropped += 1
            return
        }
        decodePending = true
        decodeGate.unlock()

        decodeQueue.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.decodeGate.lock()
                self.decodePending = false
                self.decodeGate.unlock()
            }
            guard self.isRunning else { return }

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
    
    func getStatsDict() -> [String: Any] {
        return [
            "isReceiver": true,
            "sourceName": sourceName,
            "actualWidth": actualWidth,
            "actualHeight": actualHeight,
            "codec": codecName,
            "fps": String(format: "%.1f", currentFps),
            "bitrateKbps": Int(currentBitrateKbps),
            "framesDecoded": framesDecoded,
            "framesReceived": framesReceived,
            "framesDropped": framesDropped,
            "bytesReceived": bytesReceived,
            "state": isRunning ? "receiving" : "idle"
        ]
    }
}
