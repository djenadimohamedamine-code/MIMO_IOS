#import "OMTVMXBridge.h"
#import "vmxcodec.h"

@interface OMTVMXBridge () {
    VMX_INSTANCE *_instance;
    int _width;
    int _height;
    NSMutableData *_outBuffer;
    NSString *_lastError;
}
@end

@implementation OMTVMXBridge

@synthesize width = _width;
@synthesize height = _height;
@synthesize lastError = _lastError;

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
        _lastError = nil;
        
        VMX_SIZE size;
        size.width = width;
        size.height = height;
        
        // VMX_PROFILE_OMT_SQ (166) is the standard profile for Open Media Transport
        // VMX_COLORSPACE_BT709 (709) for HD video
        _instance = VMX_Create(size, VMX_PROFILE_OMT_SQ, VMX_COLORSPACE_BT709);
        if (!_instance) {
            _lastError = [NSString stringWithFormat:@"VMX_Create failed for %dx%d", width, height];
            NSLog(@"[OMTVMXBridge] %@", _lastError);
            return nil;
        }
        
        // Output buffer size: libvmx recommends at least width * height * 4 bytes
        NSUInteger maxBufferSize = (NSUInteger)(width * height * 4);
        _outBuffer = [NSMutableData dataWithLength:maxBufferSize];
        
        NSLog(@"[OMTVMXBridge] VMX codec initialized for %dx%d (Buffer: %lu bytes)",
              width, height, (unsigned long)maxBufferSize);
    }
    return self;
}

- (nullable NSData *)encodeUYVY:(NSData *)uyvyData {
    if (!_instance || !uyvyData) {
        _lastError = @"Null instance or uyvyData";
        return nil;
    }
    
    int stride = _width * 2;
    int interlaced = 0; // Progressive broadcast
    
    VMX_ERR err = VMX_EncodeUYVY(_instance, (BYTE *)uyvyData.bytes, stride, interlaced);
    if (err != VMX_ERR_OK) {
        _lastError = [NSString stringWithFormat:@"VMX_EncodeUYVY error code: %d", (int)err];
        NSLog(@"[OMTVMXBridge] %@", _lastError);
        return nil;
    }
    
    int bytesWritten = VMX_SaveTo(_instance, (BYTE *)_outBuffer.mutableBytes, (int)_outBuffer.length);
    if (bytesWritten <= 0) {
        _lastError = [NSString stringWithFormat:@"VMX_SaveTo error: %d bytes written", bytesWritten];
        NSLog(@"[OMTVMXBridge] %@", _lastError);
        return nil;
    }
    
    _lastError = nil;
    return [NSData dataWithBytes:_outBuffer.bytes length:(NSUInteger)bytesWritten];
}

- (nullable NSData *)encodeNV12YPlane:(const uint8_t *)yPlane
                              strideY:(int)strideY
                              uvPlane:(const uint8_t *)uvPlane
                             strideUV:(int)strideUV
                           interlaced:(int)interlaced {
    if (!_instance || !yPlane || !uvPlane) {
        _lastError = @"Null instance or plane pointers";
        return nil;
    }
    
    VMX_ERR err = VMX_EncodeNV12(_instance, (BYTE *)yPlane, strideY, (BYTE *)uvPlane, strideUV, interlaced);
    if (err != VMX_ERR_OK) {
        _lastError = [NSString stringWithFormat:@"VMX_EncodeNV12 error code: %d", (int)err];
        NSLog(@"[OMTVMXBridge] %@", _lastError);
        return nil;
    }
    
    int bytesWritten = VMX_SaveTo(_instance, (BYTE *)_outBuffer.mutableBytes, (int)_outBuffer.length);
    if (bytesWritten <= 0) {
        _lastError = [NSString stringWithFormat:@"VMX_SaveTo error: %d bytes written", bytesWritten];
        NSLog(@"[OMTVMXBridge] %@", _lastError);
        return nil;
    }
    
    _lastError = nil;
    return [NSData dataWithBytes:_outBuffer.bytes length:(NSUInteger)bytesWritten];
}

- (BOOL)decodeVMX:(NSData *)vmxData toBGRA:(uint8_t *)dst stride:(int)stride {
    if (!_instance || !vmxData || !dst || vmxData.length == 0) {
        _lastError = @"Invalid decode parameters";
        return NO;
    }
    
    VMX_ERR loadErr = VMX_LoadFrom(_instance, (BYTE *)vmxData.bytes, (int)vmxData.length);
    if (loadErr != VMX_ERR_OK) {
        _lastError = [NSString stringWithFormat:@"VMX_LoadFrom error code: %d", (int)loadErr];
        NSLog(@"[OMTVMXBridge] %@", _lastError);
        return NO;
    }
    
    VMX_ERR decErr = VMX_DecodeBGRA(_instance, (BYTE *)dst, stride);
    if (decErr != VMX_ERR_OK) {
        _lastError = [NSString stringWithFormat:@"VMX_DecodeBGRA error code: %d", (int)decErr];
        NSLog(@"[OMTVMXBridge] %@", _lastError);
        return NO;
    }
    
    _lastError = nil;
    return YES;
}

- (BOOL)decodeVMX:(NSData *)vmxData toUYVY:(uint8_t *)dst stride:(int)stride {
    if (!_instance || !vmxData || !dst || vmxData.length == 0) {
        _lastError = @"Invalid decode parameters";
        return NO;
    }
    
    VMX_ERR loadErr = VMX_LoadFrom(_instance, (BYTE *)vmxData.bytes, (int)vmxData.length);
    if (loadErr != VMX_ERR_OK) {
        _lastError = [NSString stringWithFormat:@"VMX_LoadFrom error code: %d", (int)loadErr];
        NSLog(@"[OMTVMXBridge] %@", _lastError);
        return NO;
    }
    
    VMX_ERR decErr = VMX_DecodeUYVY(_instance, (BYTE *)dst, stride);
    if (decErr != VMX_ERR_OK) {
        _lastError = [NSString stringWithFormat:@"VMX_DecodeUYVY error code: %d", (int)decErr];
        NSLog(@"[OMTVMXBridge] %@", _lastError);
        return NO;
    }
    
    _lastError = nil;
    return YES;
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
