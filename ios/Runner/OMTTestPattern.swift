import Foundation
import UIKit

/// Generates standard 75% SMPTE color bars in UYVY (4:2:2) format
/// with a moving motion indicator for diagnostic verification of OMT video pipelines.
/// If vMix 29 receives this test pattern with full colors and motion,
/// we know 100% that the VMX1 encoder, OMT headers, TCP negotiation, and network transmission
/// are functional and compliant with vMix 29.
class OMTTestPattern {
    
    // 75% SMPTE Color Bars (UYVY 4:2:2 byte quad: [U, Y0, V, Y1])
    // Standard broadcast Rec.709 75% bar values
    private static let kBarColorsUYVY: [[UInt8]] = [
        [128, 180, 128, 180], // 75% White
        [44,  162, 142, 162], // Yellow
        [156, 131, 44,  131], // Cyan
        [72,  112, 58,  112], // Green
        [184, 84,  198, 84],  // Magenta
        [100, 65,  212, 65],  // Red
        [212, 35,  114, 35],  // Blue
        [128, 16,  128, 16]   // Black
    ]
    
    // Moving marker color: bright magenta [184, 180, 198, 180]
    private static let kMarkerColorUYVY: [UInt8] = [184, 180, 198, 180]
    
    /// Generates a single complete UYVY 4:2:2 video frame (width * height * 2 bytes).
    /// - Parameters:
    ///   - width: Image width in pixels (must be even, e.g. 1920 or 1280)
    ///   - height: Image height in pixels (e.g. 1080 or 720)
    ///   - frameIndex: Monotonically increasing frame index used to animate the motion marker.
    /// - Returns: Raw UYVY pixel bytes.
    static func generateUYVYFrame(width: Int, height: Int, frameIndex: Int64) -> Data {
        let totalBytes = width * height * 2
        var data = Data(count: totalBytes)
        
        let numBars = kBarColorsUYVY.count
        let barWidth = width / numBars
        
        // Height divisions: top 75% is main color bars, bottom 25% has sync bars and moving box
        let topBarHeight = (height * 3) / 4
        
        // Animated box parameters in the lower 25% section
        let boxWidth = max(32, width / 16)
        let boxHeight = max(24, (height - topBarHeight) / 2)
        let boxYStart = topBarHeight + ((height - topBarHeight - boxHeight) / 2)
        
        // Move box back and forth across the screen
        let travelWidth = max(1, width - boxWidth)
        let cycle = Int(frameIndex % Int64(travelWidth * 2))
        let boxXStart = (cycle < travelWidth) ? cycle : (travelWidth * 2 - cycle)
        let boxXEnd = boxXStart + boxWidth
        let boxYEnd = boxYStart + boxHeight
        
        data.withUnsafeMutableBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            
            for y in 0..<height {
                let rowOffset = y * width * 2
                let isTopSection = (y < topBarHeight)
                let isBoxY = (!isTopSection && y >= boxYStart && y < boxYEnd)
                
                var x = 0
                while x < width {
                    let pixelPairIndex = x / 2
                    let byteOffset = rowOffset + (pixelPairIndex * 4)
                    
                    if isBoxY && x >= boxXStart && x < boxXEnd {
                        // Moving animated indicator box
                        ptr[byteOffset]     = kMarkerColorUYVY[0]
                        ptr[byteOffset + 1] = kMarkerColorUYVY[1]
                        ptr[byteOffset + 2] = kMarkerColorUYVY[2]
                        ptr[byteOffset + 3] = kMarkerColorUYVY[3]
                    } else if isTopSection {
                        // Standard top color bars
                        let barIndex = min(x / barWidth, numBars - 1)
                        let bar = kBarColorsUYVY[barIndex]
                        ptr[byteOffset]     = bar[0]
                        ptr[byteOffset + 1] = bar[1]
                        ptr[byteOffset + 2] = bar[2]
                        ptr[byteOffset + 3] = bar[3]
                    } else {
                        // Bottom section: reversed bars for sync contrast
                        let barIndex = min((width - 1 - x) / barWidth, numBars - 1)
                        let bar = kBarColorsUYVY[barIndex]
                        ptr[byteOffset]     = bar[0]
                        ptr[byteOffset + 1] = bar[1]
                        ptr[byteOffset + 2] = bar[2]
                        ptr[byteOffset + 3] = bar[3]
                    }
                    
                    x += 2
                }
            }
        }
        
        return data
    }
}
