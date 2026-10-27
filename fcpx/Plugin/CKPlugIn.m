//
//  CKPlugIn.m
//  CorridorKey FxPlug
//

#import "CKPlugIn.h"
#import "CKClient.h"
#import "CKShared.h"

#import <Accelerate/Accelerate.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <os/lock.h>

static const int32_t kCKWindowSizes[] = { 1, 5, 9, 17 };

#pragma mark - Small helpers

static NSError *CKFxError(NSInteger code, NSString *message) {
    NSLog(@"[CorridorKey] %@", message);
    return [NSError errorWithDomain:FxPlugErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static id<MTLDevice> CKDeviceForRegistryID(uint64_t registryID) {
    static NSMutableDictionary<NSNumber *, id<MTLDevice>> *cache;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    if (cache == nil) cache = [NSMutableDictionary dictionary];
    id<MTLDevice> device = cache[@(registryID)];
    if (device == nil) {
        for (id<MTLDevice> d in MTLCopyAllDevices()) {
            if (d.registryID == registryID) { device = d; break; }
        }
        if (device == nil) device = MTLCreateSystemDefaultDevice();
        if (device != nil) cache[@(registryID)] = device;
    }
    os_unfair_lock_unlock(&lock);
    return device;
}

typedef enum { kCKPix_Unknown, kCKPix_RGBAHalf, kCKPix_RGBAFloat, kCKPix_BGRA8, kCKPix_RGBA8 } CKPixelKind;

static CKPixelKind CKPixelKindForTile(FxImageTile *tile) {
    // The Metal texture's format is the reliable description of what the host
    // put in the IOSurface (IOSurfaceGetPixelFormat can be 0 for host surfaces).
    id<MTLDevice> device = CKDeviceForRegistryID(tile.deviceRegistryID);
    id<MTLTexture> tex = device ? [tile metalTextureForDevice:device] : nil;
    switch (tex.pixelFormat) {
        case MTLPixelFormatRGBA16Float: return kCKPix_RGBAHalf;
        case MTLPixelFormatRGBA32Float: return kCKPix_RGBAFloat;
        case MTLPixelFormatBGRA8Unorm:  return kCKPix_BGRA8;
        case MTLPixelFormatRGBA8Unorm:  return kCKPix_RGBA8;
        default: break;
    }
    IOSurfaceRef s = (__bridge IOSurfaceRef)tile.ioSurface;
    switch (IOSurfaceGetBytesPerElement(s)) {
        case 8:  return kCKPix_RGBAHalf;
        case 16: return kCKPix_RGBAFloat;
        default: return kCKPix_Unknown;
    }
}

/// Copy an FxImageTile's pixels into a tight RGBA half-float buffer.
static CKHalfImage *CKReadTile(FxImageTile *tile, NSError **error) {
    if (tile.ioSurface == nil) {
        if (error) *error = CKFxError(kFxError_InvalidParameter, @"source tile has no IOSurface");
        return nil;
    }
    CKPixelKind kind = CKPixelKindForTile(tile);
    if (kind == kCKPix_Unknown) {
        if (error) *error = CKFxError(kFxError_InvalidParameter, @"unsupported source pixel format");
        return nil;
    }
    IOSurfaceRef s = (__bridge IOSurfaceRef)tile.ioSurface;
    size_t w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), bpr = IOSurfaceGetBytesPerRow(s);
    CKHalfImage *img = [[CKHalfImage alloc] initWithWidth:(NSInteger)w height:(NSInteger)h channels:4];
    uint8_t *dst = img.data.mutableBytes;

    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *base = IOSurfaceGetBaseAddress(s);
    if (kind == kCKPix_RGBAHalf) {
        for (size_t y = 0; y < h; y++) memcpy(dst + y * w * 8, base + y * bpr, w * 8);
    } else if (kind == kCKPix_RGBAFloat) {
        vImage_Buffer src = { (void *)base, h, w * 4, bpr };
        vImage_Buffer out = { dst, h, w * 4, w * 8 };
        vImageConvert_PlanarFtoPlanar16F(&src, &out, kvImageNoFlags);
    } else {
        // 8-bit: hosts shouldn't hand these to a linear-light effect, but cope.
        NSMutableData *f = [NSMutableData dataWithLength:w * h * 16];
        float *fp = f.mutableBytes;
        for (size_t y = 0; y < h; y++) {
            const uint8_t *row = base + y * bpr;
            for (size_t x = 0; x < w; x++) {
                const uint8_t *px = row + x * 4;
                float *o = fp + (y * w + x) * 4;
                if (kind == kCKPix_BGRA8) { o[0] = px[2]; o[1] = px[1]; o[2] = px[0]; }
                else                      { o[0] = px[0]; o[1] = px[1]; o[2] = px[2]; }
                o[3] = px[3];
                for (int c = 0; c < 4; c++) o[c] *= (1.0f / 255.0f);
            }
        }
        vImage_Buffer src = { fp, h, w * 4, w * 16 };
        vImage_Buffer out = { dst, h, w * 4, w * 8 };
        vImageConvert_PlanarFtoPlanar16F(&src, &out, kvImageNoFlags);
    }
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    return img;
}

/// RGBA half image -> float RGBA buffer.
static NSMutableData *CKToFloat(CKHalfImage *img) {
    NSMutableData *f = [NSMutableData dataWithLength:(NSUInteger)(img.width * img.height * img.channels * 4)];
    vImage_Buffer src = { (void *)img.data.bytes, (vImagePixelCount)img.height,
                          (vImagePixelCount)(img.width * img.channels), (size_t)(img.width * img.channels * 2) };
    vImage_Buffer dst = { f.mutableBytes, (vImagePixelCount)img.height,
                          (vImagePixelCount)(img.width * img.channels), (size_t)(img.width * img.channels * 4) };
    vImageConvert_Planar16FtoPlanarF(&src, &dst, kvImageNoFlags);
    return f;
}

static void CKFromFloat(const float *f, CKHalfImage *img) {
    vImage_Buffer src = { (void *)f, (vImagePixelCount)img.height,
                          (vImagePixelCount)(img.width * img.channels), (size_t)(img.width * img.channels * 4) };
    vImage_Buffer dst = { img.data.mutableBytes, (vImagePixelCount)img.height,
                          (vImagePixelCount)(img.width * img.channels), (size_t)(img.width * img.channels * 2) };
    vImageConvert_PlanarFtoPlanar16F(&src, &dst, kvImageNoFlags);
}

/// Single-channel hint matte from an RGBA image well frame.
static CKHalfImage *CKMatteFromImage(CKHalfImage *rgba, int channel) {
    NSMutableData *f = CKToFloat(rgba);
    const float *p = f.bytes;
    NSInteger n = rgba.width * rgba.height;
    NSMutableData *m = [NSMutableData dataWithLength:(NSUInteger)n * 4];
    float *mp = m.mutableBytes;
    for (NSInteger i = 0; i < n; i++) {
        const float *px = p + i * 4;
        float v = channel == 1 ? px[3] : (0.2126f * px[0] + 0.7152f * px[1] + 0.0722f * px[2]);
        mp[i] = v < 0.f ? 0.f : (v > 1.f ? 1.f : v);
    }
    CKHalfImage *out = [[CKHalfImage alloc] initWithWidth:rgba.width height:rgba.height channels:1];
    CKFromFloat(mp, out);
    return out;
}

/// Source frame with a red cast: what the effect shows when the server is down,
/// so a broken key can't be mistaken for a finished one.
static CKHalfImage *CKErrorImage(CKHalfImage *src) {
    NSMutableData *f = CKToFloat(src);
    float *p = f.mutableBytes;
    NSInteger n = src.width * src.height;
    for (NSInteger i = 0; i < n; i++) {
        float *px = p + i * 4;
        float l = 0.2126f * px[0] + 0.7152f * px[1] + 0.0722f * px[2];
        px[0] = 0.25f * l + 0.35f * px[3];
        px[1] = 0.25f * l;
        px[2] = 0.25f * l;
    }
    CKHalfImage *out = [[CKHalfImage alloc] initWithWidth:src.width height:src.height channels:4];
    CKFromFloat(p, out);
    return out;
}

/// Write an RGBA half image into the destination tile's IOSurface.
static BOOL CKWriteTile(FxImageTile *tile, CKHalfImage *img, NSError **error) {
    CKPixelKind kind = CKPixelKindForTile(tile);
    if (kind == kCKPix_Unknown || tile.ioSurface == nil) {
        if (error) *error = CKFxError(kFxError_InvalidParameter, @"unsupported destination pixel format");
        return NO;
    }
    IOSurfaceRef s = (__bridge IOSurfaceRef)tile.ioSurface;
    size_t w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), bpr = IOSurfaceGetBytesPerRow(s);
    size_t cw = MIN(w, (size_t)img.width), ch = MIN(h, (size_t)img.height);
    const uint8_t *src = img.data.bytes;

    IOSurfaceLock(s, 0, NULL);
    uint8_t *base = IOSurfaceGetBaseAddress(s);
    if (cw < w || ch < h) {
        for (size_t y = 0; y < h; y++) memset(base + y * bpr, 0, MIN(bpr, w * IOSurfaceGetBytesPerElement(s)));
    }
    if (kind == kCKPix_RGBAHalf) {
        for (size_t y = 0; y < ch; y++) memcpy(base + y * bpr, src + y * (size_t)img.width * 8, cw * 8);
    } else {
        NSMutableData *f = CKToFloat(img);
        const float *fp = f.bytes;
        if (kind == kCKPix_RGBAFloat) {
            for (size_t y = 0; y < ch; y++) memcpy(base + y * bpr, fp + y * (size_t)img.width * 4, cw * 16);
        } else {
            for (size_t y = 0; y < ch; y++) {
                uint8_t *row = base + y * bpr;
                for (size_t x = 0; x < cw; x++) {
                    const float *px = fp + (y * (size_t)img.width + x) * 4;
                    uint8_t q[4];
                    for (int c = 0; c < 4; c++) {
                        float v = px[c] * 255.0f + 0.5f;
                        q[c] = (uint8_t)(v < 0.f ? 0.f : (v > 255.f ? 255.f : v));
                    }
                    uint8_t *o = row + x * 4;
                    if (kind == kCKPix_BGRA8) { o[0] = q[2]; o[1] = q[1]; o[2] = q[0]; }
                    else                      { o[0] = q[0]; o[1] = q[1]; o[2] = q[2]; }
                    o[3] = q[3];
                }
            }
        }
    }
    IOSurfaceUnlock(s, 0, NULL);
    return YES;
}

static BOOL CKUnpackState(NSData *data, CKRenderState *st) {
    if (data.length != sizeof(CKRenderState)) return NO;
    memcpy(st, data.bytes, sizeof(CKRenderState));
    return st->magic == CK_STATE_MAGIC && st->version == CK_STATE_VERSION
        && st->frameCount >= 1 && st->frameCount <= CK_MAX_WINDOW
        && st->centerIndex >= 0 && st->centerIndex < st->frameCount
        && st->hintCount >= 0 && st->hintCount <= CK_MAX_WINDOW;
}

static BOOL CKTileIsUsable(FxImageTile *tile) {
    if (tile.ioSurface == nil) return NO;
    if ([tile respondsToSelector:@selector(requestError)] && [tile requestError] != nil) return NO;
    return YES;
}

#pragma mark - Plug-in

@implementation CKPlugIn

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager {
    if ((self = [super init])) {
        _apiManager = newApiManager;
    }
    return self;
}

- (BOOL)properties:(NSDictionary * _Nonnull *)properties error:(NSError * _Nullable *)error {
    *properties = @{
        // We pull neighbouring frames for temporal context.
        kFxPropertyKey_MayRemapTime: @YES,
        // The model needs the whole frame; it can't key tiles independently.
        kFxPropertyKey_NeedsFullBuffer: @YES,
        kFxPropertyKey_VariesWhenParamsAreStatic: @NO,
        kFxPropertyKey_ChangesOutputSize: @NO,
        // CorridorKey works in scene-linear light (and preserves HDR).
        kFxPropertyKey_DesiredProcessingColorInfo: @(kFxImageColorInfo_RGB_LINEAR),
    };
    return YES;
}

static BOOL CKParamFailed(NSError **error, NSString *what) {
    if (error) *error = CKFxError(kFxError_InvalidParameter, [@"Unable to add parameter: " stringByAppendingString:what]);
    return NO;
}

- (BOOL)addParametersWithError:(NSError **)error {
    id<FxParameterCreationAPI_v5> p = [_apiManager apiForProtocol:@protocol(FxParameterCreationAPI_v5)];
    if (p == nil) {
        if (error) *error = CKFxError(kFxError_APIUnavailable, @"FxParameterCreationAPI_v5 unavailable");
        return NO;
    }
    FxParameterFlags still = kFxParameterFlag_DEFAULT | kFxParameterFlag_NOT_ANIMATABLE;

    if (![p startParameterSubGroup:@"Key" parameterID:kCKGroup_Key parameterFlags:kFxParameterFlag_DEFAULT]) return CKParamFailed(error, @"Key group");
    if (![p addPopupMenuWithName:@"Output"
                         parameterID:kCKParam_Output
                        defaultValue:kCKOutput_Composite
                         menuEntries:@[@"Composite (Keyed)", @"Matte", @"Foreground", @"Orientation Check"]
                      parameterFlags:still]) return CKParamFailed(error, @"Output");
    if (![p addPopupMenuWithName:@"Temporal Window"
                         parameterID:kCKParam_Window
                        defaultValue:1
                         menuEntries:@[@"Off (1 frame)", @"5 frames", @"9 frames", @"17 frames"]
                      parameterFlags:still]) return CKParamFailed(error, @"Temporal Window");
    if (![p addFloatSliderWithName:@"Despill"
                           parameterID:kCKParam_Despill
                          defaultValue:0.5 parameterMin:0.0 parameterMax:1.0
                             sliderMin:0.0 sliderMax:1.0 delta:0.01
                        parameterFlags:kFxParameterFlag_DEFAULT]) return CKParamFailed(error, @"Despill");
    if (![p addFloatSliderWithName:@"Matte Black Point"
                           parameterID:kCKParam_ClipBlack
                          defaultValue:0.0 parameterMin:0.0 parameterMax:1.0
                             sliderMin:0.0 sliderMax:0.5 delta:0.005
                        parameterFlags:kFxParameterFlag_DEFAULT]) return CKParamFailed(error, @"Matte Black Point");
    if (![p addFloatSliderWithName:@"Matte White Point"
                           parameterID:kCKParam_ClipWhite
                          defaultValue:1.0 parameterMin:0.0 parameterMax:1.0
                             sliderMin:0.5 sliderMax:1.0 delta:0.005
                        parameterFlags:kFxParameterFlag_DEFAULT]) return CKParamFailed(error, @"Matte White Point");
    if (![p endParameterSubGroup]) return CKParamFailed(error, @"Key group end");

    if (![p startParameterSubGroup:@"Hint" parameterID:kCKGroup_Hint parameterFlags:kFxParameterFlag_COLLAPSED]) return CKParamFailed(error, @"Hint group");
    if (![p addPopupMenuWithName:@"Hint Mode"
                         parameterID:kCKParam_HintMode
                        defaultValue:kCKHint_None
                         menuEntries:@[@"None (model picks subject)", @"Matte Clip (every frame)", @"First Frame Only"]
                      parameterFlags:still]) return CKParamFailed(error, @"Hint Mode");
    if (![p addImageReferenceWithName:@"Hint Matte"
                              parameterID:kCKParam_HintImage
                           parameterFlags:kFxParameterFlag_DEFAULT]) return CKParamFailed(error, @"Hint Matte");
    if (![p addPopupMenuWithName:@"Hint Channel"
                         parameterID:kCKParam_HintChannel
                        defaultValue:0
                         menuEntries:@[@"Luminance", @"Alpha"]
                      parameterFlags:still]) return CKParamFailed(error, @"Hint Channel");
    if (![p addFloatSliderWithName:@"Hint Trust"
                           parameterID:kCKParam_HintQuality
                          defaultValue:0.95 parameterMin:0.0 parameterMax:1.0
                             sliderMin:0.0 sliderMax:1.0 delta:0.01
                        parameterFlags:still]) return CKParamFailed(error, @"Hint Trust");
    if (![p endParameterSubGroup]) return CKParamFailed(error, @"Hint group end");

    if (![p startParameterSubGroup:@"Advanced" parameterID:kCKGroup_Advanced parameterFlags:kFxParameterFlag_COLLAPSED]) return CKParamFailed(error, @"Advanced group");
    if (![p addToggleButtonWithName:@"Flip Vertical"
                            parameterID:kCKParam_FlipVertical
                           defaultValue:NO
                         parameterFlags:still]) return CKParamFailed(error, @"Flip Vertical");
    if (![p addIntSliderWithName:@"Server Port"
                         parameterID:kCKParam_Port
                        defaultValue:CK_DEFAULT_PORT parameterMin:1024 parameterMax:65535
                           sliderMin:47000 sliderMax:48000 delta:1
                      parameterFlags:still]) return CKParamFailed(error, @"Server Port");
    if (![p endParameterSubGroup]) return CKParamFailed(error, @"Advanced group end");
    return YES;
}

#pragma mark Plug-in state

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
    id<FxParameterRetrievalAPI_v6> params = [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxTimingAPI_v4> timing = [_apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
    if (params == nil || timing == nil) {
        if (error) *error = CKFxError(kFxError_APIUnavailable, @"FxParameterRetrievalAPI_v6/FxTimingAPI_v4 unavailable");
        return NO;
    }

    CKRenderState st;
    memset(&st, 0, sizeof st);
    st.magic = CK_STATE_MAGIC;
    st.version = CK_STATE_VERSION;

    int outputMode = 0, windowIndex = 1, hintMode = 0, hintChannel = 0, port = CK_DEFAULT_PORT;
    double despill = 0.5, clipBlack = 0.0, clipWhite = 1.0, hintQuality = 0.95;
    BOOL flip = NO;
    [params getIntValue:&outputMode fromParameter:kCKParam_Output atTime:renderTime];
    [params getIntValue:&windowIndex fromParameter:kCKParam_Window atTime:renderTime];
    [params getFloatValue:&despill fromParameter:kCKParam_Despill atTime:renderTime];
    [params getFloatValue:&clipBlack fromParameter:kCKParam_ClipBlack atTime:renderTime];
    [params getFloatValue:&clipWhite fromParameter:kCKParam_ClipWhite atTime:renderTime];
    [params getIntValue:&hintMode fromParameter:kCKParam_HintMode atTime:renderTime];
    [params getIntValue:&hintChannel fromParameter:kCKParam_HintChannel atTime:renderTime];
    [params getFloatValue:&hintQuality fromParameter:kCKParam_HintQuality atTime:renderTime];
    [params getBoolValue:&flip fromParameter:kCKParam_FlipVertical atTime:renderTime];
    [params getIntValue:&port fromParameter:kCKParam_Port atTime:renderTime];

    st.outputMode = outputMode;
    st.hintMode = hintMode;
    st.hintChannel = hintChannel;
    st.flipVertical = flip ? 1 : 0;
    st.port = (port >= 1024 && port <= 65535) ? port : CK_DEFAULT_PORT;
    st.despill = (float)despill;
    st.clipBlack = (float)clipBlack;
    st.clipWhite = (float)clipWhite;
    st.hintQuality = (float)hintQuality;

    id<FxColorGamutAPI_v2> gamut = [_apiManager apiForProtocol:@protocol(FxColorGamutAPI_v2)];
    st.gamutRec2020 = (gamut != nil && [gamut colorPrimaries] == kFxColorPrimaries_Rec2020) ? 1 : 0;

    // ---- Temporal window: which neighbouring frames to schedule -------------
    int32_t window = kCKWindowSizes[(windowIndex >= 0 && windowIndex < 4) ? windowIndex : 0];
    if (outputMode == kCKOutput_Orientation) window = 1;
    int32_t radius = (window - 1) / 2;

    CMTime fd = kCMTimeInvalid;
    [timing frameDuration:&fd];
    if (!CMTIME_IS_NUMERIC(fd) || CMTimeGetSeconds(fd) <= 0) {
        NSInteger num = (NSInteger)[timing timelineFpsNumeratorForEffect:self];
        NSInteger den = (NSInteger)[timing timelineFpsDenominatorForEffect:self];
        fd = (num > 0 && den > 0) ? CMTimeMake((int64_t)den, (int32_t)num) : CMTimeMake(1, 30);
    }
    CMTime start = kCMTimeInvalid, duration = kCMTimeInvalid;
    [timing startTimeOfInputToFilter:&start];
    [timing durationTimeOfInputToFilter:&duration];

    double fdSec = CMTimeGetSeconds(fd);
    int64_t current = 0, total = INT32_MAX;   // frame index of renderTime, frames in input
    BOOL haveRange = CMTIME_IS_NUMERIC(start) && CMTIME_IS_NUMERIC(duration) && CMTimeGetSeconds(duration) > 0;
    if (haveRange) {
        current = llround(CMTimeGetSeconds(CMTimeSubtract(renderTime, start)) / fdSec);
        total = MAX((int64_t)1, (int64_t)floor(CMTimeGetSeconds(duration) / fdSec + 1e-6));
        if (current < 0 || current >= total) haveRange = NO;   // don't trust a mismatched range
    }
    int64_t lo = current - radius, hi = current + radius;
    if (haveRange) {
        // Slide the window to stay inside the clip (like the CLI's last window).
        if (lo < 0) { hi = MIN(total - 1, hi - lo); lo = 0; }
        if (hi > total - 1) { lo = MAX((int64_t)0, lo - (hi - (total - 1))); hi = total - 1; }
    }
    st.frameCount = (int32_t)(hi - lo + 1);
    st.centerIndex = (int32_t)(current - lo);
    for (int32_t i = 0; i < st.frameCount; i++) {
        st.frameTimes[i] = CMTimeAdd(renderTime, CMTimeMultiply(fd, (int32_t)(lo + i - current)));
    }

    // ---- Hint frames ----------------------------------------------------------
    if (hintMode == kCKHint_EveryFrame) {
        st.hintCount = st.frameCount;
        for (int32_t i = 0; i < st.frameCount; i++) {
            st.hintFrameIndex[i] = i;
            st.hintTimes[i] = st.frameTimes[i];
        }
    } else if (hintMode == kCKHint_FirstFrame && haveRange && lo == 0) {
        // The first frame of the clip is in this window: give the model its matte.
        st.hintCount = 1;
        st.hintFrameIndex[0] = 0;
        st.hintTimes[0] = st.frameTimes[0];
    }

    *pluginState = [NSData dataWithBytes:&st length:sizeof st];
    return YES;
}

- (BOOL)scheduleInputs:(NSArray<FxImageTileRequest *> **)inputImageRequests
       withPluginState:(NSData *)pluginState
                atTime:(CMTime)renderTime
                 error:(NSError **)error {
    CKRenderState st;
    NSMutableArray<FxImageTileRequest *> *requests = [NSMutableArray array];
    if (!CKUnpackState(pluginState, &st)) {
        [requests addObject:[[FxImageTileRequest alloc] initWithSource:kFxImageTileRequestSourceEffectClip
                                                                  time:renderTime
                                                        includeFilters:YES
                                                           parameterID:0]];
    } else {
        for (int32_t i = 0; i < st.frameCount; i++) {
            [requests addObject:[[FxImageTileRequest alloc] initWithSource:kFxImageTileRequestSourceEffectClip
                                                                      time:st.frameTimes[i]
                                                            includeFilters:YES
                                                               parameterID:0]];
        }
        for (int32_t i = 0; i < st.hintCount; i++) {
            [requests addObject:[[FxImageTileRequest alloc] initWithSource:kFxImageTileRequestSourceParameter
                                                                      time:st.hintTimes[i]
                                                            includeFilters:YES
                                                               parameterID:kCKParam_HintImage]];
        }
    }
    *inputImageRequests = requests;
    return YES;
}

#pragma mark Bounds

- (BOOL)destinationImageRect:(FxRect *)destinationImageRect
                sourceImages:(NSArray<FxImageTile *> *)sourceImages
            destinationImage:(FxImageTile *)destinationImage
                 pluginState:(NSData *)pluginState
                      atTime:(CMTime)renderTime
                       error:(NSError **)outError {
    if (sourceImages.count < 1) {
        if (outError) *outError = CKFxError(kFxError_InvalidParameter, @"no source images");
        return NO;
    }
    *destinationImageRect = sourceImages[0].imagePixelBounds;
    return YES;
}

- (BOOL)sourceTileRect:(FxRect *)sourceTileRect
      sourceImageIndex:(NSUInteger)sourceImageIndex
          sourceImages:(NSArray<FxImageTile *> *)sourceImages
   destinationTileRect:(FxRect)destinationTileRect
      destinationImage:(FxImageTile *)destinationImage
           pluginState:(NSData *)pluginState
                atTime:(CMTime)renderTime
                 error:(NSError **)outError {
    // Every output pixel depends on the whole frame (and its neighbours).
    if (sourceImageIndex < sourceImages.count) {
        *sourceTileRect = sourceImages[sourceImageIndex].imagePixelBounds;
    } else {
        *sourceTileRect = destinationTileRect;
    }
    return YES;
}

#pragma mark Render

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError **)outError {
    CKRenderState st;
    if (!CKUnpackState(pluginState, &st)) {
        if (outError) *outError = CKFxError(kFxError_InvalidParameter, @"invalid plug-in state");
        return NO;
    }
    if (destinationImage.ioSurface == nil) {
        if (outError) *outError = CKFxError(kFxError_InvalidParameter, @"destination has no IOSurface");
        return NO;
    }

    // Split the scheduled inputs back into clip frames and hint frames.
    NSMutableArray<FxImageTile *> *clipTiles = [NSMutableArray array];
    NSMutableArray<FxImageTile *> *hintTiles = [NSMutableArray array];
    for (FxImageTile *tile in sourceImages) {
        if (tile.parameterID == kCKParam_HintImage) [hintTiles addObject:tile];
        else [clipTiles addObject:tile];
    }
    if (clipTiles.count == 0) {
        if (outError) *outError = CKFxError(kFxError_InvalidParameter, @"no effect source frames");
        return NO;
    }
    NSInteger center = st.centerIndex;
    if ((NSInteger)clipTiles.count != st.frameCount) {
        // Host didn't honour the schedule (e.g. thumbnails): key the current frame alone.
        NSLog(@"[CorridorKey] expected %d source frames, got %lu; using a single frame",
              st.frameCount, (unsigned long)clipTiles.count);
        center = clipTiles.count == 1 ? 0 : MIN(center, (NSInteger)clipTiles.count - 1);
        hintTiles = [NSMutableArray array];
        clipTiles = [NSMutableArray arrayWithObject:clipTiles[(NSUInteger)center]];
        center = 0;
        st.hintCount = 0;
    }
    if (!CKTileIsUsable(clipTiles[(NSUInteger)center])) {
        if (outError) *outError = CKFxError(kFxError_InvalidParameter, @"current source frame unavailable");
        return NO;
    }

    NSError *readError = nil;
    CKHalfImage *centerImage = CKReadTile(clipTiles[(NSUInteger)center], &readError);
    if (centerImage == nil) {
        if (outError) *outError = readError;
        return NO;
    }

    // Read neighbours; drop any that are missing or a different size.
    NSMutableArray<CKHalfImage *> *frames = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, NSNumber *> *windowToFrame = [NSMutableDictionary dictionary];
    NSInteger newCenter = 0;
    for (NSUInteger i = 0; i < clipTiles.count; i++) {
        CKHalfImage *img = nil;
        if ((NSInteger)i == center) {
            img = centerImage;
            newCenter = (NSInteger)frames.count;
        } else if (CKTileIsUsable(clipTiles[i])) {
            img = CKReadTile(clipTiles[i], NULL);
            if (img && (img.width != centerImage.width || img.height != centerImage.height)) img = nil;
        }
        if (img) {
            windowToFrame[@(i)] = @(frames.count);
            [frames addObject:img];
        }
    }

    NSMutableDictionary<NSNumber *, CKHalfImage *> *hints = [NSMutableDictionary dictionary];
    if ((NSInteger)hintTiles.count == st.hintCount) {
        for (NSUInteger k = 0; k < hintTiles.count; k++) {
            NSNumber *frameIdx = windowToFrame[@(st.hintFrameIndex[k])];
            if (frameIdx == nil || !CKTileIsUsable(hintTiles[k])) continue;
            CKHalfImage *rgba = CKReadTile(hintTiles[k], NULL);
            if (rgba) hints[frameIdx] = CKMatteFromImage(rgba, st.hintChannel);
        }
    }

    static NSString *const outputNames[] = { @"composite", @"matte", @"foreground", @"orientation" };
    NSDictionary *params = @{
        @"output": outputNames[(st.outputMode >= 0 && st.outputMode < 4) ? st.outputMode : 0],
        @"despill": @(st.despill),
        @"hint_quality": @(st.hintQuality),
        @"gamut": st.gamutRec2020 ? @"rec2020" : @"rec709",
        @"flip_vertical": @(st.flipVertical != 0),
        @"matte_clip_black": @(st.clipBlack),
        @"matte_clip_white": @(st.clipWhite),
    };

    NSError *keyError = nil;
    CKHalfImage *result = [CKClient keyFrames:frames center:newCenter hints:hints
                                       params:params port:st.port error:&keyError];
    if (result == nil) {
        // Keep the timeline usable: show a red-tinted frame instead of failing the render.
        NSLog(@"[CorridorKey] keying failed: %@", keyError.localizedDescription);
        result = CKErrorImage(centerImage);
    }
    return CKWriteTile(destinationImage, result, outError);
}

@end
