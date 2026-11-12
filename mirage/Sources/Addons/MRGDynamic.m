// Dynamic colors: a palette from the current cover, cached per track, blended into Mirage's accent,
// toggles and Vitrine's glass. The previous color stays up until the new one is ready, then fades to it.
// 0.6.7: the cover's vibrant color (else its dominant one) from MRGPalette, lifted to read on black; a 32x32
// downsample off the main thread, once per track.
#import "Addons/MRGAddon.h"
#import "Addons/MRGThemes.h"
#import "Addons/MRGPalette.h"
#import "MRGAddons.h"
#import "MRGPlayer.h"
#import "MRGPrefs.h"
#import "MRGDJLog.h"
#import <objc/runtime.h>

static NSString *const kAddon = @"dynamic-colors";
static NSInteger sColor = -1;
static NSString *sTrack;
static NSCache *sMemory;
static NSMutableDictionary *sDisk;
static BOOL sDiskDirty;

static NSInteger baseRGB(void) {
    NSInteger theme = -1;
    NSDictionary *applied = MRGAppliedTheme();
    if (applied) {
        NSString *hex = applied[@"accent"];
        if ([hex isKindOfClass:NSString.class]) {
            NSScanner *scanner = [NSScanner scannerWithString:[hex hasPrefix:@"#"] ? [hex substringFromIndex:1] : hex];
            unsigned int rgb = 0;
            if ([scanner scanHexInt:&rgb]) theme = rgb;
        }
    }
    if (theme >= 0) return theme;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL redesign = [d boolForKey:@"spotifyglass.redesign"];
    if (@available(iOS 26.0, *)) {}
    else redesign = redesign && [d boolForKey:@"spotifyglass.redesign.untested"];
    id v = [d objectForKey:redesign ? @"spotifyglass.redesign.accent" : @"spotifyglass.accent"];
    NSInteger rgb = [v isKindOfClass:NSNumber.class] ? [v integerValue] : (redesign ? 0x37F200 : 0x1ED760);
    return (rgb < 0 || rgb > 0xFFFFFF) ? 0x1ED760 : rgb;
}

static NSInteger blend(NSInteger from, NSInteger to, double t) {
    t = MIN(1, MAX(0, t));
    NSInteger out = 0;
    for (int shift = 16; shift >= 0; shift -= 8) {
        double a = (from >> shift) & 255, b = (to >> shift) & 255;
        out |= (NSInteger)lround(a + (b - a) * t) << shift;
    }
    return out;
}

static double strength(void) { return MIN(1, MAX(0, MRGAddonNumber(kAddon, @"strength", 0.75))); }
static NSInteger fallbackRGB(void) { return MRGAddonInteger(kAddon, @"fallback", 0x1ED760) & 0xFFFFFF; }
static BOOL element(NSString *key) { return MRGAddonFlag(kAddon, key, YES); }

static NSInteger blended(NSInteger extracted) {
    NSInteger color = extracted >= 0 ? extracted : fallbackRGB();
    return blend(baseRGB(), color, strength());
}

static NSURL *cacheFile(void) {
    NSURL *lib = [NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [lib URLByAppendingPathComponent:@"Mirage" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:@"dynamic-colors-2.plist"];   // 0.6.7: new palette, new cache
}

static void loadDisk(void) {
    if (sDisk) return;
    id obj = [NSDictionary dictionaryWithContentsOfURL:cacheFile()];
    sDisk = [obj isKindOfClass:NSDictionary.class] ? [obj mutableCopy] : [NSMutableDictionary dictionary];
}

static void saveDiskSoon(void) {
    if (sDiskDirty) return;
    sDiskDirty = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        sDiskDirty = NO;
        loadDisk();
        NSDictionary *snapshot = [sDisk copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [snapshot writeToURL:cacheFile() atomically:YES]; });
    });
}

static NSInteger cached(NSString *uri) {
    if (!sMemory) sMemory = [NSCache new];
    NSNumber *hit = [sMemory objectForKey:uri];
    if (hit) return hit.integerValue;
    loadDisk();
    NSNumber *disk = sDisk[uri];
    if ([disk isKindOfClass:NSNumber.class]) {
        [sMemory setObject:disk forKey:uri];
        return disk.integerValue;
    }
    return -1;
}

static void store(NSString *uri, NSInteger rgb) {
    if (!sMemory) sMemory = [NSCache new];
    [sMemory setObject:@(rgb) forKey:uri];
    loadDisk();
    sDisk[uri] = @(rgb);
    while (sDisk.count > 100) [sDisk removeObjectForKey:sDisk.allKeys.firstObject];
    saveDiskSoon();
}

static NSInteger paletteFrom(UIImage *image) {
    if (!image) return -1;
    return MRGPaletteAccent(MRGPaletteFromImage(image));
}

static UIImage *coverOnScreen(void) {
    __block UIImage *best = nil;
    __block CGFloat area = 0;
    void (^walk)(UIView *) = ^(UIView *root) {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        NSUInteger seen = 0;
        while (stack.count && seen < 2500) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            seen++;
            if ([view isKindOfClass:UIImageView.class]) {
                UIImage *image = ((UIImageView *)view).image;
                CGFloat w = view.bounds.size.width * view.bounds.size.height;
                if (image && view.bounds.size.width >= 80 && w > area) { best = image; area = w; }
            }
            [stack addObjectsFromArray:view.subviews];
        }
    };
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) walk(window);
    }
    return best;
}

// A new color fades in over about 0.4s (four repaints), not in one jump; at once in Low Power Mode, with Reduce
// Motion, or the first time.
static NSUInteger sFade;
static void applyColor(NSInteger extracted, NSString *uri) {
    NSInteger next = blended(extracted);
    NSInteger from = sColor;
    sTrack = [uri copy];
    if (next == from) return;
    NSUInteger fade = ++sFade;
    if (from < 0 || NSProcessInfo.processInfo.isLowPowerModeEnabled || UIAccessibilityIsReduceMotionEnabled()) {
        sColor = next;
        if (MRGAddonInstalled(kAddon)) MRGLookRefresh();
        return;
    }
    for (int step = 1; step <= 4; step++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((step - 1) * 0.11 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (fade != sFade || !MRGAddonInstalled(kAddon)) return;
            sColor = step == 4 ? next : blend(from, next, step / 4.0);
            MRGLookRefresh();
        });
    }
}

static void resolve(NSDictionary *now) {
    if (!MRGAddonInstalled(kAddon) || [now[@"ad"] boolValue]) return;
    NSString *uri = now[@"uri"];
    if (!uri.length) return;
    if ([uri isEqualToString:sTrack] && sColor >= 0) return;
    NSInteger hit = cached(uri);
    if (hit >= 0) { applyColor(hit, uri); return; }
    // Keep the color that's already on screen until this track's own color is ready.
    sTrack = [uri copy];
    NSString *urlString = now[@"image"];
    NSURL *url = [urlString hasPrefix:@"https://"] ? [NSURL URLWithString:urlString] : nil;
    if (!url) {
        UIImage *local = coverOnScreen();
        if (!local) { applyColor(-1, uri); return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSInteger rgb = -1;
            @try { rgb = paletteFrom(local); } @catch (NSException *e) {}
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![uri isEqualToString:sTrack]) return;
                if (rgb >= 0) store(uri, rgb);
                applyColor(rgb, uri);
            });
        });
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 10;
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSInteger rgb = -1;
        @try { rgb = paletteFrom(data.length ? [UIImage imageWithData:data] : nil); } @catch (NSException *e) {}
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![uri isEqualToString:sTrack]) return;
            if (rgb >= 0) store(uri, rgb);
            applyColor(rgb, uri);
        });
    }] resume];
}

static NSInteger channel(NSString *key) {
    if (!MRGAddonInstalled(kAddon) || !MRGThemeAllowsDynamicColors() || !element(key) || sColor < 0) return -1;
    return sColor;
}

@interface MRGDynamicAddon : NSObject <MRGAddon>
@end
@implementation MRGDynamicAddon
- (NSString *)addonID { return kAddon; }
- (NSString *)addonName { return @"Dynamic colors"; }
- (NSString *)addonCategory { return @"Look"; }
- (NSString *)addonVersion { return @"1.0"; }
- (NSString *)addonDescription { return @"Tints Mirage's accent and Vitrine's glass from the album cover."; }
- (NSInteger)addonBatteryImpact { return 0; }
- (NSString *)addonBatteryNote { return @"Low: reads one cover and repaints once per song."; }
- (NSArray<MRGAddonSetting *> *)addonSettings {
    MRGAddonSetting *strengthRow = [MRGAddonSetting slider:@"strength" title:@"Strength" min:0 max:1 fallback:0.75];
    strengthRow.footer = nil;
    MRGAddonSetting *accent = [MRGAddonSetting toggle:@"accent" title:@"Accent" fallback:YES];
    MRGAddonSetting *toggles = [MRGAddonSetting toggle:@"toggles" title:@"Toggles" fallback:YES];
    MRGAddonSetting *glass = [MRGAddonSetting toggle:@"glass" title:@"Vitrine's glass" fallback:YES];
    glass.footer = nil;
    MRGAddonSetting *fallback = [MRGAddonSetting color:@"fallback" title:@"Fallback" fallbackRGB:0x1ED760];
    fallback.footer = @"Used when the cover has no usable color.";
    return @[strengthRow, accent, toggles, glass, fallback];
}
- (void)addonDidEnable {
    MRGLookSetDynamicRGB(^NSInteger { return channel(@"accent"); });
    MRGLookSetSwitchRGB(^NSInteger { return channel(@"toggles"); });
    MRGLookSetGlassTint(^UIColor *{
        NSInteger rgb = channel(@"glass");
        return rgb >= 0 ? MRGColorFromRGB(rgb) : nil;
    });
    resolve(MRGNowPlaying());
    MRGLookRefresh();
}
- (void)addonDidDisable {
    sColor = -1;
    sTrack = nil;
    MRGLookSetDynamicRGB(nil);
    MRGLookSetSwitchRGB(nil);
    MRGLookSetGlassTint(nil);
    MRGLookRefresh();
}
- (NSString *)addonSummary { return sColor >= 0 ? [NSString stringWithFormat:@"#%06lX", (long)sColor] : @"From the cover"; }
@end

__attribute__((constructor)) static void mrgDynamicConstructor(void) {
    MRGAddonRegister([MRGDynamicAddon new]);
    [NSNotificationCenter.defaultCenter addObserverForName:MRGPlayerTrackChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        if (!MRGAddonInstalled(kAddon)) return;
        resolve(n.userInfo);
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:MRGSettingsChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        if (!MRGAddonInstalled(kAddon)) return;
        if (sTrack.length) {
            NSInteger extracted = cached(sTrack);
            if (extracted >= 0) sColor = blended(extracted);
        }
        MRGLookRefresh();
    }];
}
