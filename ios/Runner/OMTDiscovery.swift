import Foundation
import Network

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
            
            // Resolve the endpoint to get host and port
            let source = OMTDiscoveredSource(
                name: name,
                serviceName: "\(name).\(type)\(domain)",
                host: "",   // Will be populated on resolve
                port: 7788, // Default OMT port
                isResolved: false
            )
            updated[name] = source
            
            // Resolve the service to get actual host/port
            resolveService(name: name, type: type, domain: domain) { [weak self] host, port in
                guard let self = self else { return }
                let resolved = OMTDiscoveredSource(
                    name: name,
                    serviceName: "\(name).\(type)\(domain)",
                    host: host,
                    port: port,
                    isResolved: true
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
        
        // Add newly found (unresolved) sources while awaiting resolution
        for (key, source) in updated {
            if discoveredSources[key] == nil {
                discoveredSources[key] = source
            }
        }
        
        notifyChanges()
    }
    
    private func resolveService(name: String, type: String, domain: String,
                                completion: @escaping (String, Int) -> Void) {
        // Use NWConnection to resolve the Bonjour service
        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        let connection = NWConnection(to: endpoint, using: .tcp)
        
        connection.stateUpdateHandler = { state in
            switch state {
            case .preparing:
                break
            case .ready:
                // Extract host and port from the connection
                if let path = connection.currentPath,
                   case .hostPort(let host, let port) = path.remoteEndpoint {
                    let hostStr: String
                    switch host {
                    case .name(let n, _):
                        hostStr = n
                    case .ipv4(let addr):
                        hostStr = "\(addr)"
                    case .ipv6(let addr):
                        hostStr = "\(addr)"
                    @unknown default:
                        hostStr = ""
                    }
                    let portInt = Int(port.rawValue)
                    connection.cancel()
                    completion(hostStr, portInt)
                }
            case .failed:
                connection.cancel()
                // Use default port if resolution fails
                completion("", 7788)
            default:
                break
            }
        }
        
        connection.start(queue: queue)
        
        // Timeout after 3 seconds
        queue.asyncAfter(deadline: .now() + 3) {
            if connection.state != .ready && connection.state != .cancelled {
                connection.cancel()
            }
        }
    }
    
    private func notifyChanges() {
        let sources = Array(discoveredSources.values)
        DispatchQueue.main.async { [weak self] in
            self?.onSourcesChanged?(sources)
        }
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
