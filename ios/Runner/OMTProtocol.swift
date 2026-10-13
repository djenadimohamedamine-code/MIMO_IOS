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
    /// 'VMX1' — vMix 1 video codec (official compressed codec for OMT)
    /// ('V' | ('M' << 8) | ('X' << 16) | ('1' << 24)) = 0x31584D56
    static let vmx1: Int32 = 0x31584D56
    
    /// 'UYVY' — raw 4:2:2 YCbCr (uncompressed fallback)
    /// ('U' | ('Y' << 8) | ('V' << 16) | ('Y' << 24)) = 0x59565955
    static let uyvy: Int32 = 0x59565955
}

/// OMT Audio Codec FourCC (Little-Endian)
struct OMTAudioCodec {
    /// 'FPA1' — 32-bit floating point planar audio (official OMT audio codec)
    /// ('F' | ('P' << 8) | ('A' << 16) | ('1' << 24)) = 0x31415046
    static let fpa1: Int32 = 0x31415046
}

/// OMT Audio Extended Header (24 bytes, Little-Endian)
/// Layout matching libomtnet:
/// [0..3]:   Codec FourCC (Int32 LE, e.g. 0x31415046 'FPA1')
/// [4..7]:   SampleRate (Int32 LE, e.g. 48000)
/// [8..11]:  SamplesPerChannel (Int32 LE, e.g. 1024)
/// [12..15]: Channels (Int32 LE, e.g. 2)
/// [16..19]: ActiveChannels (UInt32 LE bitmask: 1 << channelIndex)
/// [20..23]: Reserved1 (Int32 LE, 0)
struct OMTAudioHeader {
    let codec: Int32
    let sampleRate: Int32
    let samplesPerChannel: Int32
    let channels: Int32
    let activeChannels: UInt32
    let reserved1: Int32
    
    init?(from data: Data) {
        guard data.count >= 24 else { return nil }
        self.codec = data.readLEInt32(offset: 0)
        self.sampleRate = data.readLEInt32(offset: 4)
        self.samplesPerChannel = data.readLEInt32(offset: 8)
        self.channels = data.readLEInt32(offset: 12)
        self.activeChannels = UInt32(bitPattern: data.readLEInt32(offset: 16))
        self.reserved1 = data.readLEInt32(offset: 20)
    }
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
    static let interlaced: Int32 = 1
    static let alpha: Int32 = 2
    static let preMultiplied: Int32 = 4
    static let preview: Int32 = 8
    static let highBitDepth: Int32 = 16
}

/// Official OMT Fixed Metadata Command Strings (from libomtnet OMTMetadataConstants)
struct OMTMetadataCommand {
    static let subscribeVideo = "<OMTSubscribe Video=\"true\" />"
    static let unsubscribeVideo = "<OMTSubscribe Video=\"false\" />"
    static let subscribeAudio = "<OMTSubscribe Audio=\"true\" />"
    static let unsubscribeAudio = "<OMTSubscribe Audio=\"false\" />"
    static let subscribeMetadata = "<OMTSubscribe Metadata=\"true\" />"
    static let previewOn = "<OMTSettings Preview=\"true\" />"
    static let previewOff = "<OMTSettings Preview=\"false\" />"
    static let qualityDefault = "<OMTSettings Quality=\"Default\" />"
    
    // NB: Double == typo is in official libomtnet specification for backwards compatibility
    static let tallyPreview = "<OMTTally Preview=\"true\" Program==\"false\" />"
    static let tallyProgram = "<OMTTally Preview=\"false\" Program==\"true\" />"
    static let tallyPreviewProgram = "<OMTTally Preview=\"true\" Program==\"true\" />"
    static let tallyNone = "<OMTTally Preview=\"false\" Program==\"false\" />"
}

/// Parsed client commands received over TCP
enum OMTCommand {
    case subscribeVideo(Bool)
    case subscribeAudio(Bool)
    case subscribeMetadata(Bool)
    case setPreview(Bool)
    case setQuality(String)
    case tally(preview: Bool, program: Bool)
    case unknown(String)
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
    
    /// Build a complete OMT video frame.
    /// Protocol layout (all LE):
    ///   HEADER (16 bytes): Version(1) + FrameType(1) + Timestamp(8) + MetadataLen(2) + DataLen(4)
    ///   VIDEO EXT HEADER (32 bytes): Codec(4) + W(4) + H(4) + FRN(4) + FRD(4) + AR(4) + Flags(4) + CS(4)
    ///   DATA: compressed VMX1 bitstream or raw pixel bytes
    static func buildVideoFrame(
        payloadData: Data,
        codec: Int32 = OMTVideoCodec.vmx1,
        width: Int32,
        height: Int32,
        frameRateN: Int32,
        frameRateD: Int32,
        flags: Int32 = OMTVideoFlags.none,
        colorSpace: Int32 = OMTColorSpace.bt709
    ) -> Data {
        let timestamp = makeTimestamp()
        let aspectRatio = Float(width) / Float(height)
        
        // DataLength = extended header (32 bytes) + video payload data (excludes main 16-byte header)
        let totalDataLength = Int32(32 + payloadData.count)
        
        var frame = Data()
        frame.reserveCapacity(16 + 32 + payloadData.count)
        
        // ─── MAIN HEADER (16 bytes) ───────────────────────────────────────
        frame.appendByte(kProtocolVersion)                      // Version BYTE (1)
        frame.appendByte(OMTFrameType.video.rawValue)           // FrameType BYTE (2)
        frame.appendLE(timestamp)                               // Timestamp INT64
        frame.appendLE(UInt16(0))                               // MetadataLength UINT16
        frame.appendLE(totalDataLength)                         // DataLength INT32
        
        // ─── VIDEO EXTENDED HEADER (32 bytes) ─────────────────────────────
        frame.appendLE(codec)                                   // Codec INT32 (VMX1 or UYVY)
        frame.appendLE(width)                                   // Width INT32
        frame.appendLE(height)                                  // Height INT32
        frame.appendLE(frameRateN)                              // FrameRateN INT32
        frame.appendLE(frameRateD)                              // FrameRateD INT32
        frame.appendLE(aspectRatio)                             // AspectRatio FLOAT32
        frame.appendLE(flags)                                   // Flags INT32
        frame.appendLE(colorSpace)                              // ColorSpace INT32
        
        // ─── DATA ─────────────────────────────────────────────────────────
        frame.append(payloadData)
        
        return frame
    }
    
    // MARK: - Metadata Frame
    
    /// Build an OMT metadata frame (XML UTF-8 payload, without null terminator)
    /// Conforms to official libomtnet specification (OMTChannel.cs / OMTFrame.cs):
    /// - Version: 1 (BYTE)
    /// - FrameType: 1 (BYTE, Metadata)
    /// - Timestamp: 0 (INT64 LE)
    /// - MetadataLength: 0 (UINT16 LE, per-frame metadata length is 0 for standalone metadata frames)
    /// - DataLength: length of UTF-8 XML in bytes (INT32 LE)
    /// - Data: raw UTF-8 XML bytes (exact string match without \0)
    static func buildMetadataFrame(xmlString: String, timestamp: Int64 = 0) -> Data {
        guard let xmlData = xmlString.data(using: .utf8) else { return Data() }
        
        let metadataLength: UInt16 = 0
        let totalDataLength = Int32(xmlData.count)
        
        var frame = Data()
        frame.reserveCapacity(16 + xmlData.count)
        frame.appendByte(kProtocolVersion)                      // Version BYTE (1)
        frame.appendByte(OMTFrameType.metadata.rawValue)        // FrameType BYTE (1)
        frame.appendLE(timestamp)                               // Timestamp INT64 (0)
        frame.appendLE(metadataLength)                          // MetadataLength UINT16 (0)
        frame.appendLE(totalDataLength)                         // DataLength INT32
        frame.append(xmlData)
        
        return frame
    }
    
    // MARK: - Source Identity XML (Official OMT <OMTInfo ... />)
    
    /// Generates the official OMT source identity metadata sent to receivers (vMix 29) on connect.
    static func buildSenderIdentityXML(productName: String = "MIMO_NDI",
                                        manufacturer: String = "MIMO",
                                        version: String = "1.0") -> String {
        let p = xmlEscape(productName)
        let m = xmlEscape(manufacturer)
        let v = xmlEscape(version)
        return "<OMTInfo ProductName=\"\(p)\" Manufacturer=\"\(m)\" Version=\"\(v)\" />"
    }
    
    // MARK: - Command Parser
    
    /// Parses incoming XML metadata command from a receiver (e.g. vMix 29).
    static func parseCommand(from xmlString: String) -> OMTCommand {
        let trimmed = xmlString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed == OMTMetadataCommand.subscribeVideo || trimmed.contains("Video=\"true\"") {
            return .subscribeVideo(true)
        }
        if trimmed == OMTMetadataCommand.unsubscribeVideo || trimmed.contains("Video=\"false\"") {
            return .subscribeVideo(false)
        }
        if trimmed == OMTMetadataCommand.subscribeAudio || trimmed.contains("Audio=\"true\"") {
            return .subscribeAudio(true)
        }
        if trimmed == OMTMetadataCommand.unsubscribeAudio || trimmed.contains("Audio=\"false\"") {
            return .subscribeAudio(false)
        }
        if trimmed == OMTMetadataCommand.subscribeMetadata || trimmed.contains("Metadata=\"true\"") {
            return .subscribeMetadata(true)
        }
        if trimmed == OMTMetadataCommand.previewOn || (trimmed.contains("Preview=\"true\"") && trimmed.contains("OMTSettings")) {
            return .setPreview(true)
        }
        if trimmed == OMTMetadataCommand.previewOff || (trimmed.contains("Preview=\"false\"") && trimmed.contains("OMTSettings")) {
            return .setPreview(false)
        }
        if trimmed.contains("<OMTSettings Quality=") {
            if let range = trimmed.range(of: "Quality=\"([^\"]+)\"", options: .regularExpression) {
                let match = String(trimmed[range])
                let quality = match.replacingOccurrences(of: "Quality=\"", with: "").replacingOccurrences(of: "\"", with: "")
                return .setQuality(quality)
            }
        }
        if trimmed == OMTMetadataCommand.tallyProgram {
            return .tally(preview: false, program: true)
        }
        if trimmed == OMTMetadataCommand.tallyPreview {
            return .tally(preview: true, program: false)
        }
        if trimmed == OMTMetadataCommand.tallyPreviewProgram {
            return .tally(preview: true, program: true)
        }
        if trimmed == OMTMetadataCommand.tallyNone {
            return .tally(preview: false, program: false)
        }
        
        return .unknown(trimmed)
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
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: Int32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: Int64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: Float) {
        var v = value.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
