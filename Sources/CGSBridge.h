#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CGSModeItem : NSObject
@property (nonatomic) int modeID;
@property (nonatomic) uint32_t width;
@property (nonatomic) uint32_t height;
@property (nonatomic) uint16_t freq;
@property (nonatomic) float density;
@property (nonatomic) BOOL isHiDPI;
@end

@interface CGSBridge : NSObject
+ (int)currentModeIDForDisplay:(CGDirectDisplayID)displayID;
+ (NSArray<CGSModeItem *> *)allModesForDisplay:(CGDirectDisplayID)displayID;
+ (BOOL)setDisplayMode:(int)modeID forDisplay:(CGDirectDisplayID)displayID;
@end
