import Foundation

/// Manages video encoding for Open Media Transport (OMT).
/// Seamlessly uses the native ARM64 VMX1 codec (via libvmx / OMTVMXBridge) for 
/// genuine vMix 29 interoperability.
/// If VMX1 compression is not available or fails, it provides a transparent fallback
/// to uncompressed UYVY 4:2:2 while logging the state.
class OMTVideoEncoder {
    
    let width: Int32
    let height: Int32
    let frameRateN: Int32
    let frameRateD: Int32
    
    private var vmxBridge: OMTVMXBridge?
    private(set) var isVMX1Active: Bool = false
    private(set) var lastEncodedBytes: Int = 0
    private(set) var compressionRatio: Double = 1.0
    
    init(width: Int32, height: Int32, frameRateN: Int32, frameRateD: Int32) {
        self.width = width
        self.height = height
        self.frameRateN = frameRateN
        self.frameRateD = frameRateD
        
        setupEncoder()
    }
    
    private func setupEncoder() {
        if OMTVMXBridge.isAvailable() {
            if let bridge = OMTVMXBridge(width: width, height: height) {
                self.vmxBridge = bridge
                self.isVMX1Active = true
                NSLog("[OMTVideoEncoder] Initialized VMX1 codec for %dx%d", width, height)
            } else {
                NSLog("[OMTVideoEncoder] Failed to instantiate VMX1 codec, falling back to UYVY")
                self.isVMX1Active = false
            }
        } else {
            NSLog("[OMTVideoEncoder] VMX1 codec unavailable on this architecture, using UYVY")
            self.isVMX1Active = false
        }
    }
    
    /// Encodes a raw UYVY video frame.
    /// Returns the frame payload data and the corresponding OMT codec FourCC (VMX1 or UYVY).
    func encode(uyvyData: Data) -> (data: Data, codec: Int32) {
        let rawSize = uyvyData.count
        
        if isVMX1Active, let bridge = vmxBridge {
            if let compressed = bridge.encodeUYVY(uyvyData), compressed.count > 0 {
                lastEncodedBytes = compressed.count
                if rawSize > 0 {
                    compressionRatio = Double(rawSize) / Double(compressed.count)
                }
                return (compressed, OMTVideoCodec.vmx1)
            } else {
                NSLog("[OMTVideoEncoder] VMX1 encoding failed for frame, falling back to UYVY")
            }
        }
        
        lastEncodedBytes = rawSize
        compressionRatio = 1.0
        return (uyvyData, OMTVideoCodec.uyvy)
    }
    
    func destroy() {
        vmxBridge?.destroy()
        vmxBridge = nil
        isVMX1Active = false
    }
    
    deinit {
        destroy()
    }
}
