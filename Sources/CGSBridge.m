#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef union
{
    uint8_t rawData[0xDC];
    struct
    {
        uint32_t mode;
        uint32_t flags;
        uint32_t width;
        uint32_t height;
        uint32_t depth;
        uint32_t dc2[42];
        uint16_t dc3;
        uint16_t freq;
        uint32_t dc4[4];
        float density;
    } derived;
} modes_D4;

extern void CGSGetCurrentDisplayMode(CGDirectDisplayID display, int* modeNum);
extern void CGSGetNumberOfDisplayModes(CGDirectDisplayID display, int* nModes);
extern void CGSGetDisplayModeDescriptionOfLength(CGDirectDisplayID display, int idx, modes_D4* mode, int length);
extern void CGSConfigureDisplayMode(CGDisplayConfigRef config, CGDirectDisplayID display, int modeNum);

@interface CGSModeItem : NSObject
@property (nonatomic) int modeID;
@property (nonatomic) uint32_t width;
@property (nonatomic) uint32_t height;
@property (nonatomic) uint16_t freq;
@property (nonatomic) float density;
@property (nonatomic) BOOL isHiDPI;
@end

@implementation CGSModeItem
@end

@interface CGSBridge : NSObject
+ (int)currentModeIDForDisplay:(CGDirectDisplayID)displayID;
+ (NSArray<CGSModeItem *> *)allModesForDisplay:(CGDirectDisplayID)displayID;
+ (BOOL)setDisplayMode:(int)modeID forDisplay:(CGDirectDisplayID)displayID;
@end

@implementation CGSBridge

+ (int)currentModeIDForDisplay:(CGDirectDisplayID)displayID {
    int cur = -1;
    CGSGetCurrentDisplayMode(displayID, &cur);
    return cur;
}

+ (NSArray<CGSModeItem *> *)allModesForDisplay:(CGDirectDisplayID)displayID {
    int count = 0;
    CGSGetNumberOfDisplayModes(displayID, &count);
    NSMutableArray *result = [NSMutableArray array];

    modes_D4 modeInfo;
    for (int i = 0; i < count; i++) {
        memset(&modeInfo, 0, sizeof(modeInfo));
        CGSGetDisplayModeDescriptionOfLength(displayID, i, &modeInfo, 0xD4);
        
        CGSModeItem *item = [[CGSModeItem alloc] init];
        item.modeID = modeInfo.derived.mode;
        item.width = modeInfo.derived.width;
        item.height = modeInfo.derived.height;
        item.freq = modeInfo.derived.freq;
        item.density = modeInfo.derived.density;
        item.isHiDPI = (modeInfo.derived.density >= 1.5f);
        [result addObject:item];
    }
    return result;
}

+ (BOOL)setDisplayMode:(int)modeID forDisplay:(CGDirectDisplayID)displayID {
    CGDisplayConfigRef cfg;
    if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess) {
        return NO;
    }
    CGSConfigureDisplayMode(cfg, displayID, modeID);
    CGError err = CGCompleteDisplayConfiguration(cfg, kCGConfigurePermanently);
    return (err == kCGErrorSuccess);
}

@end
