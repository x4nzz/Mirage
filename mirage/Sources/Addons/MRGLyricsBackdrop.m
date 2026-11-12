// Add-on "Lyrics backdrop" (Now Playing): while a song has synced lyrics, the cover steps aside and the lyrics take
// its place in large type. Beside the title (the default): the cover shrinks into a thumbnail at the left of the title
// row, the title and artist slide right to make room, and the lines scroll where the cover was, the line being sung
// bright, the ones around it fading off. Behind: the cover stays, dimmed, with the lines over it (0.6.7's look).
// The lines are Vitrine's (its karaoke store, looked up at run time), so it needs Vitrine's lyrics; a song without
// synced lines leaves the player as it is, and Vitrine's own lyrics view, when open, takes over. Touches pass through
// to Spotify. Low Power Mode or Reduce Motion: no springs, and the lines are checked twice a second instead of ten.
//
// 0.6.8 root cause of "the lyrics in the background doesn't work and it makes the cover invisible": it asked Vitrine
// for a song's lines once and never again, while Vitrine expects its readers to keep asking (it drops repeats during
// its retry pause, so a first ask that came too early was the only one), and it took Vitrine's plain text (kept while
// Spotify is asked for the timing) as synced lines: the cover went dark under lines that never moved, or under none.
// Now it asks on every check until lines come, waits for timed lines, and lays the player out as described above.
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

typedef NSArray *(*LinesFn)(NSString *);
typedef NSInteger (*LeadFn)(NSArray *, NSInteger);
typedef NSInteger (*PosFn)(void);
typedef NSString *(*TrackFn)(void);
typedef void (*AskFn)(NSString *);
typedef NSString *(*TextFn)(id);
typedef NSUInteger (*TimingFn)(NSArray *);
typedef BOOL (*FlagFn)(void);
static LinesFn sgLines;
static LeadFn sgLead;
static PosFn sgPos, sgDelay;
static TrackFn sgTrack;
static AskFn sgAsk;
static TextFn sgText;
static TimingFn sgTiming;
static FlagFn sgVitrineLyricsOpen;

static BOOL haveVitrine(void) {
    static BOOL looked;
    if (!looked) {
        looked = YES;
        sgLines = dlsym(RTLD_DEFAULT, "SGKaraokeLinesForTrack");
        sgLead = dlsym(RTLD_DEFAULT, "SGKaraokeLeadLine");
        sgPos = dlsym(RTLD_DEFAULT, "SGKaraokePositionMs");
        sgDelay = dlsym(RTLD_DEFAULT, "SGKaraokeDelayMs");
        sgTrack = dlsym(RTLD_DEFAULT, "SGKaraokePlayingTrack");
        sgAsk = dlsym(RTLD_DEFAULT, "SGKaraokeRequestLyrics");
        sgText = dlsym(RTLD_DEFAULT, "SGKaraokeLineText");
        sgTiming = dlsym(RTLD_DEFAULT, "SGKaraokeLinesTiming");
        sgVitrineLyricsOpen = dlsym(RTLD_DEFAULT, "SGRPlayerLyricsOpen");
    }
    return sgLines && sgLead && sgPos && sgText;
}

typedef NS_ENUM(NSInteger, MRGBackdropCover) { MRGBackdropBeside = 0, MRGBackdropBehind = 1 };
static MRGBackdropCover coverMode(void) { return MRGAddonInteger(kAddon, @"cover", 0) == 1 ? MRGBackdropBehind : MRGBackdropBeside; }
static CGFloat dimAmount(void) { return MIN(0.85, MAX(0.3, MRGAddonNumber(kAddon, @"dim", 0.6))); }
static CGFloat textSize(void) { return MIN(36, MAX(20, MRGAddonNumber(kAddon, @"size", 28))); }
static BOOL centered(void) { return MRGAddonInteger(kAddon, @"align", 0) == 1; }
static BOOL coverColored(void) { return MRGAddonInteger(kAddon, @"color", 0) == 1; }
static BOOL calm(void) { return NSProcessInfo.processInfo.isLowPowerModeEnabled || UIAccessibilityIsReduceMotionEnabled(); }

static const CGFloat kThumbGap = 12, kTitleFade = 18;

#pragma mark - the lines

@interface MRGLyricsBackdropView : UIView
@property (nonatomic, readonly) BOOL hasLines;   // timed lines for the playing song
@property (nonatomic) BOOL dims;                 // behind the lines: a dim over the cover (Behind mode)
@property (nonatomic, copy) void (^onChange)(void);
@property (nonatomic, strong) UIColor *activeColor;
- (void)changed;
@end

@implementation MRGLyricsBackdropView {
    UIView *_dim, *_clip, *_column;
    CAGradientLayer *_fade;
    NSMutableArray<UILabel *> *_labels;
    NSArray *_lines;
    NSString *_track;
    NSInteger _active;
    NSTimer *_timer;
    CGFloat _builtWidth, _builtSize;
    BOOL _builtCentered, _shown;
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
    _dim.alpha = 0;
    _clip = [UIView new];
    _clip.clipsToBounds = YES;
    _clip.alpha = 0;
    _fade = [CAGradientLayer layer];
    _fade.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
    _fade.locations = @[@0, @0.14, @0.84, @1];
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
    if (kept && [*kept isKindOfClass:NSString.class]) [nc addObserver:self selector:@selector(keptLines) name:*kept object:nil];
    return self;
}

- (void)dealloc { [_timer invalidate]; [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)keptLines { if (NSThread.isMainThread) [self changed]; else dispatch_async(dispatch_get_main_queue(), ^{ [self changed]; }); }

- (void)didMoveToWindow { [super didMoveToWindow]; [self changed]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    _dim.frame = b;
    CGRect clip = self.dims ? CGRectInset(b, 20, 14) : CGRectInset(b, 0, 4);
    if (!CGRectEqualToRect(_clip.frame, clip)) {
        _clip.frame = clip;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _fade.frame = _clip.bounds;
        [CATransaction commit];
    }
    if (fabs(_builtWidth - clip.size.width) > 0.5 || fabs(_builtSize - textSize()) > 0.1 || _builtCentered != centered()) [self rebuild];
}

// Timed lines only: plain text (Vitrine keeps it while it asks Spotify for the timing) can't follow the song.
static BOOL timed(NSArray *lines) {
    if (!lines.count) return NO;
    return sgTiming ? sgTiming(lines) < 2 : YES;
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
        if (!timed(lines)) lines = nil;
        // Asked on every check until the lines come: Vitrine ignores the repeats it is already working on.
        if (song && track.length && !lines && sgAsk) sgAsk(track);
        BOOL fresh = lines != _lines || ![track isEqualToString:_track ?: @""];
        _track = [track copy];
        _lines = lines;
        if (fresh) [self rebuild];
        BOOL show = song && lines.count > 0;
        BOOL flipped = show != _shown;
        _shown = show;
        [UIView animateWithDuration:calm() ? 0 : 0.35 animations:^{
            self->_dim.alpha = show && self.dims ? dimAmount() : 0;
            self->_clip.alpha = show ? 1 : 0;
        }];
        [self updateTimer];
        [self tick];
        if (flipped && self.onChange) self.onChange();
    } @catch (NSException *e) {
        MRGDJLog(@"lyrics backdrop: refresh threw %@", e.reason);
    }
}

- (BOOL)hasLines { return _shown; }

- (void)updateTimer {
    BOOL run = self.window && MRGAddonInstalled(kAddon) && UIApplication.sharedApplication.applicationState != UIApplicationStateBackground;
    NSTimeInterval every = !_lines.count ? 1.0 : calm() ? 0.5 : 0.1;   // no lines yet: a slow check that keeps asking
    if (run && _timer && fabs(_timer.timeInterval - every) < 0.01) return;
    [_timer invalidate];
    _timer = nil;
    if (!run) return;
    __weak typeof(self) weak = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:every repeats:YES block:^(NSTimer *t) {
        MRGLyricsBackdropView *s = weak;
        if (!s || !s.window) { [t invalidate]; return; }
        @try { if (s->_lines.count) [s tick]; else [s changed]; } @catch (NSException *e) {}
    }];
    _timer.tolerance = every * 0.2;
}

- (void)rebuild {
    for (UILabel *l in _labels) [l removeFromSuperview];
    [_labels removeAllObjects];
    CGFloat w = _clip.bounds.size.width;
    _builtWidth = w;
    _builtSize = textSize();
    _builtCentered = centered();
    _active = NSIntegerMin;
    if (w < 60 || !_lines.count || !sgText) return;
    UIFont *font = [UIFont systemFontOfSize:_builtSize weight:UIFontWeightHeavy];
    CGFloat y = 0, gap = round(_builtSize * 0.42);
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
        l.textAlignment = _builtCentered ? NSTextAlignmentCenter : NSTextAlignmentNatural;
        l.layer.shadowColor = UIColor.blackColor.CGColor;
        l.layer.shadowOpacity = 0.35;
        l.layer.shadowRadius = 4;
        l.layer.shadowOffset = CGSizeMake(0, 1);
        CGFloat h = ceil([l sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)].height);
        l.layer.anchorPoint = CGPointMake(_builtCentered ? 0.5 : 0, 0.5);
        l.bounds = CGRectMake(0, 0, w, h);
        l.layer.position = CGPointMake(_builtCentered ? w / 2 : 0, y + h / 2);
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
    if (ms >= 0 && sgDelay) ms += sgDelay();
    NSInteger index = ms >= 0 ? sgLead(_lines, ms) : -1;
    if (index >= (NSInteger)_labels.count) index = (NSInteger)_labels.count - 1;
    if (index == _active) return;
    BOOL first = _active == NSIntegerMin;
    _active = index;
    NSInteger a = index, anchor = MAX(0, a);
    UILabel *target = _labels[MIN((NSUInteger)anchor, _labels.count - 1)];
    CGFloat targetY = _clip.bounds.size.height * 0.36 - target.layer.position.y;
    UIColor *bright = self.activeColor ?: UIColor.whiteColor;
    void (^apply)(void) = ^{
        CGRect f = self->_column.frame;
        f.origin.y = round(targetY);
        self->_column.frame = f;
        for (NSInteger i = 0; i < (NSInteger)self->_labels.count; i++) {
            UILabel *l = self->_labels[i];
            NSInteger d = a < 0 ? i + 1 : labs(i - a);
            BOOL past = a >= 0 && i < a;
            l.alpha = d == 0 ? 1 : d == 1 ? (past ? 0.32 : 0.5) : d == 2 ? 0.26 : d <= 5 ? 0.12 : 0;
            l.textColor = d == 0 ? bright : UIColor.whiteColor;
            l.transform = d == 0 ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.92, 0.92);
        }
    };
    if (first || !self.window) [UIView performWithoutAnimation:apply];
    else if (calm()) [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:apply completion:nil];
    else [UIView animateWithDuration:0.7 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.2 options:UIViewAnimationOptionBeginFromCurrentState animations:apply completion:nil];
}
@end

#pragma mark - the stage: the cover beside the title, the lines where it was

// One for the whole app: the cover on screen, the title row, and the views Mirage puts beside them.
static __weak UIView *sg_tilt;                 // the cover's tilt view in the middle of the screen
static __weak UIViewController *sg_infoUnit;   // InformationElementsUnit: title, artist, like
static __weak UIView *sg_title;                // the arranged element holding the title and artist labels
static __weak UIView *sg_hiddenTilt;           // the tilt view the stage hid (put back when the stage closes)
static CGFloat sg_tiltAlpha = 1;
static MRGLyricsBackdropView *sg_lines;
static UIImageView *sg_thumb;
static BOOL sg_open, sg_queued;

static UIView *commonAncestor(UIView *a, UIView *b) {
    if (!a || !b || a.window != b.window) return nil;
    NSMutableSet *ups = [NSMutableSet set];
    for (UIView *v = a; v; v = v.superview) [ups addObject:[NSValue valueWithNonretainedObject:v]];
    for (UIView *v = b; v; v = v.superview) if ([ups containsObject:[NSValue valueWithNonretainedObject:v]]) return v;
    return nil;
}

// A view's frame in `host` as laid out, without the transform the stage put on it.
static CGRect untransformedIn(UIView *v, UIView *host) {
    CGRect r = CGRectMake(v.center.x - v.bounds.size.width / 2, v.center.y - v.bounds.size.height / 2, v.bounds.size.width, v.bounds.size.height);
    return v.superview ? [v.superview convertRect:r toView:host] : r;
}

static UIView *titleElementIn(UIView *root) {
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger seen = 0;
    UIView *label = nil;
    while (stack.count && seen < 600 && !label) {
        UIView *v = stack.lastObject; [stack removeLastObject]; seen++;
        if ([v.accessibilityIdentifier isEqualToString:@"now-playing-title-label"]) label = v;
        else [stack addObjectsFromArray:v.subviews];
    }
    for (UIView *v = label; v && v != root; v = v.superview) if ([v.superview isKindOfClass:UIStackView.class]) return v;
    return nil;
}

// How far right the title may reach: the nearest visible view of its row on its trailing side (the like button).
static CGFloat trailingLimit(UIView *title, UIView *host) {
    UIView *row = title.superview;
    CGFloat left = CGRectGetMinX(untransformedIn(title, host)), limit = CGRectGetMaxX([row convertRect:row.bounds toView:host]);
    for (UIView *v in row.subviews) {
        if (v == title || v.hidden || v.alpha < 0.01 || v.bounds.size.width < 1) continue;
        CGFloat x = CGRectGetMinX([v convertRect:v.bounds toView:host]);
        if (x > left && x < limit) limit = x;
    }
    return limit;
}

static void clipTitle(UIView *title, CGFloat width) {
    if (width <= 0 || width >= title.bounds.size.width - 0.5) { title.layer.mask = nil; return; }
    CAGradientLayer *mask = [title.layer.mask isKindOfClass:CAGradientLayer.class] ? (CAGradientLayer *)title.layer.mask : nil;
    if (!mask) {
        mask = [CAGradientLayer layer];
        mask.colors = @[(id)UIColor.whiteColor.CGColor, (id)UIColor.whiteColor.CGColor, (id)UIColor.clearColor.CGColor];
        mask.startPoint = CGPointMake(0, 0.5);
        mask.endPoint = CGPointMake(1, 0.5);
        title.layer.mask = mask;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.frame = CGRectMake(0, 0, width, title.bounds.size.height);
    mask.locations = @[@0, @((width - MIN(kTitleFade, width)) / width), @1];
    [CATransaction commit];
}

static void putBackTitle(BOOL animated) {
    UIView *title = sg_title;
    if (!title) return;
    void (^back)(void) = ^{ title.transform = CGAffineTransformIdentity; };
    if (animated && !calm()) [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState animations:back completion:nil];
    else back();
    title.layer.mask = nil;
}

static void putBackCover(BOOL animated) {
    UIView *tilt = sg_hiddenTilt;
    sg_hiddenTilt = nil;
    if (!tilt) return;
    CGFloat alpha = sg_tiltAlpha > 0.01 ? sg_tiltAlpha : 1;
    if (animated && !calm()) [UIView animateWithDuration:0.35 animations:^{ tilt.alpha = alpha; }];
    else tilt.alpha = alpha;
}

static void closeStage(BOOL animated) {
    UIImageView *thumb = sg_thumb;
    UIView *tilt = sg_hiddenTilt;
    // The thumbnail flies back into the cover as the cover comes back.
    if (animated && thumb.superview && tilt.window && !calm()) {
        CGRect back = [tilt convertRect:tilt.bounds toView:thumb.superview];
        [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.88 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            thumb.frame = back;
            thumb.layer.cornerRadius = MRGNowCoverRadius(tilt);
        } completion:^(BOOL f) { if (!sg_open) { thumb.alpha = 0; [thumb removeFromSuperview]; } }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (!sg_open) putBackCover(YES); });
    } else {
        [thumb removeFromSuperview];
        putBackCover(NO);
    }
    putBackTitle(animated);
    sg_open = NO;
}

static void layoutStage(void);
static void stageSoon(void) {
    if (sg_queued) return;
    sg_queued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        sg_queued = NO;
        @try { layoutStage(); } @catch (NSException *e) { MRGDJLog(@"lyrics backdrop: layout threw %@", e.reason); }
    });
}

static MRGLyricsBackdropView *linesView(void) {
    if (!sg_lines) {
        sg_lines = [MRGLyricsBackdropView new];
        sg_lines.onChange = ^{ stageSoon(); };
    }
    return sg_lines;
}

static void layoutStage(void) {
    UIView *tilt = sg_tilt;
    BOOL on = MRGAddonInstalled(kAddon) && haveVitrine() && tilt.window;
    BOOL vitrineOpen = sgVitrineLyricsOpen && sgVitrineLyricsOpen();   // Vitrine's own lyrics view has the stage
    MRGLyricsBackdropView *lines = linesView();
    if (!on || vitrineOpen) {
        if (sg_open) closeStage(on);
        lines.hidden = YES;
        if (!on) { [lines removeFromSuperview]; [lines changed]; }
        return;
    }
    lines.hidden = NO;
    UIImage *art = MRGNowCoverImage(tilt);
    lines.activeColor = coverColored() && art ? MRGNowVividColor(art) : nil;

    if (coverMode() == MRGBackdropBehind) {
        if (sg_open) closeStage(NO);
        UIView *cover = MRGNowCoverIn(tilt);
        if (!cover) return;
        lines.dims = YES;
        if (lines.superview != cover) { [lines removeFromSuperview]; [cover addSubview:lines]; }
        lines.frame = cover.bounds;
        lines.layer.cornerRadius = MRGNowCoverRadius(tilt);
        [lines changed];
        return;
    }

    // Beside the title.
    UIView *info = sg_infoUnit.viewIfLoaded;
    UIView *title = info.window ? titleElementIn(info) : nil;
    if (title != sg_title) { putBackTitle(NO); sg_title = title; }
    UIView *host = commonAncestor(tilt, title ?: info);
    lines.dims = NO;
    lines.layer.cornerRadius = 0;
    if (!host) return;
    if (lines.superview != host) { [lines removeFromSuperview]; [host addSubview:lines]; }
    CGRect cover = untransformedIn(tilt, host);
    CGRect titleRect = title ? untransformedIn(title, host) : CGRectNull;
    CGFloat left = title ? CGRectGetMinX(titleRect) : CGRectGetMinX(cover);
    CGFloat right = title ? MAX(CGRectGetMaxX(cover), host.bounds.size.width - left) : CGRectGetMaxX(cover);
    right = MIN(right, host.bounds.size.width - left);
    CGFloat bottom = title ? CGRectGetMinY(titleRect) - 10 : CGRectGetMaxY(cover);
    lines.frame = CGRectIntegral(CGRectMake(left, CGRectGetMinY(cover), MAX(0, right - left), MAX(0, bottom - CGRectGetMinY(cover))));
    [lines changed];
    BOOL open = lines.hasLines && title;
    if (!open) { if (sg_open) closeStage(YES); return; }

    // The cover steps out of the way, and its picture shrinks to the left of the title row.
    CGFloat side = round(MIN(56, MAX(40, titleRect.size.height)));
    CGRect thumbFrame = CGRectMake(left, round(CGRectGetMidY(titleRect) - side / 2), side, side);
    if (!sg_thumb) {
        sg_thumb = [UIImageView new];
        sg_thumb.contentMode = UIViewContentModeScaleAspectFill;
        sg_thumb.clipsToBounds = YES;
        sg_thumb.userInteractionEnabled = NO;
        sg_thumb.layer.cornerCurve = kCACornerCurveContinuous;
        sg_thumb.accessibilityElementsHidden = YES;
    }
    UIImageView *thumb = sg_thumb;
    if (art && thumb.image != art) thumb.image = art;
    BOOL arriving = !sg_open || thumb.superview != host;
    if (thumb.superview != host) { [thumb removeFromSuperview]; [host addSubview:thumb]; }
    if (sg_hiddenTilt != tilt) {
        putBackCover(NO);
        sg_hiddenTilt = tilt;
        sg_tiltAlpha = tilt.alpha;
    }
    tilt.alpha = 0;
    CGFloat shift = side + kThumbGap;
    CGFloat room = trailingLimit(title, host) - (CGRectGetMinX(titleRect) + shift) - 6;
    void (^place)(void) = ^{
        thumb.frame = thumbFrame;
        thumb.layer.cornerRadius = 6;
        thumb.alpha = 1;
        title.transform = CGAffineTransformMakeTranslation(shift, 0);
    };
    if (arriving && !calm()) {
        thumb.frame = cover;
        thumb.layer.cornerRadius = MRGNowCoverRadius(tilt);
        thumb.alpha = 1;
        [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState animations:place completion:nil];
    } else if (!CGRectEqualToRect(thumb.frame, thumbFrame) || !CGAffineTransformEqualToTransform(title.transform, CGAffineTransformMakeTranslation(shift, 0))) {
        [UIView performWithoutAnimation:place];
    }
    clipTitle(title, room);
    [host bringSubviewToFront:lines];
    [host bringSubviewToFront:thumb];
    sg_open = YES;
}

// The cover in the middle of the screen (the list keeps the songs before and after laid out off to the sides).
static void coverLaidOut(UIView *tilt) {
    if (!MRGAddonInstalled(kAddon)) { if (sg_open || sg_lines.superview) stageSoon(); return; }
    if (!tilt.window) return;
    CGRect r = [tilt convertRect:tilt.bounds toView:nil];
    if (fabs(CGRectGetMidX(r) - CGRectGetMidX(tilt.window.bounds)) > tilt.window.bounds.size.width * 0.25) return;
    if (sg_tilt != tilt && sg_hiddenTilt && sg_hiddenTilt != tilt) putBackCover(NO);
    sg_tilt = tilt;
    stageSoon();
}

@interface MRGLyricsBackdropAddon : NSObject <MRGAddon>
@end
@implementation MRGLyricsBackdropAddon
- (NSString *)addonID { return kAddon; }
- (NSString *)addonName { return @"Lyrics backdrop"; }
- (NSString *)addonCategory { return @"Now Playing"; }
- (NSString *)addonVersion { return @"2.0"; }
- (NSString *)addonDescription { return @"The cover moves beside the title and big synced lyrics take its place."; }
- (NSInteger)addonBatteryImpact { return 2; }
- (NSString *)addonBatteryNote { return @"Higher: redraws the lyrics 10 times a second while Now Playing is open."; }
- (NSArray<MRGAddonSetting *> *)addonSettings {
    MRGAddonSetting *cover = [MRGAddonSetting picker:@"cover" title:@"The cover" options:@[@"Beside the title", @"Dimmed behind"] values:@[@0, @1] fallback:@0];
    cover.footer = @"Beside the title shrinks the cover next to the song's name and gives the lyrics its space.";
    MRGAddonSetting *size = [MRGAddonSetting slider:@"size" title:@"Text size" min:20 max:36 fallback:28];
    size.live = YES;
    MRGAddonSetting *align = [MRGAddonSetting picker:@"align" title:@"Lines" options:@[@"Left", @"Centered"] values:@[@0, @1] fallback:@0];
    MRGAddonSetting *color = [MRGAddonSetting picker:@"color" title:@"Line being sung" options:@[@"White", @"Cover color"] values:@[@0, @1] fallback:@0];
    MRGAddonSetting *dim = [MRGAddonSetting slider:@"dim" title:@"Dimming (Dimmed behind)" min:0.3 max:0.85 fallback:0.6];
    dim.live = YES;
    dim.footer = !MRGNowKitRunning() ? @"Off on this Spotify build (see About)." : haveVitrine() ? @"Uses Vitrine's synced lyrics. Songs without timed lyrics keep the normal cover." : @"Needs Vitrine's lyrics, which aren't loaded.";
    return @[cover, size, align, color, dim];
}
- (void)addonDidEnable { dispatch_async(dispatch_get_main_queue(), ^{ @try { MRGNowRelayout(); stageSoon(); } @catch (NSException *e) {} }); }
- (void)addonDidDisable { dispatch_async(dispatch_get_main_queue(), ^{ @try { stageSoon(); } @catch (NSException *e) {} }); }
- (NSString *)addonSummary {
    if (!haveVitrine()) return @"Needs Vitrine";
    return coverMode() == MRGBackdropBehind ? @"Dimmed behind" : @"Beside the title";
}
@end

__attribute__((constructor)) static void MRGLyricsBackdropInit(void) {
    MRGAddonRegister([MRGLyricsBackdropAddon new]);
    MRGNowAddCoverClient(^(UIView *tilt) { coverLaidOut(tilt); });
    MRGNowAddPartClient(^(MRGNowPart part, id owner) {
        if (part != MRGNowInfo || ![owner isKindOfClass:UIViewController.class]) return;
        sg_infoUnit = owner;
        // Right away as well as after the pass: Vitrine puts the title row back on each of its layout passes, so
        // the title is moved again in the same pass and never flickers back for a frame.
        if (sg_open && MRGAddonInstalled(kAddon)) { @try { layoutStage(); } @catch (NSException *e) {} }
        if (MRGAddonInstalled(kAddon) || sg_open) stageSoon();
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:MRGSettingsChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            @try { stageSoon(); } @catch (NSException *e) {}
        }];
    });
}
