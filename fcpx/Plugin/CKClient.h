//
//  CKClient.h
//  CorridorKey FxPlug
//
//  Talks to ck_server.py over localhost TCP. See the protocol description at
//  the top of ck_server.py.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A tightly packed image: `width * height * channels` IEEE half floats,
/// rows top to bottom as they sit in the host's IOSurface.
@interface CKHalfImage : NSObject
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
@property (nonatomic, readonly) NSInteger channels;
@property (nonatomic, readonly) NSMutableData *data;
@property (nonatomic, readonly) NSString *contentHash;   // 64-bit content hash, hex
- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height channels:(NSInteger)channels;
- (void)updateHashWithPrefix:(NSString *)prefix;
@end

@interface CKClient : NSObject

/// Synchronous round trip. `hints` maps window index (NSNumber) -> single-channel CKHalfImage.
/// Returns the RGBA half-float result (same size as the center frame) or nil with `error` set.
+ (nullable CKHalfImage *)keyFrames:(NSArray<CKHalfImage *> *)frames
                             center:(NSInteger)center
                              hints:(NSDictionary<NSNumber *, CKHalfImage *> *)hints
                             params:(NSDictionary *)params
                               port:(int)port
                              error:(NSError **)error;

/// Quick health check: returns the server's ping reply, or nil if unreachable.
+ (nullable NSDictionary *)pingPort:(int)port timeout:(double)seconds;

@end

NS_ASSUME_NONNULL_END
