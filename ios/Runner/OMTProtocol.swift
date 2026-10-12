import Foundation
import AVFoundation
import Network

// MARK: - OMT Protocol Constants (matching libomtnet/PROTOCOL.md)
// All multi-byte values are Little-Endian

/// OMT Frame Types
enum OMTFrameType: UInt8 {
    case metadata = 1
    case video    = 2
    case audio    = 4
}

/// OMT Video Codec FourCC (Little-Endian)
struct OMTVideoCodec {
    /// 'UYVY' — raw 4:2:2 YCbCr (universally supported, no codec library needed)
    static let uyvy: Int32 = 0x59565955
}

/// OMT Color Space
struct OMTColorSpace {
    static let undefined: Int32 = 0
    static let bt601: Int32 = 601
    static let bt709: Int32 = 709
}

/// OMT Video Flags
struct OMTVideoFlags {
    static let none: Int32 = 0
}

// MARK: - OMT Frame Builder

/// Builds binary OMT frames compliant with the OMT 1.0 protocol specification.
/// All integers are written in Little-Endian byte order.
class OMTFrameBuilder {
    
    private static let kProtocolVersion: UInt8 = 1
    
    /// Timestamp unit: 1 second = 10,000,000 ticks (100-nanosecond intervals)
    static func makeTimestamp() -> Int64 {
        let now = Date().timeIntervalSinceReferenceDate
        return Int64(now * 10_000_000.0)
    }
    
    // MARK: - Video Frame
    
    /// Build a complete OMT video frame from raw UYVY pixel data.
    /// Protocol layout (all LE):
    ///   HEADER (16 bytes): Version(1) + FrameType(1) + Timestamp(8) + MetadataLen(2) + DataLen(4)
    ///   VIDEO EXT HEADER (32 bytes): Codec(4) + W(4) + H(4) + FRN(4) + FRD(4) + AR(4) + Flags(4) + CS(4)
    ///   DATA: raw pixel bytes
    static func buildVideoFrame(
        pixelData: Data,
        width: Int32,
        height: Int32,
        frameRateN: Int32,
        frameRateD: Int32,
        colorSpace: Int32 = OMTColorSpace.bt709
    ) -> Data {
        let timestamp = makeTimestamp()
        let aspectRatio = Float(width) / Float(height)
        
        // DataLength = extended header + pixel data (excludes main header)
        let totalDataLength = Int32(32 + pixelData.count)
        
        var frame = Data()
        frame.reserveCapacity(16 + 32 + pixelData.count)
        
        // ─── MAIN HEADER (16 bytes) ───────────────────────────────────────
        frame.appendByte(kProtocolVersion)                      // Version BYTE
        frame.appendByte(OMTFrameType.video.rawValue)           // FrameType BYTE
        frame.appendLE(timestamp)                               // Timestamp INT64
        frame.appendLE(UInt16(0))                               // MetadataLength UINT16
        frame.appendLE(totalDataLength)                         // DataLength INT32
        
        // ─── VIDEO EXTENDED HEADER (32 bytes) ─────────────────────────────
        frame.appendLE(OMTVideoCodec.uyvy)                      // Codec INT32
        frame.appendLE(width)                                   // Width INT32
        frame.appendLE(height)                                  // Height INT32
        frame.appendLE(frameRateN)                              // FrameRateN INT32
        frame.appendLE(frameRateD)                              // FrameRateD INT32
        frame.appendLE(aspectRatio)                             // AspectRatio FLOAT32
        frame.appendLE(OMTVideoFlags.none)                      // Flags INT32
        frame.appendLE(colorSpace)                              // ColorSpace INT32
        
        // ─── DATA ─────────────────────────────────────────────────────────
        frame.append(pixelData)
        
        return frame
    }
    
    // MARK: - Metadata Frame
    
    /// Build an OMT metadata frame (XML UTF-8 payload)
    static func buildMetadataFrame(xmlString: String) -> Data {
        guard var xmlData = xmlString.data(using: .utf8) else { return Data() }
        xmlData.append(0) // null terminator required by protocol
        
        let metadataLength = UInt16(xmlData.count)
        let totalDataLength = Int32(xmlData.count)
        let timestamp = makeTimestamp()
        
        var frame = Data()
        frame.appendByte(kProtocolVersion)
        frame.appendByte(OMTFrameType.metadata.rawValue)
        frame.appendLE(timestamp)
        frame.appendLE(metadataLength)
        frame.appendLE(totalDataLength)
        frame.append(xmlData)
        
        return frame
    }
    
    // MARK: - Source Identity XML
    
    /// Generates the initial metadata that identifies this source to vMix 29.
    static func buildSenderIdentityXML(sourceName: String, width: Int32, height: Int32,
                                        frameRateN: Int32, frameRateD: Int32) -> String {
        let escaped = xmlEscape(sourceName)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ndi>
          <source name="\(escaped)" />
          <video width="\(width)" height="\(height)" frame_rate_n="\(frameRateN)" frame_rate_d="\(frameRateD)" />
          <generator name="MIMO_NDI" version="1.0" />
        </ndi>
        """
    }
    
    private static func xmlEscape(_ s: String) -> String {
        return s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Data Extensions for Little-Endian writing

extension Data {
    mutating func appendByte(_ value: UInt8) {
        append(value)
    }
    mutating func appendLE(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: Int32) {
        withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: Int64) {
        withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: Float) {
        var v = value.bitPattern.littleEndian
        withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
