import Foundation
import Network

/// Manages TCP connections to OMT receivers (e.g., vMix 29).
/// Each connecting client gets a separate NWConnection.
/// This class acts as an OMT sender — it listens for incoming receiver connections
/// on a local TCP port and pushes frames to all connected receivers.
///
/// OMT senders advertise themselves via DNS-SD; receivers connect to them.
/// vMix 29 discovers the sender via Bonjour and then connects via TCP.
class OMTSender {
    
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
    
    // MARK: - State
    
    enum OMTSenderState {
        case idle, listening, hasConnections, error
    }
    
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.antigravity.omt.sender",
                                      qos: .userInteractive)
    private var netServicePublisher: NetServicePublisher?
    
    private(set) var state: OMTSenderState = .idle
    private(set) var framesSent: Int64 = 0
    private(set) var bytesSent: Int64 = 0
    
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
    }
    
    // MARK: - Public API
    
    /// Start the TCP listener and advertise via Bonjour
    func start() {
        do {
            let params = NWParameters.tcp
            // Allow reusing port
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
            onError?("Failed to start OMT sender: \(error.localizedDescription)")
        }
    }
    
    /// Stop the listener and all connections
    func stop() {
        listener?.cancel()
        listener = nil
        
        for (_, conn) in connections {
            conn.cancel()
        }
        connections.removeAll()
        
        netServicePublisher?.stop()
        netServicePublisher = nil
        
        state = .idle
        onStateChanged?(.idle)
        NSLog("[OMTSender] Stopped")
    }
    
    /// Send a video frame to all connected receivers
    func sendVideoFrame(pixelData: Data) {
        guard !connections.isEmpty else { return }
        
        let frame = OMTFrameBuilder.buildVideoFrame(
            pixelData: pixelData,
            width: width,
            height: height,
            frameRateN: frameRateN,
            frameRateD: frameRateD
        )
        
        broadcastFrame(frame)
    }
    
    /// Send raw pre-built OMT frame data to all connected receivers
    func broadcastFrame(_ frameData: Data) {
        guard !connections.isEmpty else { return }
        
        framesSent += 1
        bytesSent += Int64(frameData.count)
        
        for (id, conn) in connections {
            conn.send(content: frameData,
                      completion: .contentProcessed { [weak self] error in
                if let error = error {
                    NSLog("[OMTSender] Send error on connection: %@",
                          error.localizedDescription)
                    self?.queue.async {
                        self?.removeConnection(id: id)
                    }
                }
            })
        }
    }
    
    var activeConnectionCount: Int {
        return connections.count
    }
    
    // MARK: - Private
    
    private func handleListenerState(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            NSLog("[OMTSender] Listening on port %d", port.rawValue)
            state = .listening
            onStateChanged?(.listening)
            // Start Bonjour advertisement
            startBonjourAdvertisement()
            
        case .failed(let error):
            NSLog("[OMTSender] Listener failed: %@", error.localizedDescription)
            state = .error
            onStateChanged?(.error)
            onError?("Listener failed: \(error.localizedDescription)")
            
        case .cancelled:
            NSLog("[OMTSender] Listener cancelled")
            
        default:
            break
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready:
                NSLog("[OMTSender] New receiver connected")
                self?.queue.async {
                    self?.connections[id] = connection
                    self?.onConnectionCountChanged?(self?.connections.count ?? 0)
                    self?.state = .hasConnections
                    self?.onStateChanged?(.hasConnections)
                    // Send identity metadata frame
                    self?.sendIdentityMetadata(to: connection)
                }
                
            case .failed(let error):
                NSLog("[OMTSender] Connection failed: %@", error.localizedDescription)
                self?.queue.async {
                    self?.removeConnection(id: id)
                }
                
            case .cancelled:
                self?.queue.async {
                    self?.removeConnection(id: id)
                }
                
            default:
                break
            }
        }
        
        connection.start(queue: queue)
        
        // Start receiving (to detect disconnections)
        receiveLoop(connection: connection, id: id)
    }
    
    private func sendIdentityMetadata(to connection: NWConnection) {
        let xml = OMTFrameBuilder.buildSenderIdentityXML(
            sourceName: sourceName,
            width: width,
            height: height,
            frameRateN: frameRateN,
            frameRateD: frameRateD
        )
        let metadataFrame = OMTFrameBuilder.buildMetadataFrame(xmlString: xml)
        connection.send(content: metadataFrame, completion: .idempotent)
        NSLog("[OMTSender] Sent identity metadata to receiver")
    }
    
    private func receiveLoop(connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: 4096) { [weak self] data, _, isComplete, error in
            if let error = error {
                NSLog("[OMTSender] Receive error: %@", error.localizedDescription)
                self?.queue.async {
                    self?.removeConnection(id: id)
                }
                return
            }
            if isComplete {
                self?.queue.async {
                    self?.removeConnection(id: id)
                }
                return
            }
            // Continue receiving
            self?.receiveLoop(connection: connection, id: id)
        }
    }
    
    private func removeConnection(id: ObjectIdentifier) {
        connections[id]?.cancel()
        connections.removeValue(forKey: id)
        onConnectionCountChanged?(connections.count)
        
        if connections.isEmpty && state == .hasConnections {
            state = .listening
            onStateChanged?(.listening)
        }
        NSLog("[OMTSender] Connection removed. Active: %d", connections.count)
    }
    
    // MARK: - Bonjour Advertisement
    
    private func startBonjourAdvertisement() {
        netServicePublisher = NetServicePublisher(
            name: sourceName,
            port: Int32(port.rawValue)
        )
        netServicePublisher?.start()
        NSLog("[OMTSender] Bonjour advertisement started for '%@'", sourceName)
    }
}

// MARK: - NetServicePublisher

/// Publishes an OMT service via Bonjour DNS-SD (_omt._tcp)
/// so that vMix 29 and other OMT receivers can discover this device.
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
        NSLog("[Bonjour] Service published: %@ on port %d", sender.name, sender.port)
    }
    
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        NSLog("[Bonjour] Failed to publish: %@", errorDict.description)
    }
}
