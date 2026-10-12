import Foundation
import Network
import Darwin

/// Manages DNS-SD Bonjour discovery of OMT sources on the local network.
/// Service type: _omt._tcp (as defined in the OMT protocol)
///
/// This is completely independent of NDI discovery.
@available(iOS 13.0, *)
class OMTDiscovery: NSObject {
    
    // MARK: - Callbacks
    
    var onSourcesChanged: (([OMTDiscoveredSource]) -> Void)?
    var onError: ((String) -> Void)?
    
    // MARK: - State
    
    private var browser: NWBrowser?
    private var discoveredSources: [String: OMTDiscoveredSource] = [:]
    private var activeResolvers: [String: BonjourServiceResolver] = [:]
    private let queue = DispatchQueue(label: "com.antigravity.omt.discovery",
                                     qos: .userInitiated)
    private var isRunning = false
    
    // MARK: - Public API
    
    /// Start discovering OMT sources via Bonjour DNS-SD
    func startDiscovery() {
        guard !isRunning else { return }
        isRunning = true
        
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_omt._tcp", domain: "local.")
        let browser = NWBrowser(for: descriptor, using: parameters)
        self.browser = browser
        
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                NSLog("[OMTDiscovery] Browser ready")
            case .failed(let error):
                NSLog("[OMTDiscovery] Browser failed: %@", error.localizedDescription)
                self?.onError?("Discovery failed: \(error.localizedDescription)")
            case .cancelled:
                NSLog("[OMTDiscovery] Browser cancelled")
            default:
                break
            }
        }
        
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            self?.queue.async {
                self?.handleBrowseResults(results: results)
            }
        }
        
        browser.start(queue: queue)
        NSLog("[OMTDiscovery] Started browsing for _omt._tcp")
    }
    
    /// Stop Bonjour discovery
    func stopDiscovery() {
        isRunning = false
        browser?.cancel()
        browser = nil
        DispatchQueue.main.async { [weak self] in
            self?.activeResolvers.values.forEach { $0.cancel() }
            self?.activeResolvers.removeAll()
        }
        NSLog("[OMTDiscovery] Stopped")
    }
    
    /// Returns the current list of discovered sources
    func getCurrentSources() -> [OMTDiscoveredSource] {
        return Array(discoveredSources.values)
    }
    
    // MARK: - Private
    
    private func handleBrowseResults(results: Set<NWBrowser.Result>) {
        var updated: [String: OMTDiscoveredSource] = [:]
        
        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint else {
                continue
            }
            
            // Check if already resolved with valid IPv4
            if let existing = discoveredSources[name], existing.isResolved, !existing.host.isEmpty {
                updated[name] = existing
                continue
            }
            
            // Initial placeholder
            let source = OMTDiscoveredSource(
                name: name,
                serviceName: "\(name).\(type)\(domain)",
                host: "",
                port: 6400, // Standard OMT port
                isResolved: false
            )
            updated[name] = source
            
            // Resolve service to extract real IPv4
            resolveService(name: name, type: type, domain: domain) { [weak self] host, port in
                guard let self = self else { return }
                let resolved = OMTDiscoveredSource(
                    name: name,
                    serviceName: "\(name).\(type)\(domain)",
                    host: host,
                    port: port,
                    isResolved: !host.isEmpty
                )
                self.queue.async {
                    self.discoveredSources[name] = resolved
                    self.notifyChanges()
                }
            }
        }
        
        // Remove sources that disappeared
        let removedKeys = Set(discoveredSources.keys).subtracting(Set(updated.keys))
        for key in removedKeys {
            discoveredSources.removeValue(forKey: key)
        }
        DispatchQueue.main.async { [weak self] in
            for key in removedKeys {
                self?.activeResolvers[key]?.cancel()
                self?.activeResolvers.removeValue(forKey: key)
            }
        }
        
        // Add newly found sources while awaiting resolution
        for (key, source) in updated {
            if discoveredSources[key] == nil {
                discoveredSources[key] = source
            }
        }
        
        notifyChanges()
    }
    
    private func resolveService(name: String, type: String, domain: String,
                                completion: @escaping (String, Int) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.activeResolvers[name]?.cancel()
            let resolver = BonjourServiceResolver(name: name, type: type, domain: domain) { [weak self] host, port in
                DispatchQueue.main.async {
                    self?.activeResolvers.removeValue(forKey: name)
                }
                completion(host, port)
            }
            self.activeResolvers[name] = resolver
            resolver.start()
        }
    }
    
    private func notifyChanges() {
        let sources = Array(discoveredSources.values)
        DispatchQueue.main.async { [weak self] in
            self?.onSourcesChanged?(sources)
        }
    }
}

// MARK: - BonjourServiceResolver

/// Resolves a Bonjour NetService and extracts the IPv4 address (AF_INET),
/// explicitly bypassing IPv6 link-local addresses (fe80::) which are rejected by OMT/vMix.
class BonjourServiceResolver: NSObject, NetServiceDelegate {
    private var netService: NetService?
    private let completion: (String, Int) -> Void
    private var isCompleted = false
    private var timeoutTimer: Timer?
    
    init(name: String, type: String, domain: String, completion: @escaping (String, Int) -> Void) {
        self.completion = completion
        super.init()
        
        let service = NetService(domain: domain, type: type, name: name)
        service.delegate = self
        self.netService = service
    }
    
    func start() {
        guard let service = netService else { return }
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 4.0)
        
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 4.5, repeats: false) { [weak self] _ in
            self?.finish(host: "", port: 6400)
        }
    }
    
    func cancel() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        netService?.stop()
        netService?.delegate = nil
        netService = nil
    }
    
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard !isCompleted else { return }
        
        var resolvedIPv4: String?
        var resolvedPort: Int = sender.port > 0 ? sender.port : 6400
        
        if let addresses = sender.addresses {
            for addressData in addresses {
                addressData.withUnsafeBytes { rawBufferPointer in
                    guard let base = rawBufferPointer.baseAddress else { return }
                    let socketAddress = base.assumingMemoryBound(to: sockaddr.self)
                    if socketAddress.pointee.sa_family == sa_family_t(AF_INET) {
                        let socketAddressIn = base.assumingMemoryBound(to: sockaddr_in.self)
                        var addr = socketAddressIn.pointee.sin_addr
                        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        if let cStr = inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) {
                            let ipStr = String(cString: cStr)
                            if !ipStr.isEmpty && !ipStr.hasPrefix("127.") {
                                resolvedIPv4 = ipStr
                                let portIn = UInt16(bigEndian: socketAddressIn.pointee.sin_port)
                                if portIn > 0 {
                                    resolvedPort = Int(portIn)
                                }
                            }
                        }
                    }
                }
                if resolvedIPv4 != nil {
                    break
                }
            }
        }
        
        // Also check TXT record if available to see if an IP was published
        if resolvedIPv4 == nil, let txtData = sender.txtRecordData() {
            let dict = NetService.dictionary(fromTXTRecord: txtData)
            if let ipData = dict["ip"], let ipStr = String(data: ipData, encoding: .utf8), !ipStr.isEmpty {
                resolvedIPv4 = ipStr
            }
        }
        
        let finalHost: String
        if let ip = resolvedIPv4, !ip.isEmpty {
            finalHost = ip
        } else if let hostName = sender.hostName, !hostName.isEmpty {
            finalHost = hostName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        } else {
            finalHost = ""
        }
        
        NSLog("[OMTDiscovery] Bonjour '%@' resolved to IPv4 %@:%d", sender.name, finalHost, resolvedPort)
        finish(host: finalHost, port: resolvedPort)
    }
    
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        NSLog("[OMTDiscovery] Bonjour '%@' didNotResolve: %@", sender.name, errorDict.description)
        finish(host: "", port: 6400)
    }
    
    private func finish(host: String, port: Int) {
        guard !isCompleted else { return }
        isCompleted = true
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        netService?.stop()
        netService?.delegate = nil
        netService = nil
        completion(host, port)
    }
}

// MARK: - OMTDiscoveredSource

struct OMTDiscoveredSource {
    let name: String
    let serviceName: String
    let host: String
    let port: Int
    let isResolved: Bool
    
    func toDict() -> [String: Any] {
        return [
            "name": name,
            "host": host,
            "port": port,
            "metadata": ""
        ]
    }
}

