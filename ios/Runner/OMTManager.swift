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
///                             ←→  OMTTestPattern  ←→  SMPTE Color Bars
@available(iOS 13.0, *)
@objc class OMTManager: NSObject {
    
    // MARK: - Channels
    
    static let channelName = "com.antigravity/omt"
    static let eventChannelName = "com.antigravity/omt_events"
    
    // MARK: - State
    
    enum State: String {
        case idle = "idle"
        case discovering = "discovering"
        case listening = "listening"        // Port open, published via Bonjour, 0 clients
        case connected = "connected"        // vMix 29 connected, waiting for subscription
        case connecting = "connecting"
        case transmitting = "transmitting"  // vMix 29 subscribed and actively streaming
        case receiving = "receiving"
        case disconnecting = "disconnecting"
        case error = "error"
    }
    
    // MARK: - Components
    
    private var sender: OMTSender?
    private var receiver: OMTReceiver?
    private var videoCapture: OMTVideoCapture?
    private let discovery = OMTDiscovery()
    
    // MARK: - Test Pattern State
    
    private var isTestPatternActive: Bool = false
    private var testPatternTimer: DispatchSourceTimer?
    private var testPatternFrameIndex: Int64 = 0
    private let testPatternQueue = DispatchQueue(label: "com.antigravity.omt.testpattern",
                                                 qos: .userInteractive)
    
    // MARK: - Flutter event sink
    
    private var eventSink: FlutterEventSink?
    
    // MARK: - Stats
    
    private var currentState: State = .idle
    private var lastBitrateCalcTime: Date = Date()
    private var bytesSinceLastCalc: Int64 = 0
    private var currentBitrateKbps: Double = 0
    private var statsTimer: Timer?
    private var diagnosticLines: [String] = []
    private let diagnosticLock = NSLock()

    private func recordDiagnostic(_ message: String) {
        diagnosticLock.lock()
        diagnosticLines.append("\(Date()): \(message)")
        if diagnosticLines.count > 200 { diagnosticLines.removeFirst(diagnosticLines.count - 200) }
        diagnosticLock.unlock()
    }

    private func diagnosticText() -> String {
        diagnosticLock.lock()
        defer { diagnosticLock.unlock() }
        return diagnosticLines.joined(separator: "\n")
    }
    
    /// Exposed for PlatformView camera preview
    var activeCaptureSession: AVCaptureSession? {
        return videoCapture?.session
    }
    
    // MARK: - Singleton
    
    @objc static let shared = OMTManager()
    
    private override init() {
        super.init()
        setupDiscovery()
    }
    
    // MARK: - Registration
    
    /// Called from AppDelegate to register the MethodChannel and EventChannel
    func register(with registrar: FlutterPluginRegistrar) {
        // Registered from AppDelegate directly
    }
    
    // MARK: - Method Channel Handler
    
    /// Handle method calls from Flutter
    func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
            
        case "startSending":
            handleStartSending(call: call, result: result)
            
        case "stopSending":
            handleStopSending(result: result)
            
        case "startCameraPreview":
            handleStartCameraPreview(call: call, result: result)
            
        case "stopCameraPreview":
            handleStopCameraPreview(result: result)
            
        case "setTestPattern":
            handleSetTestPattern(call: call, result: result)
            
        case "switchCamera":
            handleSwitchCamera(call: call, result: result)
            
        case "startDiscovery":
            handleStartDiscovery(result: result)
            
        case "stopDiscovery":
            handleStopDiscovery(result: result)
            
        case "getSources":
            handleGetSources(result: result)
            
        case "connectToSource":
            handleConnectToSource(call: call, result: result)
            
        case "disconnect":
            handleDisconnect(result: result)
            
        case "getState":
            result(currentState.rawValue)
            
        case "getStats":
            result(buildStatsDict())

        case "getDiagnosticLogs":
            result(diagnosticText())
            
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
        
        let sourceName = args["sourceName"] as? String ?? "MIMO Camera"
        let width = Int32(args["width"] as? Int ?? 1920)
        let height = Int32(args["height"] as? Int ?? 1080)
        let frameRateN = Int32(args["frameRateN"] as? Int ?? 30000)
        let frameRateD = Int32(args["frameRateD"] as? Int ?? 1001)
        let useFrontCamera = args["useFrontCamera"] as? Bool ?? false
        
        // Stop any existing sending
        stopAllSending()
        
        setState(.listening)
        
        // Create and start sender (TCP server waiting for receiver connections)
        let requestedPort = args["port"] as? Int ?? 6400
        let newSender = OMTSender(
            sourceName: sourceName,
            port: requestedPort,
            width: width,
            height: height,
            frameRateN: frameRateN,
            frameRateD: frameRateD
        )
        
        newSender.onStateChanged = { [weak self] senderState in
            guard let self = self else { return }
            switch senderState {
            case .idle:
                self.setState(.idle)
            case .listening:
                self.setState(.listening)
            case .connected:
                self.setState(.connected)
            case .transmitting:
                self.setState(.transmitting)
            case .error:
                self.setState(.error)
            }
        }
        
        newSender.onError = { [weak self] errorMsg in
            self?.sendEvent(["type": "error", "message": errorMsg])
            self?.setState(.error)
        }
        
        recordDiagnostic("Start OMT sender: \(sourceName), requested port \(requestedPort)")
        newSender.onDiagnostic = { [weak self] message in
            self?.recordDiagnostic(message)
        }

        newSender.onConnectionCountChanged = { [weak self] count in
            NSLog("[OMTManager] Connected receivers: %d", count)
            self?.recordDiagnostic("Connection count: \(count)")
            self?.sendStatsUpdate()
        }
        
        newSender.onSubscribedCountChanged = { [weak self] count in
            NSLog("[OMTManager] Subscribed receivers: %d", count)
            self?.sendStatsUpdate()
        }
        
        newSender.onBytesSent = { [weak self] bytes in
            self?.updateBitrateStats(bytes: bytes)
        }
        
        newSender.start()
        self.sender = newSender
        
        // Start camera capture (or reuse running preview capture)
        if let existingCapture = self.videoCapture, existingCapture.isRunning {
            existingCapture.onFrame = { [weak self, weak newSender] pixelData, actualW, actualH in
                guard let self = self, let sender = newSender else { return }
                if !self.isTestPatternActive {
                    sender.sendVideoFrame(pixelData: pixelData, width: actualW, height: actualH)
                }
            }
        } else {
            let captureConfig = OMTVideoCapture.Config(
                width: Int(width),
                height: Int(height),
                frameRateN: frameRateN,
                frameRateD: frameRateD,
                useFrontCamera: useFrontCamera
            )
            let capture = OMTVideoCapture()
            capture.onFrame = { [weak self, weak newSender] pixelData, actualW, actualH in
                guard let self = self, let sender = newSender else { return }
                if !self.isTestPatternActive {
                    sender.sendVideoFrame(pixelData: pixelData, width: actualW, height: actualH)
                }
            }
            capture.onError = { [weak self] errorMsg in
                self?.sendEvent(["type": "error", "message": "Camera: \(errorMsg)"])
            }
            capture.startCapture(config: captureConfig)
            self.videoCapture = capture
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(name: NSNotification.Name("OMTCameraSessionReady"), object: nil)
            }
        }
        
        // Start stats timer
        startStatsTimer()
        
        NSLog("[OMTManager] Started OMT service '%@' (%dx%d)", sourceName, width, height)
        result(true)
    }
    
    private func handleStopSending(result: @escaping FlutterResult) {
        setState(.disconnecting)
        // Stop sender network pipeline, keep camera preview running smoothly
        statsTimer?.invalidate()
        statsTimer = nil
        stopTestPatternGenerator()
        isTestPatternActive = false
        testPatternFrameIndex = 0
        sender?.stop()
        sender = nil
        bytesSinceLastCalc = 0
        currentBitrateKbps = 0
        setState(.idle)
        result(nil)
    }
    
    private func handleStartCameraPreview(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let width = Int(args?["width"] as? Int ?? 1920)
        let height = Int(args?["height"] as? Int ?? 1080)
        let frameRateN = Int32(args?["frameRateN"] as? Int ?? 30000)
        let frameRateD = Int32(args?["frameRateD"] as? Int ?? 1001)
        let useFrontCamera = args?["useFrontCamera"] as? Bool ?? false
        
        if let existing = self.videoCapture, existing.isRunning {
            NotificationCenter.default.post(name: NSNotification.Name("OMTCameraSessionReady"), object: nil)
            result(true)
            return
        }
        
        let config = OMTVideoCapture.Config(
            width: width,
            height: height,
            frameRateN: frameRateN,
            frameRateD: frameRateD,
            useFrontCamera: useFrontCamera
        )
        
        let capture = OMTVideoCapture()
        capture.onFrame = { [weak self] pixelData, actualW, actualH in
            guard let self = self, let sender = self.sender else { return }
            if !self.isTestPatternActive {
                sender.sendVideoFrame(pixelData: pixelData, width: actualW, height: actualH)
            }
        }
        capture.onError = { [weak self] errorMsg in
            self?.sendEvent(["type": "error", "message": "Camera: \(errorMsg)"])
        }
        capture.startCapture(config: config)
        self.videoCapture = capture
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: NSNotification.Name("OMTCameraSessionReady"), object: nil)
        }
        
        result(true)
    }
    
    private func handleStopCameraPreview(result: @escaping FlutterResult) {
        // Only stop camera capture if not actively transmitting
        if sender == nil {
            videoCapture?.stopCapture()
            videoCapture = nil
        }
        result(true)
    }
    
    private func handleSetTestPattern(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let enabled = args["enabled"] as? Bool else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing enabled parameter", details: nil))
            return
        }
        
        isTestPatternActive = enabled
        
        if enabled {
            startTestPatternGenerator()
            NSLog("[OMTManager] Test pattern ENABLED (SMPTE Color Bars)")
        } else {
            stopTestPatternGenerator()
            NSLog("[OMTManager] Test pattern DISABLED (Camera Feed)")
        }
        
        sendStatsUpdate()
        result(true)
    }
    
    private func startTestPatternGenerator() {
        stopTestPatternGenerator()
        
        let timer = DispatchSource.makeTimerSource(queue: testPatternQueue)
        // 30 FPS = 33,333 microseconds interval
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self = self, let sender = self.sender, self.isTestPatternActive else { return }
            self.testPatternFrameIndex += 1
            
            let w = sender.currentWidth > 0 ? sender.currentWidth : 1920
            let h = sender.currentHeight > 0 ? sender.currentHeight : 1080
            
            let patternUYVY = OMTTestPattern.generateUYVYFrame(
                width: Int(w),
                height: Int(h),
                frameIndex: self.testPatternFrameIndex
            )
            
            sender.sendVideoFrame(pixelData: patternUYVY, width: w, height: h)
        }
        timer.resume()
        self.testPatternTimer = timer
    }
    
    private func stopTestPatternGenerator() {
        testPatternTimer?.cancel()
        testPatternTimer = nil
    }
    
    private func handleSwitchCamera(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing arguments", details: nil))
            return
        }
        let useFront = args["useFrontCamera"] as? Bool ?? false
        videoCapture?.switchCamera(useFront: useFront)
        result(true)
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
    
    private func handleConnectToSource(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let host = args["host"] as? String,
              let port = args["port"] as? Int else {
            result(FlutterError(code: "INVALID_ARGS", message: "Host and port required", details: nil))
            return
        }
        let sourceName = args["name"] as? String ?? "\(host):\(port)"
        
        setState(.connecting)
        
        // Stop any active transmission
        if sender != nil {
            handleStopSending { _ in }
        }
        
        receiver?.stop()
        let newReceiver = OMTReceiver(host: host, port: UInt16(port), sourceName: sourceName)
        newReceiver.onStateChanged = { [weak self] state in
            self?.setState(state)
        }
        newReceiver.onError = { [weak self] err in
            self?.sendEvent(["type": "error", "message": "OMT Réception: \(err)"])
        }
        newReceiver.onStatsUpdated = { [weak self] stats in
            var fullStats = stats
            fullStats["type"] = "stats"
            self?.sendEvent(fullStats)
        }
        self.receiver = newReceiver
        newReceiver.start()
        result(true)
    }
    
    private func handleDisconnect(result: @escaping FlutterResult) {
        if let rec = receiver {
            rec.stop()
            receiver = nil
            setState(.idle)
            result(true)
            return
        }
        stopAllSending()
        setState(.idle)
        result(true)
    }
    
    // MARK: - Helpers
    
    private func stopAllSending() {
        statsTimer?.invalidate()
        statsTimer = nil
        
        stopTestPatternGenerator()
        isTestPatternActive = false
        testPatternFrameIndex = 0
        
        videoCapture?.stopCapture()
        videoCapture = nil
        
        sender?.stop()
        sender = nil
        
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
    
    private func sendStatsUpdate() {
        sendEvent(buildStatsDict())
    }
    
    private func buildStatsDict() -> [String: Any] {
        if let rec = receiver {
            var stats = rec.getStatsDict()
            stats["type"] = "stats"
            return stats
        }
        
        let fps = videoCapture?.measuredFPS ?? 0
        let connections = sender?.activeConnectionCount ?? 0
        let subscribed = sender?.subscribedConnectionCount ?? 0
        let framesSent = sender?.framesSentTotal ?? 0
        let framesDropped = sender?.framesDroppedTotal ?? 0
        let framesEncoded = sender?.encodedFramesTotal ?? 0
        let isVMX = sender?.isUsingVMX1 ?? false
        let codecName = isVMX ? "VMX1 (vMix 29 Native)" : "UYVY (4:2:2 Raw)"
        let actualW = sender?.currentWidth ?? 1920
        let actualH = sender?.currentHeight ?? 1080
        let encoderErr = sender?.encoderLastError ?? "OK"
        
        var dict: [String: Any] = [
            "type": "stats",
            "fps": String(format: "%.1f", fps),
            "actualWidth": actualW,
            "actualHeight": actualH,
            "bitrateKbps": Int(currentBitrateKbps),
            "framesSent": framesSent,
            "framesDropped": framesDropped,
            "framesEncoded": framesEncoded,
            "activeConnections": connections,
            "subscribedConnections": subscribed,
            "codec": codecName,
            "isVMX1": isVMX,
            "encoderError": encoderErr,
            "testPatternActive": isTestPatternActive,
            "state": currentState.rawValue,
            "port": Int(sender?.port.rawValue ?? 6400)
        ]
        if let ip = NetServicePublisher.getLocalIPv4Address() {
            dict["localIP"] = ip
        }
        return dict
    }
    
    private func updateBitrateStats(bytes: Int64) {
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
            if self.currentState == .transmitting || self.currentState == .listening || self.currentState == .connected || self.currentState == .receiving {
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
