#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OMTVMXBridge : NSObject

+ (BOOL)isAvailable;

- (nullable instancetype)initWithWidth:(int)width height:(int)height;

/// Encodes a UYVY 4:2:2 video frame to VMX1 compressed bitstream.
/// @param uyvyData Raw UYVY pixel bytes (width * height * 2 bytes)
/// @return Compressed VMX1 data, or nil on encoding failure.
- (nullable NSData *)encodeUYVY:(NSData *)uyvyData;

/// Frees VMX instance resources.
- (void)destroy;

@end

NS_ASSUME_NONNULL_END
