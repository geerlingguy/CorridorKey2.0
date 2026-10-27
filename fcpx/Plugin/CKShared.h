//
//  CKShared.h
//  CorridorKey FxPlug
//
//  Parameter IDs and the plug-in state blob that travels from
//  -pluginState:atTime:quality:error: to -scheduleInputs: and -render...
//
//  Parameter IDs are stored in saved FCP/Motion projects, so never renumber
//  them. Add new ones with new IDs instead.
//

#ifndef CKShared_h
#define CKShared_h

#import <CoreMedia/CoreMedia.h>

enum {
    // "Key" group
    kCKGroup_Key            = 100,
    kCKParam_Output         = 1,    // popup: Composite / Matte / Foreground / Orientation Check
    kCKParam_Window         = 2,    // popup: temporal window size
    kCKParam_Despill        = 3,    // float 0..1
    kCKParam_ClipBlack      = 4,    // float 0..1
    kCKParam_ClipWhite      = 5,    // float 0..1

    // "Hint" group
    kCKGroup_Hint           = 200,
    kCKParam_HintMode       = 11,   // popup: None / Matte Clip (every frame) / First Frame Only
    kCKParam_HintImage      = 12,   // image well
    kCKParam_HintChannel    = 13,   // popup: Luminance / Alpha
    kCKParam_HintQuality    = 14,   // float 0..1

    // "Advanced" group
    kCKGroup_Advanced       = 300,
    kCKParam_FlipVertical   = 21,   // toggle
    kCKParam_Port           = 22,   // int
};

typedef enum : int32_t {
    kCKOutput_Composite = 0,
    kCKOutput_Matte = 1,
    kCKOutput_Foreground = 2,
    kCKOutput_Orientation = 3,
} CKOutputMode;

typedef enum : int32_t {
    kCKHint_None = 0,
    kCKHint_EveryFrame = 1,
    kCKHint_FirstFrame = 2,
} CKHintMode;

#define CK_MAX_WINDOW 17
#define CK_STATE_MAGIC 0x434B5354u   // 'CKST'
#define CK_STATE_VERSION 1
#define CK_DEFAULT_PORT 47823

// Plain-old-data so it can be memcpy'd into NSData. Both ends are the same
// binary (the XPC service), so layout/endianness always match.
typedef struct {
    uint32_t magic;
    uint32_t version;

    int32_t  outputMode;          // CKOutputMode
    int32_t  frameCount;          // number of effect-clip frames scheduled (>= 1)
    int32_t  centerIndex;         // which of those is the frame being rendered
    int32_t  hintMode;            // CKHintMode
    int32_t  hintChannel;         // 0 = luminance, 1 = alpha
    int32_t  hintCount;           // number of hint-well frames scheduled
    int32_t  hintFrameIndex[CK_MAX_WINDOW];  // window index each hint frame belongs to
    int32_t  flipVertical;
    int32_t  gamutRec2020;
    int32_t  port;

    float    despill;
    float    clipBlack;
    float    clipWhite;
    float    hintQuality;

    CMTime   frameTimes[CK_MAX_WINDOW];      // effect-clip times, oldest first
    CMTime   hintTimes[CK_MAX_WINDOW];
} CKRenderState;

#endif /* CKShared_h */
