import Foundation
import Network
import UIKit

/// Manages TCP connections to OMT receivers (e.g., vMix 29).
/// Implements full OMT 1.0 protocol specification:
/// - TCP stream defragmentation with 16-byte OMT header parsing
/// - Subscription state tracking per connected client (<OMTSubscribe Video="true" />)
/// - Backpressure handling: drops frames when a client network queue is saturated
/// - Codec integration: uses VMX1 via OMTVideoEncoder with transparent UYVY fallback
/// - Accurate network byte tracking via completion callbacks
/// - Bonjour DNS-SD advertisement as `_omt._tcp`
@available(iOS 13.0, *)
class OMTSender {
    
    // MARK: - Types
    
    enum OMTSenderState: String {
        case idle         // Listener not started
        case listening    // Port open, waiting for vMix 29 to connect
        case connected    // vMix 29 connected, awaiting <OMTSubscribe Video="true" />
        case transmitting // vMix 29 subscribed and actively receiving video
        case error        // Listener or socket failure
    }
    
    class ClientSession {
        let id: ObjectIdentifier
        let connection: NWConnection
        let remoteEndpoint: String
        
        var isSubscribedToVideo: Bool = false
        var isSubscribedToAudio: Bool = false
        var isSubscribedToMetadata: Bool = false
        var wantsPreview: Bool = false
        var suggestedQuality: String = "Default"
        
        /// Backpressure flag: true when an asynchronous send is currently in flight
        var isSending: Bool = false
        var incomingBuffer = Data()
        var framesSent: Int64 = 0
        var framesDropped: Int64 = 0
        var bytesSent: Int64 = 0
        
        init(connection: NWConnection) {
            self.id = ObjectIdentifier(connection)
            self.connection = connection
            self.remoteEndpoint = "\(connection.endpoint)"
        }
    }
    
    // MARK: - Configuration
    
    let sourceName: String
    let port: NWEndpoint.Port
    let width: Int32
    let height: Int32
    let frameRateN: Int32
    let frameRateD: Int32
    
    // MARK: - Callbacks
    
    var onStateChanged: ((OMTSenderState) -> Void)?
    var onError: ((String) -> Void)?
    var onConnectionCountChanged: ((Int) -> Void)?
    var onSubscribedCountChanged: ((Int) -> Void)?
    var onBytesSent: ((Int64) -> Void)?
    
    // MARK: - State
    
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: ClientSession] = [:]
    private let queue = DispatchQueue(label: "com.antigravity.omt.sender",
                                      qos: .userInteractive)
    private var netServicePublisher: NetServicePublisher?
    private var videoEncoder: OMTVideoEncoder?
    
    private(set) var state: OMTSenderState = .idle
    private(set) var framesSentTotal: Int64 = 0
    private(set) var framesDroppedTotal: Int64 = 0
    private(set) var bytesSentTotal: Int64 = 0
    
    var activeConnectionCount: Int {
        return sessions.count
    }
    
    var subscribedConnectionCount: Int {
        return sessions.values.filter { $0.isSubscribedToVideo }.count
    }
    
    var isUsingVMX1: Bool {
        return videoEncoder?.isVMX1Active ?? false
    }
    
    // MARK: - Init
    
    init(sourceName: String,
         port: Int = 7788,
         width: Int32,
         height: Int32,
         frameRateN: Int32,
         frameRateD: Int32) {
        self.sourceName = sourceName
        self.port = NWEndpoint.Port(integerLiteral: UInt16(port))
        self.width = width
        self.height = height
        self.frameRateN = frameRateN
        self.frameRateD = frameRateD
        
        // Initialize video encoder (VMX1 native with UYVY fallback)
        self.videoEncoder = OMTVideoEncoder(
            width: width,
            height: height,
            frameRateN: frameRateN,
            frameRateD: frameRateD
        )
    }
    
    // MARK: - Public API
    
    /// Start the TCP listener and advertise via Bonjour
    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            
            let listener = try NWListener(using: params, on: port)
            self.listener = listener
            
            listener.stateUpdateHandler = { [weak self] newState in
                self?.handleListenerState(newState)
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async {
                    self?.handleNewConnection(connection)
                }
            }
            
            listener.start(queue: queue)
            NSLog("[OMTSender] Listener starting on port %d", port.rawValue)
            
        } catch {
            NSLog("[OMTSender] Failed to create listener: %@", error.localizedDescription)
            updateState(.error)
            onError?("Failed to start OMT sender: \(error.localizedDescription)")
        }
    }
    
    /// Stop the listener and all client connections
    func stop() {
        listener?.cancel()
        listener = nil
        
        for (_, session) in sessions {
            session.connection.cancel()
        }
        sessions.removeAll()
        
        netServicePublisher?.stop()
        netServicePublisher = nil
        
        videoEncoder?.destroy()
        videoEncoder = nil
        
        updateState(.idle)
        NSLog("[OMTSender] Stopped")
    }
    
    /// Send a video frame to all subscribed receivers (vMix 29).
    /// Does NOT send to connections that have not subscribed yet.
    func sendVideoFrame(pixelData: Data) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            let subscribedSessions = self.sessions.values.filter { $0.isSubscribedToVideo }
            guard !subscribedSessions.isEmpty else {
                // No client is subscribed to video yet — do not burn CPU encoding
                return
            }
            
            // Encode frame using VMX1 (or fallback UYVY)
            guard let encoder = self.videoEncoder else { return }
            let encoded = encoder.encode(uyvyData: pixelData)
            
            // Build binary OMT Video Frame
            let frameData = OMTFrameBuilder.buildVideoFrame(
                payloadData: encoded.data,
                codec: encoded.codec,
                width: self.width,
                height: self.height,
                frameRateN: self.frameRateN,
                frameRateD: self.frameRateD,
                flags: OMTVideoFlags.none,
                colorSpace: OMTColorSpace.bt709
            )
            
            let frameByteCount = Int64(frameData.count)
            
            for session in subscribedSessions {
                // Backpressure check: if previous frame send is still in flight, drop this frame
                if session.isSending {
                    session.framesDropped += 1
                    self.framesDroppedTotal += 1
                    continue
                }
                
                session.isSending = true
                session.framesSent += 1
                self.framesSentTotal += 1
                
                session.connection.send(content: frameData, completion: .contentProcessed { [weak self, weak session] error in
                    guard let self = self, let session = session else { return }
                    self.queue.async {
                        session.isSending = false
                        if let error = error {
                            NSLog("[OMTSender] Connection send error for %@: %@",
                                  session.remoteEndpoint, error.localizedDescription)
                            self.removeSession(id: session.id)
                        } else {
                            session.bytesSent += frameByteCount
                            self.bytesSentTotal += frameByteCount
                            self.onBytesSent?(frameByteCount)
                        }
                    }
                })
            }
        }
    }
    
    // MARK: - Private Connection Management
    
    private func handleListenerState(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            NSLog("[OMTSender] Listening on port %d", port.rawValue)
            updateState(.listening)
            startBonjourAdvertisement()
            
        case .failed(let error):
            NSLog("[OMTSender] Listener failed: %@", error.localizedDescription)
            updateState(.error)
            onError?("Listener failed: \(error.localizedDescription)")
            
        case .cancelled:
            NSLog("[OMTSender] Listener cancelled")
            
        default:
            break
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        let session = ClientSession(connection: connection)
        let id = session.id
        
        connection.stateUpdateHandler = { [weak self, weak session] newState in
            guard let self = self, let session = session else { return }
            switch newState {
            case .ready:
                NSLog("[OMTSender] Receiver connected from %@", session.remoteEndpoint)
                self.queue.async {
                    self.sessions[id] = session
                    self.onConnectionCountChanged?(self.sessions.count)
                    self.updateSenderState()
                    // Send official OMT source identity metadata (<OMTInfo ... />)
                    self.sendIdentityMetadata(to: session)
                }
                
            case .failed(let error):
                NSLog("[OMTSender] Connection failed for %@: %@", session.remoteEndpoint, error.localizedDescription)
                self.queue.async {
                    self.removeSession(id: id)
                }
                
            case .cancelled:
                self.queue.async {
                    self.removeSession(id: id)
                }
                
            default:
                break
            }
        }
        
        connection.start(queue: queue)
        receiveLoop(session: session)
    }
    
    private func sendIdentityMetadata(to session: ClientSession) {
        let xml = OMTFrameBuilder.buildSenderIdentityXML(
            productName: "MIMO_NDI",
            manufacturer: "MIMO",
            version: "1.0"
        )
        let metadataFrame = OMTFrameBuilder.buildMetadataFrame(xmlString: xml)
        session.connection.send(content: metadataFrame, completion: .contentProcessed { [weak self] error in
            if let error = error {
                NSLog("[OMTSender] Error sending identity metadata: %@", error.localizedDescription)
            } else {
                NSLog("[OMTSender] Sent <OMTInfo> identity metadata to %@", session.remoteEndpoint)
                self?.bytesSentTotal += Int64(metadataFrame.count)
            }
        })
    }
    
    // MARK: - Frame Defragmentation & Command Parsing
    
    private func receiveLoop(session: ClientSession) {
        session.connection.receive(minimumIncompleteLength: 1,
                                   maximumLength: 65536) { [weak self, weak session] data, _, isComplete, error in
            guard let self = self, let session = session else { return }
            
            if let error = error {
                NSLog("[OMTSender] Receive error from %@: %@", session.remoteEndpoint, error.localizedDescription)
                self.queue.async { self.removeSession(id: session.id) }
                return
            }
            if isComplete {
                NSLog("[OMTSender] Receiver %@ closed connection", session.remoteEndpoint)
                self.queue.async { self.removeSession(id: session.id) }
                return
            }
            
            if let data = data, !data.isEmpty {
                self.queue.async {
                    session.incomingBuffer.append(data)
                    self.parseIncomingFrames(session: session)
                }
            }
            
            // Continue receive loop
            self.receiveLoop(session: session)
        }
    }
    
    private func parseIncomingFrames(session: ClientSession) {
        while session.incomingBuffer.count >= 16 {
            let version = session.incomingBuffer[0]
            guard version == 1 else {
                NSLog("[OMTSender] Protocol error: invalid version %d from %@", version, session.remoteEndpoint)
                removeSession(id: session.id)
                return
            }
            
            let frameType = session.incomingBuffer[1]
            let dataLength = session.incomingBuffer.readLEInt32(offset: 12)
            
            guard dataLength >= 0 && dataLength <= 10_485_760 else {
                NSLog("[OMTSender] Protocol error: invalid DataLength %d from %@", dataLength, session.remoteEndpoint)
                removeSession(id: session.id)
                return
            }
            
            let totalFrameBytes = 16 + Int(dataLength)
            if session.incomingBuffer.count < totalFrameBytes {
                // Waiting for remaining bytes of the frame to arrive
                break
            }
            
            // Full frame received — extract payload
            let payload = session.incomingBuffer.subdata(in: 16..<totalFrameBytes)
            session.incomingBuffer.removeSubrange(0..<totalFrameBytes)
            
            if frameType == OMTFrameType.metadata.rawValue {
                handleMetadataPayload(payload, session: session)
            }
        }
    }
    
    private func handleMetadataPayload(_ payload: Data, session: ClientSession) {
        var cleanData = payload
        // Strip null terminator if present
        if cleanData.last == 0 {
            cleanData.removeLast()
        }
        
        guard let xmlString = String(data: cleanData, encoding: .utf8) else {
            NSLog("[OMTSender] Received non-UTF8 metadata payload from %@", session.remoteEndpoint)
            return
        }
        
        let cmd = OMTFrameBuilder.parseCommand(from: xmlString)
        NSLog("[OMTSender] Received command from %@: %@", session.remoteEndpoint, xmlString)
        
        switch cmd {
        case .subscribeVideo(let subscribed):
            session.isSubscribedToVideo = subscribed
            NSLog("[OMTSender] %@ Video subscription -> %@", session.remoteEndpoint, subscribed ? "SUBSCRIBED" : "UNSUBSCRIBED")
            updateSenderState()
            onSubscribedCountChanged?(subscribedConnectionCount)
            
        case .subscribeAudio(let subscribed):
            session.isSubscribedToAudio = subscribed
            NSLog("[OMTSender] %@ Audio subscription -> %@", session.remoteEndpoint, subscribed ? "SUBSCRIBED" : "UNSUBSCRIBED")
            
        case .subscribeMetadata(let subscribed):
            session.isSubscribedToMetadata = subscribed
            
        case .setPreview(let preview):
            session.wantsPreview = preview
            NSLog("[OMTSender] %@ Preview mode -> %@", session.remoteEndpoint, preview ? "ON" : "OFF")
            
        case .setQuality(let quality):
            session.suggestedQuality = quality
            NSLog("[OMTSender] %@ Suggested quality -> %@", session.remoteEndpoint, quality)
            
        case .tally(let preview, let program):
            NSLog("[OMTSender] %@ Tally: preview=%@ program=%@",
                  session.remoteEndpoint, preview ? "true" : "false", program ? "true" : "false")
            
        case .unknown(let raw):
            NSLog("[OMTSender] Unhandled metadata XML: %@", raw)
        }
    }
    
    private func removeSession(id: ObjectIdentifier) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.connection.cancel()
        NSLog("[OMTSender] Removed connection %@. Remaining: %d", session.remoteEndpoint, sessions.count)
        
        onConnectionCountChanged?(sessions.count)
        onSubscribedCountChanged?(subscribedConnectionCount)
        updateSenderState()
    }
    
    private func updateSenderState() {
        if listener == nil {
            updateState(.idle)
        } else if subscribedConnectionCount > 0 {
            updateState(.transmitting)
        } else if !sessions.isEmpty {
            updateState(.connected)
        } else {
            updateState(.listening)
        }
    }
    
    private func updateState(_ newState: OMTSenderState) {
        if state != newState {
            state = newState
            onStateChanged?(newState)
            NSLog("[OMTSender] State changed -> %@", newState.rawValue)
        }
    }
    
    // MARK: - Bonjour Advertisement
    
    private func startBonjourAdvertisement() {
        // vMix 29 OMT discovery naming convention: "DeviceName (SourceName)"
        let deviceName = UIDevice.current.name
        let advertisedName = "\(deviceName) (\(sourceName))"
        
        netServicePublisher = NetServicePublisher(
            name: advertisedName,
            port: Int32(port.rawValue)
        )
        netServicePublisher?.start()
        NSLog("[OMTSender] Bonjour advertisement registered for '%@'", advertisedName)
    }
}

// MARK: - Safe Data Reading (Awaits unaligned memory hazards)

extension Data {
    func readLEInt32(offset: Int) -> Int32 {
        guard offset + 4 <= count else { return 0 }
        var value: Int32 = 0
        Swift.withUnsafeMutableBytes(of: &value) { ptr in
            _ = self.copyBytes(to: ptr, from: offset..<(offset + 4))
        }
        return Int32(littleEndian: value)
    }
    
    func readLEUInt16(offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        var value: UInt16 = 0
        Swift.withUnsafeMutableBytes(of: &value) { ptr in
            _ = self.copyBytes(to: ptr, from: offset..<(offset + 2))
        }
        return UInt16(littleEndian: value)
    }
    
    func readLEInt64(offset: Int) -> Int64 {
        guard offset + 8 <= count else { return 0 }
        var value: Int64 = 0
        Swift.withUnsafeMutableBytes(of: &value) { ptr in
            _ = self.copyBytes(to: ptr, from: offset..<(offset + 8))
        }
        return Int64(littleEndian: value)
    }
}

// MARK: - NetServicePublisher

/// Publishes an OMT service via Bonjour DNS-SD (_omt._tcp)
/// so that vMix 29 discovers this iPhone on the local network.
class NetServicePublisher: NSObject, NetServiceDelegate {
    private var service: NetService?
    private let name: String
    private let port: Int32
    
    init(name: String, port: Int32) {
        self.name = name
        self.port = port
    }
    
    func start() {
        let service = NetService(domain: "local.",
                                 type: "_omt._tcp.",
                                 name: name,
                                 port: port)
        service.delegate = self
        service.publish()
        self.service = service
    }
    
    func stop() {
        service?.stop()
        service = nil
    }
    
    func netServiceDidPublish(_ sender: NetService) {
        NSLog("[Bonjour] OMT service published: %@ on port %d", sender.name, sender.port)
    }
    
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        NSLog("[Bonjour] OMT service failed to publish: %@", errorDict.description)
    }
}
