#import "MRGNowKit.h"
#import "MRGCompat.h"
#import "MRGDJLog.h"
#import <objc/runtime.h>

static NSMutableArray<MRGNowPartClient> *sPartClients;
static NSMutableArray<MRGNowCoverClient> *sCoverClients;
static BOOL sRunning;

void MRGNowAddPartClient(MRGNowPartClient client) {
    if (!client) return;
    if (!sPartClients) sPartClients = [NSMutableArray array];
    [sPartClients addObject:[client copy]];
}
void MRGNowAddCoverClient(MRGNowCoverClient client) {
    if (!client) return;
    if (!sCoverClients) sCoverClients = [NSMutableArray array];
    [sCoverClients addObject:[client copy]];
}
BOOL MRGNowKitRunning(void) { return sRunning; }

BOOL MRGNowClassNamed(id obj, NSString *part) { return obj && [NSStringFromClass([obj class]) containsString:part]; }

static void runParts(MRGNowPart part, id owner) {
    for (MRGNowPartClient c in sPartClients) {
        @try { c(part, owner); } @catch (NSException *e) { MRGDJLog(@"now playing kit: a part client threw %@", e.reason); }
    }
}

static Class tiltClass(void) {
    static Class c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView"); });
    return c;
}
static Class cellClass(void) {
    static Class c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl"); });
    return c;
}
static BOOL inPlayerCell(UIView *v) {
    Class c = cellClass();
    for (UIView *p = v.superview; p && c; p = p.superview) if ([p isKindOfClass:c]) return YES;
    return NO;
}
static UIView *findTilt(UIView *v, int depth) {
    if (!v || depth > 8) return nil;
    Class c = tiltClass();
    if (c && [v isKindOfClass:c] && v.bounds.size.width >= 200) return v;
    for (UIView *s in v.subviews) { UIView *t = findTilt(s, depth + 1); if (t) return t; }
    return nil;
}

static void runCover(UIView *tilt) {
    if (!tilt || tilt.bounds.size.width < 200 || !inPlayerCell(tilt)) return;
    for (MRGNowCoverClient c in sCoverClients) {
        @try { c(tilt); } @catch (NSException *e) { MRGDJLog(@"now playing kit: a cover client threw %@", e.reason); }
    }
}

UIStackView *MRGNowRowIn(UIView *root) {
    if (!root) return nil;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger seen = 0;
    while (stack.count && seen < 300) {
        UIView *v = stack.firstObject; [stack removeObjectAtIndex:0]; seen++;
        if ([v isKindOfClass:UIStackView.class] && v.bounds.size.width > 200 && ((UIStackView *)v).arrangedSubviews.count >= 2) return (UIStackView *)v;
        [stack addObjectsFromArray:v.subviews];
    }
    return nil;
}

UIView *MRGNowCoverIn(UIView *tilt) {
    UIView *best = nil;
    CGFloat side = MIN(tilt.bounds.size.width, tilt.bounds.size.height), bestArea = 0;
    for (UIView *s in tilt.subviews) {
        if (s.hidden || [NSStringFromClass(s.class) hasPrefix:@"MRG"]) continue;
        CGSize z = s.bounds.size;
        if (z.width < side * 0.8 || z.height < side * 0.8) continue;
        if (z.width * z.height > bestArea) { bestArea = z.width * z.height; best = s; }
    }
    return best;
}

static UIImage *imageIn(UIView *v, int depth) {
    if (!v || depth > 8) return nil;
    if ([v isKindOfClass:UIImageView.class]) {
        UIImage *img = ((UIImageView *)v).image;
        if (img.size.width >= 60) return img;
    }
    for (UIView *s in v.subviews) { UIImage *i = imageIn(s, depth + 1); if (i) return i; }
    return nil;
}
UIImage *MRGNowCoverImage(UIView *tilt) { return imageIn(MRGNowCoverIn(tilt) ?: tilt, 0); }

UIColor *MRGNowVividColor(UIImage *image) {
    CGImageRef cg = image.CGImage;
    if (!cg) return nil;
    static NSMapTable *cache;
    if (!cache) cache = [NSMapTable weakToStrongObjectsMapTable];
    UIColor *hit = [cache objectForKey:image];
    if (hit) return hit;
    // 8x8 average, then the most colorful cell of them (an average of a two-color cover is mud).
    uint8_t px[8 * 8 * 4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, 8, 8, 8, 32, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!ctx) return nil;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, 8, 8), cg);
    CGContextRelease(ctx);
    CGFloat bestScore = -1, bh = 0, bs = 0, bb = 0;
    for (int i = 0; i < 64; i++) {
        UIColor *c = [UIColor colorWithRed:px[i * 4] / 255.0 green:px[i * 4 + 1] / 255.0 blue:px[i * 4 + 2] / 255.0 alpha:1];
        CGFloat h, s, b, a;
        if (![c getHue:&h saturation:&s brightness:&b alpha:&a]) continue;
        CGFloat score = s * (0.35 + b);
        if (score > bestScore) { bestScore = score; bh = h; bs = s; bb = b; }
    }
    UIColor *out = bestScore < 0.08 ? [UIColor colorWithWhite:0.92 alpha:1]   // a gray cover: white
        : [UIColor colorWithHue:bh saturation:MIN(1, MAX(0.45, bs * 1.15)) brightness:MAX(0.78, bb) alpha:1];
    [cache setObject:out forKey:image];
    return out;
}

static char kHidAlphaKey, kHidTouchKey, kHidOwnerKey;
static NSMutableDictionary<NSString *, NSHashTable *> *sHidden;

BOOL MRGNowHide(UIView *view, NSString *owner) {
    if (!view || !owner) return NO;
    if (!objc_getAssociatedObject(view, &kHidOwnerKey)) {
        objc_setAssociatedObject(view, &kHidAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, &kHidTouchKey, @(view.userInteractionEnabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, &kHidOwnerKey, owner, OBJC_ASSOCIATION_COPY_NONATOMIC);
        if (!sHidden) sHidden = [NSMutableDictionary dictionary];
        if (!sHidden[owner]) sHidden[owner] = [NSHashTable weakObjectsHashTable];
        [sHidden[owner] addObject:view];
    }
    BOOL changed = view.alpha != 0 || view.userInteractionEnabled;
    view.alpha = 0;
    view.userInteractionEnabled = NO;
    return changed;
}

void MRGNowRestoreAll(NSString *owner) {
    NSHashTable *t = owner ? sHidden[owner] : nil;
    for (UIView *v in t.allObjects) {
        if (![objc_getAssociatedObject(v, &kHidOwnerKey) isEqual:owner]) continue;
        NSNumber *a = objc_getAssociatedObject(v, &kHidAlphaKey), *touch = objc_getAssociatedObject(v, &kHidTouchKey);
        v.alpha = a ? a.doubleValue : 1;
        v.userInteractionEnabled = touch ? touch.boolValue : YES;
        objc_setAssociatedObject(v, &kHidOwnerKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(v, &kHidAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(v, &kHidTouchKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [t removeAllObjects];
}

static NSDictionary<NSString *, NSNumber *> *partClasses(void) {
    static NSDictionary *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = @{
            @"_TtC20NowPlaying_ModesImpl18HeaderElementsUnit": @(MRGNowHeader),
            @"_TtC20NowPlaying_ModesImpl23InformationElementsUnit": @(MRGNowInfo),
            @"_TtC20NowPlaying_ModesImpl19DurationElementUnit": @(MRGNowDuration),
            @"_TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit": @(MRGNowControls),
            @"_TtC20NowPlaying_ModesImpl18FooterElementsUnit": @(MRGNowFooter),
            @"_TtC20NowPlaying_ModesImpl20FloatingElementsUnit": @(MRGNowFloating),
            @"_TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController": @(MRGNowBackground),
            @"_TtC21NowPlaying_ScrollImpl23NPVScrollViewController": @(MRGNowScroll),
        };
    });
    return d;
}

void MRGNowRelayout(void) {
    if (!sRunning) return;
    Class lyrics = NSClassFromString(@"_TtC22Lyrics_NPVContainerKit19LyricsContainerView");
    NSDictionary *parts = partClasses();
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
            NSUInteger seen = 0;
            while (stack.count && seen < 6000) {
                UIView *v = stack.lastObject; [stack removeLastObject]; seen++;
                UIResponder *next = v.nextResponder;
                if ([next isKindOfClass:UIViewController.class] && ((UIViewController *)next).viewIfLoaded == v) {
                    NSNumber *p = parts[NSStringFromClass(next.class)];
                    if (p) runParts((MRGNowPart)p.integerValue, next);
                }
                if (lyrics && [v isKindOfClass:lyrics]) runParts(MRGNowLyrics, v);
                if (tiltClass() && [v isKindOfClass:tiltClass()] && v.bounds.size.width >= 200) { runCover(v); continue; }
                [stack addObjectsFromArray:v.subviews];
            }
        }
    }
}

%group MRGNowKitHooks
%hook _TtC20NowPlaying_ModesImpl18HeaderElementsUnit
- (void)viewDidLayoutSubviews { %orig; runParts(MRGNowHeader, self); }
%end
%hook _TtC20NowPlaying_ModesImpl23InformationElementsUnit
- (void)viewDidLayoutSubviews { %orig; runParts(MRGNowInfo, self); }
%end
%hook _TtC20NowPlaying_ModesImpl19DurationElementUnit
- (void)viewDidLayoutSubviews { %orig; runParts(MRGNowDuration, self); }
%end
%hook _TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit
- (void)viewDidLayoutSubviews { %orig; runParts(MRGNowControls, self); }
%end
%hook _TtC20NowPlaying_ModesImpl18FooterElementsUnit
- (void)viewDidLayoutSubviews { %orig; runParts(MRGNowFooter, self); }
%end
%hook _TtC20NowPlaying_ModesImpl20FloatingElementsUnit
- (void)viewDidLayoutSubviews { %orig; runParts(MRGNowFloating, self); }
%end
%hook _TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController
- (void)viewDidLayoutSubviews { %orig; runParts(MRGNowBackground, self); }
%end
%hook _TtC21NowPlaying_ScrollImpl23NPVScrollViewController
- (void)viewDidLayoutSubviews { %orig; runParts(MRGNowScroll, self); }
%end
%hook _TtC22Lyrics_NPVContainerKit19LyricsContainerView
- (void)layoutSubviews { %orig; runParts(MRGNowLyrics, self); }
%end
%hook _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
- (void)layoutSubviews { %orig; runCover((UIView *)self); }
- (void)didMoveToWindow { %orig; UIView *t = (UIView *)self; if (t.window) runCover(t); }
%end
%hook _TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl
- (void)layoutSubviews { %orig; runCover(findTilt((UIView *)self, 0)); }
%end
%end

%ctor {
    // Every class has to be there: a partial kit would hide half a player.
    for (NSString *name in partClasses()) if (!NSClassFromString(name)) { MRGDJLog(@"now playing kit: %@ missing, the Now Playing add-ons stay off", name); return; }
    for (NSString *name in @[@"_TtC22Lyrics_NPVContainerKit19LyricsContainerView", @"_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView", @"_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl"])
        if (!NSClassFromString(name)) { MRGDJLog(@"now playing kit: %@ missing, the Now Playing add-ons stay off", name); return; }
    if (!MRGFragileHooksAllowed(@"Now Playing kit")) return;
    %init(MRGNowKitHooks);
    sRunning = YES;
}
