// Pop-up lyrics: a lyrics shelf on Home, Apple Music style. It is a section of the feed, not an overlay: the feed's
// collection view (Home_CarouselKit.TouchCancellingCollectionView, inset 112pt at the top for Spotify's header) is
// given that much more top inset and the shelf sits in the room it makes, so every shelf below moves down and the
// lyrics scroll away with the feed like any other row. No synced lyrics, an ad, or nothing playing: the room closes.
//
// The lines are Vitrine's own (SGKaraokeLinesForTrack, SGKaraokeLeadLine, SGKaraokePositionMs, SGKaraokeLineText),
// looked up at runtime, so Mirage still runs without Vitrine (the shelf then stays closed). The active line is large
// and bright; the others are smaller, dimmer and softly blurred, and the column springs to each new line. In Low
// Power Mode the lines step without the spring or the blur, and the clock ticks twice a second instead of ten times.
// Tapping the shelf opens the player through Spotify's own now playing bar.
#import "Addons/MRGPopupLyrics.h"
#import "Addons/MRGAddon.h"
#import "MRGAddons.h"
#import "MRGPlayer.h"
#import "MRGPrefs.h"
#import "MRGDJLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

static NSString *const kAddon = @"popup-lyrics";
static char kShelfKey;

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
static BOOL sgLooked;

static void resolveSymbols(void) {
    if (sgLooked) return;
    sgLooked = YES;
    sgLines = dlsym(RTLD_DEFAULT, "SGKaraokeLinesForTrack");
    sgLead = dlsym(RTLD_DEFAULT, "SGKaraokeLeadLine");
    sgPos = dlsym(RTLD_DEFAULT, "SGKaraokePositionMs");
    sgTrack = dlsym(RTLD_DEFAULT, "SGKaraokePlayingTrack");
    sgAsk = dlsym(RTLD_DEFAULT, "SGKaraokeRequestLyrics");
    sgText = dlsym(RTLD_DEFAULT, "SGKaraokeLineText");
}

static CGFloat fontSize(void) { return MIN(30, MAX(18, MRGAddonNumber(kAddon, @"size", 24))); }
// Glass clarity: 0 is almost clear (the background shows straight through), 1 is fully frosted. Tint is how much
// of the accent washes over it. Both apply live.
static CGFloat frost(void) { return MIN(1, MAX(0, MRGAddonNumber(kAddon, @"frost", 0.3))); }
static CGFloat tintAmount(void) { return MIN(0.5, MAX(0, MRGAddonNumber(kAddon, @"tint", 0.10))); }

static NSInteger linesShown(void) { return MIN(5, MAX(3, MRGAddonInteger(kAddon, @"lines", 4))); }
static BOOL lowPower(void) { return NSProcessInfo.processInfo.isLowPowerModeEnabled; }

// The section's height: the card plus the gap to the shelf under it.
static const CGFloat kTopGap = 4, kBottomGap = 18, kHeader = 46, kLineGap = 10;
static CGFloat clipHeight(void) { return ceil(fontSize() * 1.25 + kLineGap) * linesShown(); }
static CGFloat cardHeight(void) { return kHeader + clipHeight() + 14; }
static CGFloat sectionHeight(void) { return kTopGap + cardHeight() + kBottomGap; }

#pragma mark - blur (Core Animation's gaussian blur filter, used when the class is there; never required)

static id blurFilter(CGFloat radius) {
    static Class filterClass;
    static BOOL looked;
    if (!looked) { looked = YES; filterClass = NSClassFromString(@"CAFilter"); }
    if (!filterClass || ![filterClass respondsToSelector:NSSelectorFromString(@"filterWithType:")]) return nil;
    @try {
        id f = ((id (*)(id, SEL, NSString *))objc_msgSend)(filterClass, NSSelectorFromString(@"filterWithType:"), @"gaussianBlur");
        [f setValue:@(radius) forKey:@"inputRadius"];
        return f;
    } @catch (NSException *e) { return nil; }
}

static void setBlur(UIView *v, CGFloat radius) {
    @try {
        if (radius <= 0.05) { if (v.layer.filters.count) v.layer.filters = nil; return; }
        id f = blurFilter(radius);
        v.layer.filters = f ? @[f] : nil;
    } @catch (NSException *e) {}
}

#pragma mark - opening the player

static UIView *findIdentifier(UIView *root, NSString *ident) {
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger seen = 0;
    while (stack.count && seen < 4000) {
        UIView *v = stack.lastObject; [stack removeLastObject]; seen++;
        if ([v.accessibilityIdentifier isEqualToString:ident]) return v;
        [stack addObjectsFromArray:v.subviews];
    }
    return nil;
}

// The now playing bar answers VoiceOver's activate by opening the player, the same as a tap; a control inside it
// (the bar in some layouts) fires its own action. NO when the bar isn't on screen.
static BOOL openPlayer(UIView *from) {
    UIView *bar = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) { bar = findIdentifier(w, @"SPTNowPlayingBar"); if (bar) break; }
        if (bar) break;
    }
    if (!bar || !bar.window || bar.hidden) return NO;
    @try {
        if ([bar isKindOfClass:UIControl.class]) { [(UIControl *)bar sendActionsForControlEvents:UIControlEventTouchUpInside]; return YES; }
        if ([bar accessibilityActivate]) return YES;
        for (UIGestureRecognizer *g in bar.gestureRecognizers) if ([g isKindOfClass:UITapGestureRecognizer.class] && g.enabled) { MRGDJLog(@"pop-up lyrics: the bar has a tap recognizer only"); break; }
    } @catch (NSException *e) { MRGDJLog(@"pop-up lyrics: opening the player threw %@", e.reason); }
    return NO;
}

#pragma mark - the card

@interface MRGLyricsShelf : UIView
@property (nonatomic, readonly) BOOL wantsRoom;
@property (nonatomic, copy) void (^roomChanged)(void);
- (void)changed;
@end

// The card's material. Vitrine's own glass when it is loaded (the same effect its redesign uses, so the card matches
// the rest of the app), else UIGlassEffect on iOS 26, else an ultra-thin dark material blur. `liquid` says whether
// the result is real glass (it shapes itself with a corner configuration and needs no border).
static UIVisualEffect *glassEffect(BOOL *liquid, BOOL clear) {
    Class glass = NSClassFromString(@"UIGlassEffect");
    BOOL haveGlass = [glass respondsToSelector:@selector(effectWithStyle:)];
    UIVisualEffect *(*vitrine)(void) = (UIVisualEffect *(*)(void))dlsym(RTLD_DEFAULT, "SGGlassEffect");
    UIVisualEffect *e = nil;
    // Clear glass (UIGlassEffectStyleClear, 1) for the clearer half of the slider; Vitrine's regular glass otherwise.
    if (vitrine && haveGlass && !clear) { @try { e = vitrine(); } @catch (NSException *x) {} }
    if (![e isKindOfClass:UIVisualEffect.class] && haveGlass) {
        @try { e = ((id (*)(id, SEL, NSInteger))objc_msgSend)(glass, @selector(effectWithStyle:), clear ? 1 : 0); } @catch (NSException *x) { e = nil; }
    }
    if ([e isKindOfClass:UIVisualEffect.class] && glass && [e isKindOfClass:glass]) {
        if (liquid) *liquid = YES;
        return e;
    }
    if (liquid) *liquid = NO;
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
}

static void shapeGlass(UIVisualEffectView *v, CGFloat radius) {
    void (*vitrine)(UIView *, CGFloat, BOOL) = (void (*)(UIView *, CGFloat, BOOL))dlsym(RTLD_DEFAULT, "SGShapeGlass");
    if (vitrine) { @try { vitrine(v, radius, NO); return; } @catch (NSException *x) {} }
    Class config = NSClassFromString(@"UICornerConfiguration"), corner = NSClassFromString(@"UICornerRadius");
    if ([v respondsToSelector:@selector(setCornerConfiguration:)] && [config respondsToSelector:@selector(configurationWithUniformRadius:)] && [corner respondsToSelector:@selector(fixedRadius:)]) {
        @try {
            id r = ((id (*)(id, SEL, CGFloat))objc_msgSend)(corner, @selector(fixedRadius:), radius);
            id shape = r ? ((id (*)(id, SEL, id))objc_msgSend)(config, @selector(configurationWithUniformRadius:), r) : nil;
            if (shape) { ((void (*)(id, SEL, id))objc_msgSend)(v, @selector(setCornerConfiguration:), shape); return; }
        } @catch (NSException *x) {}
    }
    v.layer.cornerRadius = radius;
}

// A soft shadow keeps white text readable over a clear card on a bright background.
static void shadowText(UILabel *l) {
    l.layer.shadowColor = UIColor.blackColor.CGColor;
    l.layer.shadowOpacity = 0.45;
    l.layer.shadowRadius = 3;
    l.layer.shadowOffset = CGSizeMake(0, 1);
}

@implementation MRGLyricsShelf {
    UIVisualEffectView *_glass;
    UIVisualEffectView *_frost;   // a real blur under liquid glass, faded in by Glass clarity
    UIView *_wash;                // the tint, under the glass so the glass shows it through
    CGFloat _shownFrost, _shownTint;
    NSInteger _shownTintRGB;
    BOOL _liquid;          // UIGlassEffect (iOS 26), else a thin material blur
    BOOL _clearGlass;      // the clear glass style is in use
    CAGradientLayer *_tint, *_fade;
    UIImageView *_icon;
    UILabel *_kicker, *_song;
    UIImageView *_open;
    UIView *_clip, *_column;
    NSMutableArray<UILabel *> *_labels;
    NSArray *_lines;
    NSString *_track, *_asked;
    NSInteger _active;
    CGFloat _builtWidth, _builtFont;
    NSTimer *_timer;
    BOOL _wants;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _active = NSIntegerMin;
    _labels = [NSMutableArray array];
    self.layer.cornerRadius = 22;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    // Liquid glass, so the background shows through: no shadow (a layer shadow is drawn under the whole card and
    // darkens what the glass shows) and no fill, only the faintest accent wash.
    self.backgroundColor = UIColor.clearColor;
    _liquid = NO;
    _clearGlass = frost() < 0.5;
    _glass = [[UIVisualEffectView alloc] initWithEffect:glassEffect(&_liquid, _clearGlass)];
    _glass.layer.cornerCurve = kCACornerCurveContinuous;
    shapeGlass(_glass, 22);
    if (!_liquid) {
        _glass.clipsToBounds = YES;
        _glass.layer.borderWidth = 0.5;
        _glass.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    }
    _frost = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    _frost.userInteractionEnabled = NO;
    _frost.clipsToBounds = YES;
    _frost.layer.cornerRadius = 22;
    _frost.layer.cornerCurve = kCACornerCurveContinuous;
    _frost.alpha = 0;
    _wash = [UIView new];
    _wash.userInteractionEnabled = NO;
    _wash.layer.cornerRadius = 22;
    _wash.layer.cornerCurve = kCACornerCurveContinuous;
    _shownFrost = _shownTint = -1;
    _shownTintRGB = -1;
    [self addSubview:_frost];
    [self addSubview:_wash];
    [self addSubview:_glass];
    _tint = [CAGradientLayer layer];
    _tint.startPoint = CGPointMake(0, 0);
    _tint.endPoint = CGPointMake(1, 1);
    _tint.cornerRadius = 22;
    _tint.cornerCurve = kCACornerCurveContinuous;
    _tint.masksToBounds = YES;
    [_glass.contentView.layer addSublayer:_tint];
    _icon = [UIImageView new];
    _icon.contentMode = UIViewContentModeScaleAspectFit;
    _icon.image = [UIImage systemImageNamed:@"quote.bubble.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightBold]];
    _kicker = [UILabel new];
    _kicker.text = @"LYRICS";
    _kicker.font = [UIFont systemFontOfSize:12 weight:UIFontWeightHeavy];
    _kicker.textColor = UIColor.whiteColor;
    shadowText(_kicker);
    _song = [UILabel new];
    _song.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _song.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    shadowText(_song);
    _open = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]]];
    _open.tintColor = [UIColor colorWithWhite:1 alpha:0.55];
    _open.contentMode = UIViewContentModeCenter;
    _clip = [UIView new];
    _clip.clipsToBounds = YES;
    _fade = [CAGradientLayer layer];
    _fade.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
    _fade.locations = @[@0, @0.16, @0.8, @1];
    _clip.layer.mask = _fade;
    _column = [UIView new];
    [_clip addSubview:_column];
    for (UIView *v in @[_icon, _kicker, _song, _open, _clip]) [_glass.contentView addSubview:v];
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)]];
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityHint = @"Opens the player";
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

- (BOOL)wantsRoom { return _wants; }

- (void)tapped {
    [[UIImpactFeedbackGenerator new] impactOccurred];
    if (!openPlayer(self)) MRGDJLog(@"pop-up lyrics: no now playing bar to open");
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    _glass.frame = b;
    _frost.frame = b;
    _wash.frame = b;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    UIColor *accent = [self tintColorNow];
    _tint.frame = b;
    // The sheen over the text: strongest top-left, still there across the card (0.6.6 faded to nothing by the middle).
    CGFloat top = tintAmount();
    _tint.colors = @[(id)[accent colorWithAlphaComponent:top].CGColor, (id)[accent colorWithAlphaComponent:top * 0.6].CGColor, (id)[accent colorWithAlphaComponent:top * 0.35].CGColor];
    [CATransaction commit];
    CGFloat pad = 16;
    _icon.frame = CGRectMake(pad, 14, 22, 22);
    _icon.tintColor = MRGAccent();
    [_kicker sizeToFit];
    _kicker.frame = CGRectMake(CGRectGetMaxX(_icon.frame) + 8, 14, _kicker.bounds.size.width, 22);
    _open.frame = CGRectMake(b.size.width - pad - 22, 14, 22, 22);
    CGFloat sx = CGRectGetMaxX(_kicker.frame) + 8;
    _song.frame = CGRectMake(sx, 14, MAX(0, CGRectGetMinX(_open.frame) - 8 - sx), 22);
    CGRect clip = CGRectMake(pad, kHeader, b.size.width - 2 * pad, clipHeight());
    if (!CGRectEqualToRect(_clip.frame, clip)) {
        _clip.frame = clip;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _fade.frame = _clip.bounds;
        [CATransaction commit];
    }
    if (fabs(_builtWidth - clip.size.width) > 0.5 || fabs(_builtFont - fontSize()) > 0.1) [self rebuild];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self changed];
}

// What should be up: the lines of the playing song, or nothing (the section closes).
- (UIColor *)tintColorNow { return MRGAccent(); }

// Clarity and tint, live. 0.6.7 root cause of "the sliders change nothing": on iOS 26 the card is real glass, and
// 0.6.6 only swapped the glass style when Clarity crossed the middle (the fade it did is skipped for real glass), and
// the tint was a faint corner gradient inside the glass's content, under the glass's own rendering. Now Clarity fades
// a real blur in under the glass across the whole slider, and Tint colors a wash under the glass, the glass's own
// tint (iOS 26) and the sheen over the text, all at once.
- (void)applyGlass {
    CGFloat f = frost(), t = tintAmount();
    UIColor *color = [self tintColorNow];
    CGFloat r = 0, g = 0, bl = 0, a = 0;
    [color getRed:&r green:&g blue:&bl alpha:&a];
    NSInteger rgb = ((NSInteger)lround(r * 255) << 16) | ((NSInteger)lround(g * 255) << 8) | (NSInteger)lround(bl * 255);
    BOOL clear = f < 0.5;
    BOOL restyle = _liquid && (clear != _clearGlass || fabs(t - _shownTint) > 0.004 || rgb != _shownTintRGB);
    if (restyle) {
        _clearGlass = clear;
        BOOL liquid = NO;
        UIVisualEffect *e = [glassEffect(&liquid, clear) copy];   // a copy: Vitrine's effect may be shared
        if (liquid && e) {
            if (t > 0.005 && [e respondsToSelector:@selector(setTintColor:)]) {
                @try { [(id)e setTintColor:[color colorWithAlphaComponent:MIN(0.6, t * 1.2)]]; } @catch (NSException *x) {}
            }
            _glass.effect = e;
        }
    }
    _shownTint = t;
    _shownTintRGB = rgb;
    _shownFrost = f;
    // Real glass is never faded (it would lose its edge): the blur under it is. The blur fallback fades itself.
    _frost.hidden = !_liquid;
    _frost.alpha = _liquid ? f : 0;
    _glass.alpha = _liquid ? 1 : 0.12 + 0.88 * f;
    _wash.backgroundColor = [color colorWithAlphaComponent:MIN(0.55, t * 1.1)];
    [self setNeedsLayout];
}

- (void)changed {
    @try {
        [self applyGlass];
        resolveSymbols();
        NSDictionary *playing = MRGNowPlaying();
        BOOL song = MRGAddonInstalled(kAddon) && playing && ![playing[@"ad"] boolValue] && sgLines && sgLead && sgText;
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
        NSString *title = playing[@"title"], *artist = playing[@"artist"];
        _song.text = title.length ? (artist.length ? [NSString stringWithFormat:@"%@ · %@", title, artist] : title) : nil;
        self.accessibilityLabel = _song.text.length ? [@"Lyrics, " stringByAppendingString:_song.text] : @"Lyrics";
        if (fresh) { _active = NSIntegerMin; [self rebuild]; }
        BOOL wants = song && lines.count > 0;
        if (wants != _wants) { _wants = wants; if (self.roomChanged) self.roomChanged(); }
        [self updateTimer];
        [self tick];
    } @catch (NSException *e) {
        MRGDJLog(@"pop-up lyrics: refresh threw %@", e.reason);
    }
}

- (void)updateTimer {
    BOOL run = _wants && self.window && UIApplication.sharedApplication.applicationState != UIApplicationStateBackground;
    NSTimeInterval every = lowPower() ? 0.5 : 0.1;
    if (run && _timer && fabs(_timer.timeInterval - every) < 0.01) return;
    [_timer invalidate];
    _timer = nil;
    if (!run) return;
    __weak MRGLyricsShelf *weak = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:every repeats:YES block:^(NSTimer *t) {
        MRGLyricsShelf *s = weak;
        if (!s || !s.window) { [t invalidate]; return; }
        @try { [s tick]; } @catch (NSException *e) {}
    }];
    _timer.tolerance = every * 0.2;
}

- (UIFont *)lineFont { return [UIFont systemFontOfSize:fontSize() weight:UIFontWeightHeavy]; }

- (void)rebuild {
    for (UILabel *l in _labels) [l removeFromSuperview];
    [_labels removeAllObjects];
    CGFloat w = _clip.bounds.size.width;
    _builtWidth = w;
    _builtFont = fontSize();
    _active = NSIntegerMin;
    if (w < 40 || !_lines.count || !sgText) return;
    UIFont *font = [self lineFont];
    CGFloat y = 0;
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
        shadowText(l);
        CGFloat h = ceil([l sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)].height);
        // Scaled about the leading edge, so a dimmed line stays aligned with the active one.
        l.layer.anchorPoint = CGPointMake(0, 0.5);
        l.bounds = CGRectMake(0, 0, w, h);
        l.layer.position = CGPointMake(0, y + h / 2);
        l.alpha = 0;
        [_column addSubview:l];
        [_labels addObject:l];
        y += h + kLineGap;
    }
    _column.frame = CGRectMake(0, 0, w, y);
}

- (void)tick {
    if (!_wants || !_labels.count || !sgLead) return;
    NSInteger ms = sgPos ? sgPos() : 0;
    NSInteger index = ms >= 0 ? sgLead(_lines, ms) : -1;
    if (index >= (NSInteger)_labels.count) index = (NSInteger)_labels.count - 1;
    if (index == _active) return;
    BOOL first = _active == NSIntegerMin;
    _active = index;
    [self showActive:!first && self.window != nil];
}

// The column moves so the active line sits a little above the middle; every line's size, brightness and blur
// follow its distance from it. Before the first line (index -1) the first lines wait, all dimmed.
- (void)showActive:(BOOL)animated {
    NSInteger a = _active;
    NSInteger anchor = MAX(0, a);
    UILabel *target = _labels[MIN((NSUInteger)anchor, _labels.count - 1)];
    CGFloat targetY = _clip.bounds.size.height * 0.36 - target.layer.position.y;
    BOOL calm = lowPower() || UIAccessibilityIsReduceMotionEnabled();
    void (^apply)(void) = ^{
        CGRect f = self->_column.frame;
        f.origin.y = round(targetY);
        self->_column.frame = f;
        for (NSInteger i = 0; i < (NSInteger)self->_labels.count; i++) {
            UILabel *l = self->_labels[i];
            NSInteger d = a < 0 ? i + 1 : labs(i - a);
            BOOL past = a >= 0 && i < a;
            CGFloat alpha = d == 0 ? 1 : d == 1 ? (past ? 0.34 : 0.46) : d == 2 ? 0.26 : d <= 4 ? 0.14 : 0;
            CGFloat scale = d == 0 ? 1 : 0.86;
            l.alpha = alpha;
            l.transform = CGAffineTransformMakeScale(scale, scale);
        }
    };
    if (animated && !calm) {
        [UIView animateWithDuration:0.7 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.2
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:apply completion:nil];
    } else if (animated) {
        [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:apply completion:nil];
    } else {
        [UIView performWithoutAnimation:apply];
    }
    // Blur on the lines around the active one only; none in Low Power Mode or with Reduce Motion.
    for (NSInteger i = 0; i < (NSInteger)_labels.count; i++) {
        NSInteger d = a < 0 ? i + 1 : labs(i - a);
        setBlur(_labels[i], (calm || d == 0 || d > 4) ? 0 : (d == 1 ? 1.1 : 2.2));
    }
}
@end

#pragma mark - the room in Home's feed

// Home's feed: the page's tall collection view (Home_CarouselKit.TouchCancellingCollectionView), not a shelf's own.
static UICollectionView *feedIn(UIView *page) {
    UICollectionView *best = nil;
    CGFloat bestH = 0;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:page];
    NSUInteger seen = 0;
    while (stack.count && seen < 600) {
        UIView *v = stack.firstObject; [stack removeObjectAtIndex:0]; seen++;
        if ([v isKindOfClass:UICollectionView.class]) {
            if ([NSStringFromClass(v.class) containsString:@"TouchCancelling"]) return (UICollectionView *)v;
            if (v.bounds.size.height > bestH && v.bounds.size.height >= page.bounds.size.height * 0.6) { best = (UICollectionView *)v; bestH = v.bounds.size.height; }
            continue;   // a shelf's carousel is inside the feed, not another feed
        }
        [stack addObjectsFromArray:v.subviews];
    }
    return best;
}

// The room is added inside the feed's own contentInset accessors (MRGPopupLyrics.x): the setter adds it, the getter
// takes it back off. Spotify keeps setting the inset it wants (on every layout of the page) and always reads back
// exactly that, so nobody fights over the value. 0.6.2 watched the inset with KVO and set it again whenever Spotify
// did; each set laid the page out again, Spotify set its inset again, and Home could spin in that loop.
static char kRoomKey;
static __unsafe_unretained Class sFeedClass;

CGFloat MRGShelfRoom(UIScrollView *list) {
    if (!sFeedClass || [list class] != sFeedClass) return 0;
    NSNumber *room = objc_getAssociatedObject(list, &kRoomKey);
    return room ? room.doubleValue : 0;
}

static void setRoom(UICollectionView *feed, CGFloat room) {
    objc_setAssociatedObject(feed, &kRoomKey, room > 0 ? @(room) : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CGPoint shelfCenter(CGFloat width, CGFloat want) {
    CGFloat h = cardHeight();
    // Closed: parked just above the first shelf, out of sight.
    return CGPointMake(width / 2, want > 0 ? -want + kTopGap + h / 2 : -kBottomGap - h / 2);
}

void MRGShelfLayout(UICollectionView *feed, BOOL animated) {
    if (!feed) return;
    MRGLyricsShelf *shelf = objc_getAssociatedObject(feed, &kShelfKey);
    @try {
        CGFloat want = (shelf && shelf.wantsRoom && MRGAddonInstalled(kAddon)) ? sectionHeight() : 0;
        CGFloat have = MRGShelfRoom(feed);
        CGFloat width = feed.bounds.size.width;
        if (shelf) {
            CGRect bounds = CGRectMake(0, 0, MAX(100, width - 32), cardHeight());
            if (!CGRectEqualToRect(shelf.bounds, bounds)) shelf.bounds = bounds;
            if (shelf.superview != feed) [feed addSubview:shelf];
        }
        if (fabs(want - have) <= 0.5) {
            if (shelf) {
                CGPoint c = shelfCenter(width, want);
                if (!CGPointEqualToPoint(shelf.center, c)) shelf.center = c;
                CGFloat alpha = want > 0 ? 1 : 0;
                if (shelf.alpha != alpha) shelf.alpha = alpha;
            }
            return;
        }
        BOOL atTop = feed.contentOffset.y <= -feed.adjustedContentInset.top + 2;
        UIEdgeInsets base = feed.contentInset;   // Spotify's own inset (the getter leaves the room out)
        setRoom(feed, want);
        void (^change)(void) = ^{
            feed.contentInset = base;            // the setter adds the new room
            // At the top the room opens in view and pushes the shelves down; scrolled away, nothing on screen moves.
            if (atTop) feed.contentOffset = CGPointMake(feed.contentOffset.x, -feed.adjustedContentInset.top);
            if (shelf) {
                shelf.center = shelfCenter(width, want);
                shelf.alpha = want > 0 ? 1 : 0;
            }
        };
        if (animated && !lowPower() && feed.window)
            [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:change completion:nil];
        else [UIView performWithoutAnimation:change];
    } @catch (NSException *e) {
        MRGDJLog(@"pop-up lyrics: feed layout threw %@", e.reason);
    }
}

static NSHashTable<UIView *> *sPages;

// The page's feed, found once and remembered weakly (the search walks up to 600 views; it used to run on every
// layout pass of Home). With the add-on off and no shelf ever made, nothing is searched at all.
@interface MRGFeedBox : NSObject
@property (nonatomic, weak) id value;
@end
@implementation MRGFeedBox
@end
static char kFeedKey;

void MRGPopupPlace(UIView *page) {
    if (![page isKindOfClass:UIView.class]) return;
    MRGFeedBox *box = objc_getAssociatedObject(page, &kFeedKey);
    UICollectionView *feed = box.value;
    if (!feed || ![feed isDescendantOfView:page]) {
        if (!box && !MRGAddonInstalled(kAddon)) return;
        feed = feedIn(page);
        if (!feed) return;
        if (!box) { box = [MRGFeedBox new]; objc_setAssociatedObject(page, &kFeedKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        box.value = feed;
    }
    MRGLyricsShelf *shelf = objc_getAssociatedObject(feed, &kShelfKey);
    if (!shelf) {
        if (!MRGAddonInstalled(kAddon)) return;
        sFeedClass = [feed class];
        if (!sPages) sPages = [NSHashTable weakObjectsHashTable];
        [sPages addObject:page];
        shelf = [MRGLyricsShelf new];
        shelf.alpha = 0;
        __weak UICollectionView *weakFeed = feed;
        shelf.roomChanged = ^{ MRGShelfLayout(weakFeed, YES); };
        objc_setAssociatedObject(feed, &kShelfKey, shelf, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [feed addSubview:shelf];
        [shelf changed];
    }
    MRGShelfLayout(feed, NO);
}

@interface MRGPopupAddon : NSObject <MRGAddon>
@end
@implementation MRGPopupAddon
- (NSString *)addonID { return kAddon; }
- (NSString *)addonName { return @"Pop-up lyrics"; }
- (NSString *)addonCategory { return @"Home"; }
- (NSString *)addonVersion { return @"2.0"; }
- (NSString *)addonDescription { return @"A synced lyrics shelf at the top of Home, Apple Music style."; }
- (NSArray<MRGAddonSetting *> *)addonSettings {
    MRGAddonSetting *size = [MRGAddonSetting slider:@"size" title:@"Text size" min:18 max:30 fallback:24];
    MRGAddonSetting *lines = [MRGAddonSetting picker:@"lines" title:@"Lines shown" options:@[@"3", @"4", @"5"] values:@[@3, @4, @5] fallback:@4];
    MRGAddonSetting *clarity = [MRGAddonSetting slider:@"frost" title:@"Glass clarity" min:0 max:1 fallback:0.3];
    clarity.footer = @"Left is clear glass, right is fully frosted.";
    clarity.live = YES;
    MRGAddonSetting *tint = [MRGAddonSetting slider:@"tint" title:@"Tint" min:0 max:0.5 fallback:0.10];
    tint.live = YES;
    return @[size, lines, clarity, tint];
}
// On or off takes effect on Home right away: every Home page seen gets its shelf (or loses its room).
static void relayoutHome(void) {
    Class home = NSClassFromString(@"_TtC19Home_FunkisPageImpl20FunkisViewController");
    NSMutableArray *pages = [NSMutableArray arrayWithArray:sPages.allObjects ?: @[]];
    if (home) for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            NSMutableArray *stack = [NSMutableArray arrayWithObject:window];
            NSUInteger seen = 0;
            while (stack.count && seen < 3000) {
                UIView *view = stack.lastObject; [stack removeLastObject]; seen++;
                if ([view.nextResponder isKindOfClass:home]) { if (![pages containsObject:view]) [pages addObject:view]; continue; }
                [stack addObjectsFromArray:view.subviews];
            }
        }
    }
    for (UIView *page in pages) {
        MRGPopupPlace(page);
        UICollectionView *feed = feedIn(page);
        [(MRGLyricsShelf *)objc_getAssociatedObject(feed, &kShelfKey) changed];
        MRGShelfLayout(feed, YES);
    }
}
- (void)addonDidEnable { dispatch_async(dispatch_get_main_queue(), ^{ @try { relayoutHome(); } @catch (NSException *e) {} }); }
- (void)addonDidDisable { dispatch_async(dispatch_get_main_queue(), ^{ @try { relayoutHome(); } @catch (NSException *e) {} }); }
- (NSString *)addonSummary { return [NSString stringWithFormat:@"%ld lines", (long)linesShown()]; }
@end

__attribute__((constructor)) static void mrgPopupConstructor(void) { MRGAddonRegister([MRGPopupAddon new]); }
