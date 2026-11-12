// Add-on "Lyrics backdrop" (Now Playing): the cover dims and the song's synced lyrics scroll over it in large type,
// the line being sung bright and a little above the middle, the ones around it fading off. The lines are Vitrine's
// (its karaoke store: SGKaraokeLinesForTrack and friends, looked up at run time like the Pop-up lyrics add-on), so it
// needs Vitrine's lyrics; a song without synced lines leaves the cover as it is. It sits on the cover itself, so it
// moves with it (Vinyl's sleeve too). Touches pass through to Spotify. Low Power Mode or Reduce Motion: the lines
// step without the spring and are checked twice a second instead of ten times.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "MRGAddon.h"
#import "MRGAddons.h"
#import "MRGPrefs.h"
#import "MRGPlayer.h"
#import "MRGNowKit.h"
#import "MRGDJLog.h"

static NSString *const kAddon = @"lyrics-backdrop";
static char kBackdropKey;

typedef NSArray *(*LinesFn)(NSString *);
typedef NSInteger (*LeadFn)(NSArray *, NSInteger);
typedef NSInteger (*PosFn)(void);
typedef NSString *(*TrackFn)(void);
typedef void (*AskFn)(NSString *);
typedef NSString *(*TextFn)(id);
static LinesFn sgLines;
static LeadFn sgLead;
static PosFn sgPos;
static TrackFn sgTrack;
static AskFn sgAsk;
static TextFn sgText;

static BOOL haveVitrine(void) {
    static BOOL looked;
    if (!looked) {
        looked = YES;
        sgLines = dlsym(RTLD_DEFAULT, "SGKaraokeLinesForTrack");
        sgLead = dlsym(RTLD_DEFAULT, "SGKaraokeLeadLine");
        sgPos = dlsym(RTLD_DEFAULT, "SGKaraokePositionMs");
        sgTrack = dlsym(RTLD_DEFAULT, "SGKaraokePlayingTrack");
        sgAsk = dlsym(RTLD_DEFAULT, "SGKaraokeRequestLyrics");
        sgText = dlsym(RTLD_DEFAULT, "SGKaraokeLineText");
    }
    return sgLines && sgLead && sgPos && sgText;
}

static CGFloat dimAmount(void) { return MIN(0.85, MAX(0.3, MRGAddonNumber(kAddon, @"dim", 0.6))); }
static CGFloat textSize(void) { return MIN(34, MAX(20, MRGAddonNumber(kAddon, @"size", 27))); }
static BOOL calm(void) { return NSProcessInfo.processInfo.isLowPowerModeEnabled || UIAccessibilityIsReduceMotionEnabled(); }

@interface MRGLyricsBackdropView : UIView
- (void)changed;
@end

@implementation MRGLyricsBackdropView {
    UIView *_dim, *_clip, *_column;
    CAGradientLayer *_fade;
    NSMutableArray<UILabel *> *_labels;
    NSArray *_lines;
    NSString *_track, *_asked;
    NSInteger _active;
    NSTimer *_timer;
    CGFloat _builtWidth, _builtSize;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.clipsToBounds = YES;
    self.layer.zPosition = 10;   // under Cover ring's line (20)
    self.accessibilityElementsHidden = YES;
    _labels = [NSMutableArray array];
    _active = NSIntegerMin;
    _dim = [UIView new];
    _dim.backgroundColor = UIColor.blackColor;
    _clip = [UIView new];
    _clip.clipsToBounds = YES;
    _fade = [CAGradientLayer layer];
    _fade.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
    _fade.locations = @[@0, @0.16, @0.82, @1];
    _clip.layer.mask = _fade;
    _column = [UIView new];
    [_clip addSubview:_column];
    [self addSubview:_dim];
    [self addSubview:_clip];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(changed) name:MRGPlayerTrackChangedNotification object:nil];
    [nc addObserver:self selector:@selector(changed) name:MRGSettingsChangedNotification object:nil];
    [nc addObserver:self selector:@selector(changed) name:NSProcessInfoPowerStateDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(changed) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(updateTimer) name:UIApplicationDidEnterBackgroundNotification object:nil];
    NSString * __strong *kept = (NSString * __strong *)dlsym(RTLD_DEFAULT, "SGKaraokeLinesKeptNotification");
    if (kept && [*kept isKindOfClass:NSString.class]) [nc addObserver:self selector:@selector(changed) name:*kept object:nil];
    return self;
}

- (void)dealloc { [_timer invalidate]; [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)didMoveToWindow { [super didMoveToWindow]; [self changed]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    UIView *cover = self.superview;
    CGFloat r = cover.layer.cornerRadius;
    for (UIView *s in cover.subviews) if (s != self && s.layer.cornerRadius > r) r = s.layer.cornerRadius;
    self.layer.cornerRadius = r;
    _dim.frame = b;
    CGRect clip = CGRectInset(b, 20, 14);
    if (!CGRectEqualToRect(_clip.frame, clip)) {
        _clip.frame = clip;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _fade.frame = _clip.bounds;
        [CATransaction commit];
    }
    if (fabs(_builtWidth - clip.size.width) > 0.5 || fabs(_builtSize - textSize()) > 0.1) [self rebuild];
}

- (void)changed {
    @try {
        NSDictionary *playing = MRGNowPlaying();
        BOOL song = MRGAddonInstalled(kAddon) && haveVitrine() && playing && ![playing[@"ad"] boolValue];
        NSString *track = song && sgTrack ? sgTrack() : nil;
        if (song && !track.length) {
            NSString *uri = playing[@"uri"];
            if ([uri hasPrefix:@"spotify:track:"]) track = [uri substringFromIndex:@"spotify:track:".length];
        }
        NSArray *lines = track.length ? sgLines(track) : nil;
        if (song && track.length && !lines.count && ![track isEqualToString:_asked] && sgAsk) { _asked = [track copy]; sgAsk(track); }
        BOOL fresh = lines != _lines || ![track isEqualToString:_track ?: @""];
        _track = [track copy];
        _lines = lines;
        if (fresh) [self rebuild];
        BOOL show = song && lines.count > 0;
        CGFloat dim = show ? dimAmount() : 0;
        [UIView animateWithDuration:calm() ? 0 : 0.35 animations:^{
            self->_dim.alpha = dim;
            self->_clip.alpha = show ? 1 : 0;
        }];
        [self updateTimer];
        [self tick];
    } @catch (NSException *e) {
        MRGDJLog(@"lyrics backdrop: refresh threw %@", e.reason);
    }
}

- (void)updateTimer {
    BOOL run = _lines.count && self.window && UIApplication.sharedApplication.applicationState != UIApplicationStateBackground;
    NSTimeInterval every = calm() ? 0.5 : 0.1;
    if (run && _timer && fabs(_timer.timeInterval - every) < 0.01) return;
    [_timer invalidate];
    _timer = nil;
    if (!run) return;
    __weak typeof(self) weak = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:every repeats:YES block:^(NSTimer *t) {
        MRGLyricsBackdropView *s = weak;
        if (!s || !s.window) { [t invalidate]; return; }
        @try { [s tick]; } @catch (NSException *e) {}
    }];
    _timer.tolerance = every * 0.2;
}

- (void)rebuild {
    for (UILabel *l in _labels) [l removeFromSuperview];
    [_labels removeAllObjects];
    CGFloat w = _clip.bounds.size.width;
    _builtWidth = w;
    _builtSize = textSize();
    _active = NSIntegerMin;
    if (w < 60 || !_lines.count || !sgText) return;
    UIFont *font = [UIFont systemFontOfSize:_builtSize weight:UIFontWeightHeavy];
    CGFloat y = 0, gap = 10;
    NSUInteger n = MIN(_lines.count, (NSUInteger)400);
    for (NSUInteger i = 0; i < n; i++) {
        NSString *text = nil;
        @try { text = sgText(_lines[i]); } @catch (NSException *e) {}
        text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        UILabel *l = [UILabel new];
        l.text = text.length ? text : @"♪";
        l.font = font;
        l.textColor = UIColor.whiteColor;
        l.numberOfLines = 0;
        l.layer.shadowColor = UIColor.blackColor.CGColor;
        l.layer.shadowOpacity = 0.4;
        l.layer.shadowRadius = 4;
        l.layer.shadowOffset = CGSizeMake(0, 1);
        CGFloat h = ceil([l sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)].height);
        l.layer.anchorPoint = CGPointMake(0, 0.5);
        l.bounds = CGRectMake(0, 0, w, h);
        l.layer.position = CGPointMake(0, y + h / 2);
        l.alpha = 0;
        [_column addSubview:l];
        [_labels addObject:l];
        y += h + gap;
    }
    _column.frame = CGRectMake(0, 0, w, y);
}

- (void)tick {
    if (!_labels.count || !sgLead) return;
    NSInteger ms = sgPos ? sgPos() : 0;
    NSInteger index = ms >= 0 ? sgLead(_lines, ms) : -1;
    if (index >= (NSInteger)_labels.count) index = (NSInteger)_labels.count - 1;
    if (index == _active) return;
    BOOL first = _active == NSIntegerMin;
    _active = index;
    NSInteger a = index, anchor = MAX(0, a);
    UILabel *target = _labels[MIN((NSUInteger)anchor, _labels.count - 1)];
    CGFloat targetY = _clip.bounds.size.height * 0.4 - target.layer.position.y;
    void (^apply)(void) = ^{
        CGRect f = self->_column.frame;
        f.origin.y = round(targetY);
        self->_column.frame = f;
        for (NSInteger i = 0; i < (NSInteger)self->_labels.count; i++) {
            UILabel *l = self->_labels[i];
            NSInteger d = a < 0 ? i + 1 : labs(i - a);
            BOOL past = a >= 0 && i < a;
            l.alpha = d == 0 ? 1 : d == 1 ? (past ? 0.3 : 0.45) : d == 2 ? 0.22 : d <= 4 ? 0.1 : 0;
            l.transform = d == 0 ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.9, 0.9);
        }
    };
    if (first || !self.window) [UIView performWithoutAnimation:apply];
    else if (calm()) [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:apply completion:nil];
    else [UIView animateWithDuration:0.65 delay:0 usingSpringWithDamping:0.84 initialSpringVelocity:0.2 options:UIViewAnimationOptionBeginFromCurrentState animations:apply completion:nil];
}
@end

static void applyCover(UIView *tilt) {
    MRGLyricsBackdropView *v = objc_getAssociatedObject(tilt, &kBackdropKey);
    UIView *cover = MRGNowCoverIn(tilt);
    if (!MRGAddonInstalled(kAddon) || !haveVitrine()) { [v removeFromSuperview]; return; }
    if (!cover) return;
    if (!v) {
        v = [MRGLyricsBackdropView new];
        objc_setAssociatedObject(tilt, &kBackdropKey, v, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (v.superview != cover) {
        v.frame = cover.bounds;
        v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [cover addSubview:v];
    } else if (!CGRectEqualToRect(v.frame, cover.bounds)) v.frame = cover.bounds;
}

@interface MRGLyricsBackdropAddon : NSObject <MRGAddon>
@end
@implementation MRGLyricsBackdropAddon
- (NSString *)addonID { return kAddon; }
- (NSString *)addonName { return @"Lyrics backdrop"; }
- (NSString *)addonCategory { return @"Now Playing"; }
- (NSString *)addonVersion { return @"1.0"; }
- (NSString *)addonDescription { return @"Dims the Now Playing cover and scrolls the synced lyrics over it, big."; }
- (NSInteger)addonBatteryImpact { return 2; }
- (NSString *)addonBatteryNote { return @"Higher: redraws the lyrics 10 times a second while Now Playing is open."; }
- (NSArray<MRGAddonSetting *> *)addonSettings {
    MRGAddonSetting *dim = [MRGAddonSetting slider:@"dim" title:@"Cover dimming" min:0.3 max:0.85 fallback:0.6];
    dim.live = YES;
    MRGAddonSetting *size = [MRGAddonSetting slider:@"size" title:@"Text size" min:20 max:34 fallback:27];
    size.live = YES;
    size.footer = !MRGNowKitRunning() ? @"Off on this Spotify build (see About)." : haveVitrine() ? @"Uses Vitrine's synced lyrics." : @"Needs Vitrine's lyrics, which aren't loaded.";
    return @[dim, size];
}
- (void)addonDidEnable {}
- (void)addonDidDisable {}
- (NSString *)addonSummary { return haveVitrine() ? nil : @"Needs Vitrine"; }
@end

__attribute__((constructor)) static void MRGLyricsBackdropInit(void) {
    MRGAddonRegister([MRGLyricsBackdropAddon new]);
    MRGNowAddCoverClient(^(UIView *tilt) { applyCover(tilt); });
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:MRGSettingsChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            static BOOL last;
            BOOL now = MRGAddonInstalled(kAddon);
            if (now == last) return;
            last = now;
            @try { MRGNowRelayout(); } @catch (NSException *e) {}
        }];
    });
}
