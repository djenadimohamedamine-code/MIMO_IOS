#import "OMTVMXBridge.h"
#import "vmxcodec.h"

@interface OMTVMXBridge () {
    VMX_INSTANCE *_instance;
    int _width;
    int _height;
    NSMutableData *_outBuffer;
}
@end

@implementation OMTVMXBridge

+ (BOOL)isAvailable {
#if defined(ARM64) || defined(__arm64__) || defined(__aarch64__)
    return YES;
#else
    return NO;
#endif
}

- (nullable instancetype)initWithWidth:(int)width height:(int)height {
    self = [super init];
    if (self) {
        _width = width;
        _height = height;
        
        VMX_SIZE size;
        size.width = width;
        size.height = height;
        
        // VMX_PROFILE_OMT_SQ (166) is the standard profile for Open Media Transport
        // VMX_COLORSPACE_BT709 (709) for HD video
        _instance = VMX_Create(size, VMX_PROFILE_OMT_SQ, VMX_COLORSPACE_BT709);
        if (!_instance) {
            NSLog(@"[OMTVMXBridge] Failed to create VMX codec instance for %dx%d", width, height);
            return nil;
        }
        
        // Maximum output buffer size (width * height * 2 is plenty for compressed frame)
        NSUInteger maxBufferSize = (NSUInteger)(width * height * 2);
        _outBuffer = [NSMutableData dataWithLength:maxBufferSize];
        
        NSLog(@"[OMTVMXBridge] VMX codec initialized for %dx%d (Profile OMT_SQ)", width, height);
    }
    return self;
}

- (nullable NSData *)encodeUYVY:(NSData *)uyvyData {
    if (!_instance || !uyvyData) {
        return nil;
    }
    
    int stride = _width * 2;
    int interlaced = 0; // Progressive
    
    VMX_ERR err = VMX_EncodeUYVY(_instance, (BYTE *)uyvyData.bytes, stride, interlaced);
    if (err != VMX_ERR_OK) {
        NSLog(@"[OMTVMXBridge] VMX_EncodeUYVY error: %d", (int)err);
        return nil;
    }
    
    int bytesWritten = VMX_SaveTo(_instance, (BYTE *)_outBuffer.mutableBytes, (int)_outBuffer.length);
    if (bytesWritten <= 0) {
        NSLog(@"[OMTVMXBridge] VMX_SaveTo error: %d bytes written", bytesWritten);
        return nil;
    }
    
    return [NSData dataWithBytes:_outBuffer.bytes length:(NSUInteger)bytesWritten];
}

- (void)destroy {
    if (_instance) {
        VMX_Destroy(_instance);
        _instance = NULL;
    }
}

- (void)dealloc {
    [self destroy];
}

@end
