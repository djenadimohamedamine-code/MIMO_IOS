import Foundation
import Flutter
import AVFoundation

/// The main OMT (Open Media Transport) manager for iOS.
/// Handles the Flutter ↔ Native bridge via MethodChannel 'com.antigravity/omt'.
/// This is completely separate from NDIManager and must not interfere with it.
///
/// Architecture:
///   Flutter  ←→  OMTManager  ←→  OMTSender  ←→  vMix 29 (TCP)
///                             ←→  OMTDiscovery  ←→  Bonjour
///                             ←→  OMTVideoCapture  ←→  Camera
@available(iOS 13.0, *)
@objc class OMTManager: NSObject {
    
    // MARK: - Channels
    
    static let channelName = "com.antigravity/omt"
    static let eventChannelName = "com.antigravity/omt_events"
    
    // MARK: - State
    
    enum State: String {
        case idle = "idle"
        case discovering = "discovering"
        case connecting = "connecting"
        case transmitting = "transmitting"
        case receiving = "receiving"
        case disconnecting = "disconnecting"
        case error = "error"
    }
    
    // MARK: - Components
    
    private var sender: OMTSender?
    private var videoCapture: OMTVideoCapture?
    private let discovery = OMTDiscovery()
    
    // MARK: - Flutter event sink
    
    private var eventSink: FlutterEventSink?
    
    // MARK: - Stats
    
    private var currentState: State = .idle
    private var framesSentTotal: Int64 = 0
    private var lastBitrateCalcTime: Date = Date()
    private var bytesSinceLastCalc: Int64 = 0
    private var currentBitrateKbps: Double = 0
    private var statsTimer: Timer?
    
    // MARK: - Singleton
    
    @objc static let shared = OMTManager()
    
    private override init() {
        super.init()
        setupDiscovery()
    }
    
    // MARK: - Registration
    
    /// Called from AppDelegate to register the MethodChannel and EventChannel
    func register(with registrar: FlutterPluginRegistrar) {
        // Nothing — channel is set up from AppDelegate directly
    }
    
    // MARK: - Method Channel Handler
    
    /// Handle method calls from Flutter
    func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
            
        case "startSending":
            handleStartSending(call: call, result: result)
            
        case "stopSending":
            handleStopSending(result: result)
            
        case "startDiscovery":
            handleStartDiscovery(result: result)
            
        case "stopDiscovery":
            handleStopDiscovery(result: result)
            
        case "getSources":
            handleGetSources(result: result)
            
        case "connectToSource":
            // Reception — Phase 2 (not yet implemented)
            result(false)
            
        case "disconnect":
            handleDisconnect(result: result)
            
        case "getState":
            result(currentState.rawValue)
            
        case "getStats":
            result(buildStatsDict())
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Discovery setup
    
    private func setupDiscovery() {
        discovery.onSourcesChanged = { [weak self] sources in
            guard let self = self else { return }
            let dicts = sources.map { $0.toDict() }
            self.sendEvent(["type": "sourcesDiscovered", "sources": dicts])
        }
        
        discovery.onError = { [weak self] errorMsg in
            self?.sendEvent(["type": "error", "message": errorMsg])
        }
    }
    
    // MARK: - Handle Methods
    
    private func handleStartSending(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing arguments", details: nil))
            return
        }
        
        let sourceName = args["sourceName"] as? String ?? "MIMO_NDI Camera"
        let width = Int32(args["width"] as? Int ?? 1920)
        let height = Int32(args["height"] as? Int ?? 1080)
        let frameRateN = Int32(args["frameRateN"] as? Int ?? 30000)
        let frameRateD = Int32(args["frameRateD"] as? Int ?? 1001)
        let useFrontCamera = args["useFrontCamera"] as? Bool ?? false
        
        // Stop any existing sending
        stopAllSending()
        
        setState(.connecting)
        
        // Create and start sender (TCP server waiting for receiver connections)
        let newSender = OMTSender(
            sourceName: sourceName,
            port: 7788,
            width: width,
            height: height,
            frameRateN: frameRateN,
            frameRateD: frameRateD
        )
        
        newSender.onStateChanged = { [weak self] senderState in
            guard let self = self else { return }
            switch senderState {
            case .listening:
                // Ready and waiting for vMix to connect
                // We move to transmitting state to let UI show active state
                // even before a receiver connects (we are broadcasting-ready)
                self.setState(.transmitting)
            case .hasConnections:
                self.setState(.transmitting)
            case .error:
                self.setState(.error)
            default:
                break
            }
        }
        
        newSender.onError = { [weak self] errorMsg in
            self?.sendEvent(["type": "error", "message": errorMsg])
            self?.setState(.error)
        }
        
        newSender.onConnectionCountChanged = { [weak self] count in
            NSLog("[OMTManager] Active receivers: %d", count)
        }
        
        newSender.start()
        self.sender = newSender
        
        // Start camera capture
        let captureConfig = OMTVideoCapture.Config(
            width: Int(width),
            height: Int(height),
            frameRateN: frameRateN,
            frameRateD: frameRateD,
            useFrontCamera: useFrontCamera
        )
        
        let capture = OMTVideoCapture()
        capture.onFrame = { [weak self, weak newSender] pixelData, config in
            newSender?.sendVideoFrame(pixelData: pixelData)
            self?.updateBitrateStats(bytes: Int64(pixelData.count))
        }
        capture.onError = { [weak self] errorMsg in
            self?.sendEvent(["type": "error", "message": "Camera: \(errorMsg)"])
        }
        capture.startCapture(config: captureConfig)
        self.videoCapture = capture
        
        // Start stats timer
        startStatsTimer()
        
        NSLog("[OMTManager] Started sending '%@' at %dx%d", sourceName, width, height)
        result(true)
    }
    
    private func handleStopSending(result: @escaping FlutterResult) {
        setState(.disconnecting)
        stopAllSending()
        setState(.idle)
        result(nil)
    }
    
    private func handleStartDiscovery(result: @escaping FlutterResult) {
        setState(.discovering)
        discovery.startDiscovery()
        result(nil)
    }
    
    private func handleStopDiscovery(result: @escaping FlutterResult) {
        discovery.stopDiscovery()
        if currentState == .discovering {
            setState(.idle)
        }
        result(nil)
    }
    
    private func handleGetSources(result: @escaping FlutterResult) {
        let sources = discovery.getCurrentSources()
        let dicts = sources.map { $0.toDict() }
        result(dicts)
    }
    
    private func handleDisconnect(result: @escaping FlutterResult) {
        stopAllSending()
        setState(.idle)
        result(nil)
    }
    
    // MARK: - Helpers
    
    private func stopAllSending() {
        statsTimer?.invalidate()
        statsTimer = nil
        
        videoCapture?.stopCapture()
        videoCapture = nil
        
        sender?.stop()
        sender = nil
        
        framesSentTotal = 0
        bytesSinceLastCalc = 0
        currentBitrateKbps = 0
    }
    
    private func setState(_ newState: State) {
        currentState = newState
        sendEvent(["type": "stateChanged", "state": newState.rawValue])
        NSLog("[OMTManager] State → %@", newState.rawValue)
    }
    
    private func sendEvent(_ data: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(data)
        }
    }
    
    private func buildStatsDict() -> [String: Any] {
        let fps = videoCapture?.measuredFPS ?? 0
        let connections = sender?.activeConnectionCount ?? 0
        return [
            "type": "stats",
            "fps": String(format: "%.1f", fps),
            "bitrateKbps": Int(currentBitrateKbps),
            "framesSent": framesSentTotal,
            "activeConnections": connections,
            "codec": "UYVY (4:2:2)",
            "state": currentState.rawValue
        ]
    }
    
    private func updateBitrateStats(bytes: Int64) {
        framesSentTotal += 1
        bytesSinceLastCalc += bytes
        
        let now = Date()
        let elapsed = now.timeIntervalSince(lastBitrateCalcTime)
        if elapsed >= 1.0 {
            currentBitrateKbps = Double(bytesSinceLastCalc * 8) / elapsed / 1000.0
            bytesSinceLastCalc = 0
            lastBitrateCalcTime = now
        }
    }
    
    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.currentState == .transmitting {
                self.sendEvent(self.buildStatsDict())
            }
        }
    }
}

// MARK: - FlutterStreamHandler for EventChannel

extension OMTManager: FlutterStreamHandler {
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
