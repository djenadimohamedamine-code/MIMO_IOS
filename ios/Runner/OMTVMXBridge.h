#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OMTVMXBridge : NSObject

@property (nonatomic, readonly) int width;
@property (nonatomic, readonly) int height;
@property (nonatomic, readonly, nullable) NSString *lastError;

+ (BOOL)isAvailable;

- (nullable instancetype)initWithWidth:(int)width height:(int)height;

/// Encodes a UYVY 4:2:2 video frame to VMX1 compressed bitstream.
/// @param uyvyData Raw UYVY pixel bytes (width * height * 2 bytes)
/// @return Compressed VMX1 data, or nil on encoding failure.
- (nullable NSData *)encodeUYVY:(NSData *)uyvyData;

/// Encodes NV12 bi-planar video data directly (zero copy from iOS camera buffer).
/// @param yPlane Pointer to Y plane bytes
/// @param strideY Bytes per row in Y plane
/// @param uvPlane Pointer to UV plane bytes
/// @param strideUV Bytes per row in UV plane
/// @param interlaced 0 for progressive, 1 for interlaced
/// @return Compressed VMX1 data, or nil on encoding failure.
- (nullable NSData *)encodeNV12YPlane:(const uint8_t *)yPlane
                              strideY:(int)strideY
                              uvPlane:(const uint8_t *)uvPlane
                             strideUV:(int)strideUV
                           interlaced:(int)interlaced;

/// Decodes a compressed VMX1 bitstream into BGRA 32-bit pixel buffer.
/// @param vmxData Compressed VMX1 bytes
/// @param dst Destination buffer pointer (must have capacity >= stride * height)
/// @param stride Destination bytes per row (e.g. width * 4)
/// @return YES on success, NO on failure.
- (BOOL)decodeVMX:(NSData *)vmxData toBGRA:(uint8_t *)dst stride:(int)stride;

/// Decodes a compressed VMX1 bitstream into UYVY 4:2:2 pixel buffer.
/// @param vmxData Compressed VMX1 bytes
/// @param dst Destination buffer pointer (must have capacity >= stride * height)
/// @param stride Destination bytes per row (e.g. width * 2)
/// @return YES on success, NO on failure.
- (BOOL)decodeVMX:(NSData *)vmxData toUYVY:(uint8_t *)dst stride:(int)stride;

/// Frees VMX instance resources.
- (void)destroy;

@end

NS_ASSUME_NONNULL_END
