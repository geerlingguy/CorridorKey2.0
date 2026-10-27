//
//  CKClient.m
//  CorridorKey FxPlug
//

#import "CKClient.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

static NSString *const CKErrorDomain = @"CorridorKey";

static NSError *CKError(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static NSError *CKError(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    return [NSError errorWithDomain:CKErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: msg}];
}

#pragma mark - Hashing

static inline uint64_t ck_rotl(uint64_t x, int r) { return (x << r) | (x >> (64 - r)); }

/// Fast 64-bit content hash (xxHash64-style rounds, two lanes). Only needs to
/// tell frames apart for cache lookups, not resist adversaries.
static uint64_t CKHash64(const uint8_t *p, size_t n, uint64_t seed) {
    const uint64_t P1 = 0x9E3779B185EBCA87ULL, P2 = 0xC2B2AE3D27D4EB4FULL, P3 = 0x165667B19E3779F9ULL;
    uint64_t a = seed + P1 + P2, b = seed + P2, c = seed, d = seed - P1;
    size_t i = 0;
    for (; i + 32 <= n; i += 32) {
        uint64_t w0, w1, w2, w3;
        memcpy(&w0, p + i, 8); memcpy(&w1, p + i + 8, 8);
        memcpy(&w2, p + i + 16, 8); memcpy(&w3, p + i + 24, 8);
        a = ck_rotl(a + w0 * P2, 31) * P1;
        b = ck_rotl(b + w1 * P2, 31) * P1;
        c = ck_rotl(c + w2 * P2, 31) * P1;
        d = ck_rotl(d + w3 * P2, 31) * P1;
    }
    uint64_t h = ck_rotl(a, 1) + ck_rotl(b, 7) + ck_rotl(c, 12) + ck_rotl(d, 18) + (uint64_t)n;
    for (; i < n; i++) {
        h ^= p[i] * P3;
        h = ck_rotl(h, 11) * P1;
    }
    h ^= h >> 33; h *= P2; h ^= h >> 29; h *= P3; h ^= h >> 32;
    return h;
}

@implementation CKHalfImage {
    NSString *_hash;
}

- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height channels:(NSInteger)channels {
    if ((self = [super init])) {
        _width = width;
        _height = height;
        _channels = channels;
        _data = [NSMutableData dataWithLength:(NSUInteger)(width * height * channels * 2)];
    }
    return self;
}

- (void)updateHashWithPrefix:(NSString *)prefix {
    uint64_t seed = ((uint64_t)_width << 40) ^ ((uint64_t)_height << 16) ^ (uint64_t)_channels;
    uint64_t h = CKHash64(_data.bytes, _data.length, seed);
    _hash = [NSString stringWithFormat:@"%@%016llx", prefix, (unsigned long long)h];
}

- (NSString *)contentHash {
    if (_hash == nil) {
        [self updateHashWithPrefix:@"f"];
    }
    return _hash;
}

@end

#pragma mark - Socket helpers

static BOOL CKSendAll(int fd, const void *buf, size_t len, NSError **error) {
    const uint8_t *p = buf;
    while (len > 0) {
        ssize_t k = send(fd, p, len, 0);
        if (k < 0) {
            if (errno == EINTR) continue;
            if (error) *error = CKError(@"send failed: %s", strerror(errno));
            return NO;
        }
        p += k;
        len -= (size_t)k;
    }
    return YES;
}

static BOOL CKRecvAll(int fd, void *buf, size_t len, NSError **error) {
    uint8_t *p = buf;
    while (len > 0) {
        ssize_t k = recv(fd, p, len, 0);
        if (k == 0) {
            if (error) *error = CKError(@"CorridorKey server closed the connection");
            return NO;
        }
        if (k < 0) {
            if (errno == EINTR) continue;
            if (error) *error = CKError(@"recv failed: %s%@", strerror(errno),
                                        errno == EAGAIN ? @" (timed out)" : @"");
            return NO;
        }
        p += k;
        len -= (size_t)k;
    }
    return YES;
}

static BOOL CKSendJSON(int fd, NSDictionary *obj, NSError **error) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:obj options:0 error:error];
    if (json == nil) return NO;
    uint32_t n = OSSwapHostToLittleInt32((uint32_t)json.length);
    return CKSendAll(fd, &n, 4, error) && CKSendAll(fd, json.bytes, json.length, error);
}

static NSDictionary *CKRecvJSON(int fd, NSError **error) {
    uint32_t n = 0;
    if (!CKRecvAll(fd, &n, 4, error)) return nil;
    n = OSSwapLittleToHostInt32(n);
    if (n > (1u << 20)) {
        if (error) *error = CKError(@"bad reply length %u", n);
        return nil;
    }
    NSMutableData *buf = [NSMutableData dataWithLength:n];
    if (!CKRecvAll(fd, buf.mutableBytes, n, error)) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:buf options:0 error:error];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        if (error && *error == nil) *error = CKError(@"malformed reply from server");
        return nil;
    }
    return obj;
}

static int CKConnect(int port, double timeoutSeconds, NSError **error) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error) *error = CKError(@"socket() failed: %s", strerror(errno));
        return -1;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    int bufsize = 8 << 20;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufsize, sizeof bufsize);
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufsize, sizeof bufsize);
    struct timeval tv = { .tv_sec = (time_t)timeoutSeconds, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_len = sizeof addr;
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        if (error) *error = CKError(@"CorridorKey server not reachable on 127.0.0.1:%d (%s). "
                                    @"Open the CorridorKey app and start the server.", port, strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

@implementation CKClient

+ (NSDictionary *)pingPort:(int)port timeout:(double)seconds {
    int fd = CKConnect(port, seconds, NULL);
    if (fd < 0) return nil;
    NSDictionary *reply = nil;
    if (CKSendJSON(fd, @{@"op": @"ping"}, NULL)) {
        reply = CKRecvJSON(fd, NULL);
    }
    close(fd);
    return reply;
}

+ (CKHalfImage *)keyFrames:(NSArray<CKHalfImage *> *)frames
                    center:(NSInteger)center
                     hints:(NSDictionary<NSNumber *, CKHalfImage *> *)hints
                    params:(NSDictionary *)params
                      port:(int)port
                     error:(NSError **)error {
    if (frames.count == 0 || center < 0 || center >= (NSInteger)frames.count) {
        if (error) *error = CKError(@"bad frame window");
        return nil;
    }
    CKHalfImage *ref = frames[(NSUInteger)center];

    NSMutableDictionary<NSString *, CKHalfImage *> *blobs = [NSMutableDictionary dictionary];
    NSMutableArray *frameHashes = [NSMutableArray arrayWithCapacity:frames.count];
    for (CKHalfImage *f in frames) {
        [frameHashes addObject:f.contentHash];
        blobs[f.contentHash] = f;
    }
    NSMutableDictionary *hintJSON = [NSMutableDictionary dictionary];
    [hints enumerateKeysAndObjectsUsingBlock:^(NSNumber *idx, CKHalfImage *m, BOOL *stop) {
        [m updateHashWithPrefix:@"m"];   // keep matte and frame hashes disjoint
        blobs[m.contentHash] = m;
        hintJSON[idx.stringValue] = @{@"hash": m.contentHash, @"w": @(m.width), @"h": @(m.height)};
    }];

    // Generous timeout: first use loads ~5 GB of weights, and big windows at
    // 4K take a while per frame.
    int fd = CKConnect(port, 900.0, error);
    if (fd < 0) return nil;

    CKHalfImage *result = nil;
    @try {
        NSDictionary *req = @{@"op": @"key", @"w": @(ref.width), @"h": @(ref.height),
                              @"frames": frameHashes, @"center": @(center),
                              @"hints": hintJSON, @"params": params};
        if (!CKSendJSON(fd, req, error)) return nil;
        NSDictionary *need = CKRecvJSON(fd, error);
        if (need == nil) return nil;
        if (need[@"need"] == nil) {
            if (error) *error = CKError(@"server error: %@", need[@"error"] ?: need);
            return nil;
        }
        for (NSString *h in need[@"need"]) {
            CKHalfImage *blob = blobs[h];
            if (blob == nil) {
                if (error) *error = CKError(@"server asked for unknown blob %@", h);
                return nil;
            }
            if (!CKSendAll(fd, blob.data.bytes, blob.data.length, error)) return nil;
        }
        NSDictionary *reply = CKRecvJSON(fd, error);
        if (reply == nil) return nil;
        if (![reply[@"ok"] boolValue]) {
            if (error) *error = CKError(@"CorridorKey server: %@", reply[@"error"] ?: @"unknown error");
            return nil;
        }
        NSInteger w = [reply[@"w"] integerValue], h = [reply[@"h"] integerValue];
        NSUInteger bytes = [reply[@"bytes"] unsignedIntegerValue];
        if (w != ref.width || h != ref.height || bytes != (NSUInteger)(w * h * 4 * 2)) {
            if (error) *error = CKError(@"unexpected reply size %ldx%ld (%lu bytes)", (long)w, (long)h, (unsigned long)bytes);
            return nil;
        }
        CKHalfImage *out = [[CKHalfImage alloc] initWithWidth:w height:h channels:4];
        if (!CKRecvAll(fd, out.data.mutableBytes, bytes, error)) return nil;
        result = out;
    } @finally {
        close(fd);
    }
    return result;
}

@end
