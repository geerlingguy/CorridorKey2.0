//
//  CKPlugIn.h
//  CorridorKey FxPlug
//
//  FxPlug 4 filter that keys the clip it is applied to with CorridorKey 2.0.
//  The heavy lifting happens in ck_server.py (PyTorch on Apple Silicon via
//  MPS); this class gathers parameters, schedules a temporal window of input
//  frames, ships them to the server and writes the result back.
//

#import <Foundation/Foundation.h>
#import <FxPlug/FxPlugSDK.h>

@interface CKPlugIn : NSObject <FxTileableEffect>
@property (assign) id<PROAPIAccessing> apiManager;
@end
