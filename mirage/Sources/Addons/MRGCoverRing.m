// Add-on "Cover ring" (Now Playing): a thin progress line runs around the edge of the player's cover, filling
// clockwise from the top as the song plays, in the accent, the cover's own color or white. It lives on the cover
// itself, so it moves, scales and fades with it (Vinyl's sleeve included). Spotify 9.1.90 gives the app no waveform
// for a track (that data isn't in the player state or any endpoint a Free account can read), so it is a progress
// ring only, not a waveform. Low Power Mode: it steps every 2 seconds without animating.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "MRGAddon.h"
#import "MRGAddons.h"
#import "MRGPrefs.h"
#import "MRGPlayer.h"
#import "MRGNowKit.h"
#import "MRGDJLog.h"

static NSString *const kAddon = @"cover-ring";
static char kRingKey;

static NSInteger colorMode(void) { return MRGAddonInteger(kAddon, @"color", 0); }   // 0 accent, 1 cover, 2 white
static CGFloat thickness(void) { return MIN(6, MAX(1.5, MRGAddonNumber(kAddon, @"width", 3))); }

@interface MRGCoverRingView : UIView
@property (nonatomic, weak) UIView *tilt;
- (void)refresh;
@end

@implementation MRGCoverRingView {
    CAShapeLayer *_track, *_bar;
    NSTimer *_timer;
    CGSize _builtSize;
    CGFloat _builtWidth, _builtRadius;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    self.layer.zPosition = 20;
    _track = [CAShapeLayer layer];
    _track.fillColor = nil;
    _track.strokeColor = [UIColor colorWithWhite:1 alpha:0.16].CGColor;
    _bar = [CAShapeLayer layer];
    _bar.fillColor = nil;
    _bar.lineCap = kCALineCapRound;
    _bar.strokeEnd = 0;
    [self.layer addSublayer:_track];
    [self.layer addSublayer:_bar];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(trackChanged) name:MRGPlayerTrackChangedNotification object:nil];
    [nc addObserver:self selector:@selector(refresh) name:NSProcessInfoPowerStateDidChangeNotification object:nil];
    return self;
}
- (void)dealloc { [_timer invalidate]; [NSNotificationCenter.defaultCenter removeObserver:self]; }

// A rounded square starting at the top middle, clockwise, so the fill starts at 12 o'clock.
static CGPathRef ringPath(CGRect r, CGFloat radius) {
    CGFloat x0 = CGRectGetMinX(r), x1 = CGRectGetMaxX(r), y0 = CGRectGetMinY(r), y1 = CGRectGetMaxY(r), mx = CGRectGetMidX(r);
    radius = MIN(radius, MIN(r.size.width, r.size.height) / 2);
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(mx, y0)];
    [p addLineToPoint:CGPointMake(x1 - radius, y0)];
    [p addArcWithCenter:CGPointMake(x1 - radius, y0 + radius) radius:radius startAngle:-M_PI_2 endAngle:0 clockwise:YES];
    [p addLineToPoint:CGPointMake(x1, y1 - radius)];
    [p addArcWithCenter:CGPointMake(x1 - radius, y1 - radius) radius:radius startAngle:0 endAngle:M_PI_2 clockwise:YES];
    [p addLineToPoint:CGPointMake(x0 + radius, y1)];
    [p addArcWithCenter:CGPointMake(x0 + radius, y1 - radius) radius:radius startAngle:M_PI_2 endAngle:M_PI clockwise:YES];
    [p addLineToPoint:CGPointMake(x0, y0 + radius)];
    [p addArcWithCenter:CGPointMake(x0 + radius, y0 + radius) radius:radius startAngle:M_PI endAngle:1.5 * M_PI clockwise:YES];
    [p closePath];
    return p.CGPath;
}

- (CGFloat)coverRadius {
    UIView *cover = self.superview;
    CGFloat r = cover.layer.cornerRadius;
    for (UIView *s in cover.subviews) if (s != self && s.layer.cornerRadius > r && s.bounds.size.width > cover.bounds.size.width * 0.9) r = s.layer.cornerRadius;
    return r;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize s = self.bounds.size;
    CGFloat w = thickness(), radius = [self coverRadius];
    if (CGSizeEqualToSize(s, _builtSize) && w == _builtWidth && radius == _builtRadius) return;
    _builtSize = s; _builtWidth = w; _builtRadius = radius;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGFloat inset = w / 2 + 2;
    CGPathRef path = ringPath(CGRectInset(self.bounds, inset, inset), MAX(2, radius - inset));
    for (CAShapeLayer *l in @[_track, _bar]) { l.frame = self.bounds; l.path = path; l.lineWidth = w; }
    [CATransaction commit];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self refresh];
}

- (void)trackChanged {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _bar.strokeEnd = 0;
    [CATransaction commit];
    __weak typeof(self) weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weak refresh]; });
}

- (void)refresh {
    BOOL lpm = NSProcessInfo.processInfo.isLowPowerModeEnabled;
    BOOL run = self.window && UIApplication.sharedApplication.applicationState != UIApplicationStateBackground;
    NSTimeInterval every = lpm ? 2 : 1;
    if (!run) { [_timer invalidate]; _timer = nil; }
    else if (!_timer || fabs(_timer.timeInterval - every) > 0.01) {
        [_timer invalidate];
        __weak typeof(self) weak = self;
        _timer = [NSTimer scheduledTimerWithTimeInterval:every repeats:YES block:^(NSTimer *t) {
            MRGCoverRingView *s = weak;
            if (!s || !s.window) { [t invalidate]; return; }
            @try { [s tick]; } @catch (NSException *e) {}
        }];
        _timer.tolerance = every * 0.2;
    }
    [self setNeedsLayout];
    [self tick];
}

- (UIColor *)barColor {
    switch (colorMode()) {
        case 1: { UIColor *c = MRGNowVividColor(MRGNowCoverImage(self.tilt)); if (c) return c; break; }
        case 2: return UIColor.whiteColor;
        default: break;
    }
    return MRGAccent();
}

- (void)tick {
    double pos = 0, dur = 0;
    BOOL known = MRGPlayerProgress(&pos, &dur) && dur > 1;
    BOOL playing = MRGPlayerIsPlaying(), calm = NSProcessInfo.processInfo.isLowPowerModeEnabled || UIAccessibilityIsReduceMotionEnabled();
    _bar.strokeColor = [self barColor].CGColor;
    self.hidden = !known;
    if (!known) return;
    double now = MIN(1, MAX(0, pos / dur));
    // Animated to where the song will be at the next tick, so the line creeps instead of stepping.
    double next = playing && !calm ? MIN(1, (pos + _timer.timeInterval) / dur) : now;
    [CATransaction begin];
    if (fabs(_bar.strokeEnd - now) > 0.02 || !playing || calm) {
        [CATransaction setDisableActions:YES];
        _bar.strokeEnd = now;
        [CATransaction commit];
        [CATransaction begin];
    }
    if (next != now) {
        [CATransaction setAnimationDuration:_timer.timeInterval];
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear]];
        _bar.strokeEnd = next;
    }
    [CATransaction commit];
}
@end

static void applyCover(UIView *tilt) {
    MRGCoverRingView *ring = objc_getAssociatedObject(tilt, &kRingKey);
    UIView *cover = MRGNowCoverIn(tilt);
    if (!MRGAddonInstalled(kAddon) || !cover) { if (!cover && ring.superview) return; [ring removeFromSuperview]; return; }
    if (!ring) {
        ring = [MRGCoverRingView new];
        ring.tilt = tilt;
        objc_setAssociatedObject(tilt, &kRingKey, ring, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (ring.superview != cover) {
        ring.frame = cover.bounds;
        ring.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [cover addSubview:ring];
    } else if (cover.subviews.lastObject != ring) [cover bringSubviewToFront:ring];
    if (!CGRectEqualToRect(ring.frame, cover.bounds)) ring.frame = cover.bounds;
}

@interface MRGCoverRingAddon : NSObject <MRGAddon>
@end
@implementation MRGCoverRingAddon
- (NSString *)addonID { return kAddon; }
- (NSString *)addonName { return @"Cover ring"; }
- (NSString *)addonCategory { return @"Now Playing"; }
- (NSString *)addonVersion { return @"1.0"; }
- (NSString *)addonDescription { return @"A thin progress ring around the Now Playing cover."; }
- (NSInteger)addonBatteryImpact { return 0; }
- (NSString *)addonBatteryNote { return @"Low: updates once a second, only while Now Playing is open."; }
- (NSArray<MRGAddonSetting *> *)addonSettings {
    MRGAddonSetting *color = [MRGAddonSetting picker:@"color" title:@"Color" options:@[@"Accent", @"From the cover", @"White"] values:@[@0, @1, @2] fallback:@0];
    MRGAddonSetting *width = [MRGAddonSetting picker:@"width" title:@"Thickness" options:@[@"Hairline", @"Thin", @"Bold"] values:@[@1.5, @3, @5] fallback:@3];
    width.footer = MRGNowKitRunning() ? @"Progress only: Spotify gives no waveform data." : @"Off on this Spotify build (see About).";
    return @[color, width];
}
- (void)addonDidEnable {}
- (void)addonDidDisable {}
- (NSString *)addonSummary { NSInteger c = colorMode(); return c == 1 ? @"Cover color" : c == 2 ? @"White" : @"Accent"; }
@end

__attribute__((constructor)) static void MRGCoverRingInit(void) {
    MRGAddonRegister([MRGCoverRingAddon new]);
    MRGNowAddCoverClient(^(UIView *tilt) { applyCover(tilt); });
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:MRGSettingsChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            static NSString *last;
            NSString *now = [NSString stringWithFormat:@"%d%ld%.1f", MRGAddonInstalled(kAddon), (long)colorMode(), thickness()];
            if ([now isEqualToString:last]) return;
            BOOL first = last == nil;
            last = now;
            if (first && !MRGAddonInstalled(kAddon)) return;
            @try { MRGNowRelayout(); } @catch (NSException *e) {}
        }];
    });
}
