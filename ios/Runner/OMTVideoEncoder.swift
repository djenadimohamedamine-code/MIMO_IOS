import Foundation

/// Manages video encoding for Open Media Transport (OMT).
/// Seamlessly uses the native ARM64 VMX1 codec (via libvmx / OMTVMXBridge) for 
/// genuine vMix 29 interoperability.
/// Dynamically updates encoder dimensions if the camera feed or test pattern
/// switches resolution (e.g. 1080p, 720p).
class OMTVideoEncoder {
    
    private(set) var width: Int32
    private(set) var height: Int32
    let frameRateN: Int32
    let frameRateD: Int32
    
    private var vmxBridge: OMTVMXBridge?
    private(set) var isVMX1Active: Bool = false
    private(set) var lastEncodedBytes: Int = 0
    private(set) var compressionRatio: Double = 1.0
    private(set) var lastError: String?
    private(set) var encodedFrameCount: Int64 = 0
    
    init(width: Int32, height: Int32, frameRateN: Int32, frameRateD: Int32) {
        self.width = width
        self.height = height
        self.frameRateN = frameRateN
        self.frameRateD = frameRateD
        
        setupEncoder()
    }
    
    /// Recreates the VMX1 instance if dimensions changed (e.g. camera orientation or preset change)
    func updateDimensionsIfNeeded(width: Int32, height: Int32) {
        guard width != self.width || height != self.height else { return }
        NSLog("[OMTVideoEncoder] Dimension changed from %dx%d to %dx%d — reinitializing VMX1",
              self.width, self.height, width, height)
        destroy()
        self.width = width
        self.height = height
        setupEncoder()
    }
    
    private func setupEncoder() {
        if OMTVMXBridge.isAvailable() {
            if let bridge = OMTVMXBridge(width: width, height: height) {
                self.vmxBridge = bridge
                self.isVMX1Active = true
                self.lastError = nil
                NSLog("[OMTVideoEncoder] Initialized VMX1 codec for %dx%d", width, height)
            } else {
                let err = "Failed to instantiate VMX1 codec for \(width)x\(height)"
                NSLog("[OMTVideoEncoder] %@", err)
                self.lastError = err
                self.isVMX1Active = false
            }
        } else {
            let err = "VMX1 codec unavailable on this architecture"
            NSLog("[OMTVideoEncoder] %@", err)
            self.lastError = err
            self.isVMX1Active = false
        }
    }
    
    /// Encodes a raw UYVY video frame.
    /// Returns the frame payload data and the corresponding OMT codec FourCC (VMX1 or UYVY).
    func encode(uyvyData: Data, width: Int32? = nil, height: Int32? = nil) -> (data: Data, codec: Int32) {
        if let w = width, let h = height {
            updateDimensionsIfNeeded(width: w, height: h)
        }
        
        let rawSize = uyvyData.count
        
        if isVMX1Active, let bridge = vmxBridge {
            if let compressed = bridge.encodeUYVY(uyvyData), compressed.count > 0 {
                lastEncodedBytes = compressed.count
                encodedFrameCount += 1
                if rawSize > 0 {
                    compressionRatio = Double(rawSize) / Double(compressed.count)
                }
                lastError = nil
                return (compressed, OMTVideoCodec.vmx1)
            } else {
                let err = bridge.lastError ?? "VMX1 encodeUYVY returned empty data"
                lastError = err
                NSLog("[OMTVideoEncoder] %@, falling back to UYVY", err)
            }
        }
        
        lastEncodedBytes = rawSize
        compressionRatio = 1.0
        return (uyvyData, OMTVideoCodec.uyvy)
    }
    
    /// Encodes NV12 bi-planar video data directly (zero copy from iOS camera buffer)
    func encodeNV12(yPlane: UnsafePointer<UInt8>,
                    strideY: Int,
                    uvPlane: UnsafePointer<UInt8>,
                    strideUV: Int,
                    width: Int32,
                    height: Int32) -> (data: Data, codec: Int32)? {
        updateDimensionsIfNeeded(width: width, height: height)
        
        guard isVMX1Active, let bridge = vmxBridge else {
            return nil
        }
        
        if let compressed = bridge.encodeNV12YPlane(yPlane,
                                                    strideY: Int32(strideY),
                                                    uvPlane: uvPlane,
                                                    strideUV: Int32(strideUV),
                                                    interlaced: 0),
           compressed.count > 0 {
            lastEncodedBytes = compressed.count
            encodedFrameCount += 1
            lastError = nil
            return (compressed, OMTVideoCodec.vmx1)
        } else {
            let err = bridge.lastError ?? "VMX1 encodeNV12 returned empty data"
            lastError = err
            NSLog("[OMTVideoEncoder] %@", err)
            return nil
        }
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
