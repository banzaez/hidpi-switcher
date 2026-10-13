#import "CGSBridge.h"

// Приватная структура описания режима CGS. Поле `density` лежит по смещению 208
// и заканчивается ровно на 0xD4 (212) байтах — именно эта длина запрашивается у CGS.
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

static const int kCGSModeDescriptionLength = 0xD4;

extern void CGSGetCurrentDisplayMode(CGDirectDisplayID display, int* modeNum);
extern void CGSGetNumberOfDisplayModes(CGDirectDisplayID display, int* nModes);
extern void CGSGetDisplayModeDescriptionOfLength(CGDirectDisplayID display, int idx, modes_D4* mode, int length);
extern void CGSConfigureDisplayMode(CGDisplayConfigRef config, CGDirectDisplayID display, int modeNum);

@implementation CGSModeItem
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
    if (count <= 0) {
        return @[];
    }
    NSMutableArray<CGSModeItem *> *result = [NSMutableArray arrayWithCapacity:(NSUInteger)count];

    modes_D4 modeInfo;
    for (int i = 0; i < count; i++) {
        memset(&modeInfo, 0, sizeof(modeInfo));
        CGSGetDisplayModeDescriptionOfLength(displayID, i, &modeInfo, kCGSModeDescriptionLength);

        CGSModeItem *item = [[CGSModeItem alloc] init];
        item.modeID = (int)modeInfo.derived.mode;
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
    CGDisplayConfigRef cfg = NULL;
    if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess) {
        return NO;
    }
    CGSConfigureDisplayMode(cfg, displayID, modeID);
    // Только на время сессии: неудачный режим не переживёт перезагрузку.
    CGError err = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(cfg);
        return NO;
    }
    return YES;
}

@end
