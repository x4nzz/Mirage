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
static char kShelfKey, kInsetKey, kWatchKey;

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

@implementation MRGLyricsShelf {
    UIVisualEffectView *_glass;
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
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.35;
    self.layer.shadowRadius = 16;
    self.layer.shadowOffset = CGSizeMake(0, 8);
    _glass = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    _glass.layer.cornerRadius = 22;
    _glass.layer.cornerCurve = kCACornerCurveContinuous;
    _glass.clipsToBounds = YES;
    _glass.layer.borderWidth = 0.5;
    _glass.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
    [self addSubview:_glass];
    _tint = [CAGradientLayer layer];
    _tint.startPoint = CGPointMake(0, 0);
    _tint.endPoint = CGPointMake(1, 1);
    [_glass.contentView.layer addSublayer:_tint];
    _icon = [UIImageView new];
    _icon.contentMode = UIViewContentModeScaleAspectFit;
    _icon.image = [UIImage systemImageNamed:@"quote.bubble.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightBold]];
    _kicker = [UILabel new];
    _kicker.text = @"LYRICS";
    _kicker.font = [UIFont systemFontOfSize:12 weight:UIFontWeightHeavy];
    _kicker.textColor = UIColor.whiteColor;
    _song = [UILabel new];
    _song.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _song.textColor = [UIColor colorWithWhite:1 alpha:0.6];
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
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:b cornerRadius:22].CGPath;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    UIColor *accent = MRGAccent();
    _tint.frame = b;
    _tint.colors = @[(id)[accent colorWithAlphaComponent:0.42].CGColor, (id)[accent colorWithAlphaComponent:0.10].CGColor, (id)[UIColor colorWithWhite:0 alpha:0.25].CGColor];
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
- (void)changed {
    @try {
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

// The extra top inset Mirage put on the feed, and the inset the feed had when Mirage last set it. When Spotify sets
// its own inset again (it does on some layouts), that is taken as the new base and the room is added back on top.
@interface MRGFeedRoom : NSObject
@property (nonatomic) CGFloat ours, lastSet;
@property (nonatomic) BOOL busy;
@property (nonatomic, weak) UICollectionView *feed;
@end
@implementation MRGFeedRoom
- (void)observeValueForKeyPath:(NSString *)key ofObject:(id)object change:(NSDictionary *)change context:(void *)ctx {
    if (self.busy || !self.feed) return;
    MRGShelfLayout(self.feed, NO);
}
@end

void MRGShelfLayout(UICollectionView *feed, BOOL animated) {
    if (!feed) return;
    MRGFeedRoom *room = objc_getAssociatedObject(feed, &kInsetKey);
    MRGLyricsShelf *shelf = objc_getAssociatedObject(feed, &kShelfKey);
    if (!room) {
        if (!shelf) return;
        room = [MRGFeedRoom new];
        room.feed = feed;
        objc_setAssociatedObject(feed, &kInsetKey, room, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try { [feed addObserver:room forKeyPath:@"contentInset" options:0 context:NULL]; objc_setAssociatedObject(feed, &kWatchKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC); } @catch (NSException *e) {}
    }
    if (room.busy) return;
    room.busy = YES;
    @try {
        CGFloat want = (shelf && shelf.wantsRoom && MRGAddonInstalled(kAddon)) ? sectionHeight() : 0;
        UIEdgeInsets inset = feed.contentInset;
        BOOL spotifyReset = room.lastSet != 0 && fabs(inset.top - room.lastSet) > 0.5;
        CGFloat base = spotifyReset ? inset.top : inset.top - room.ours;
        CGFloat width = feed.bounds.size.width;
        if (shelf) {
            CGFloat h = cardHeight();
            shelf.bounds = CGRectMake(0, 0, MAX(100, width - 32), h);
            CGPoint center = CGPointMake(width / 2, -want + kTopGap + h / 2);
            if (want <= 0) center.y = -kBottomGap - h / 2;   // closed: parked just above the first shelf, out of sight
            if (!animated) shelf.center = center;
            if (shelf.superview != feed) [feed addSubview:shelf];
        }
        if (spotifyReset || fabs(room.ours - want) > 0.5) {
            CGFloat delta = want - (spotifyReset ? 0 : room.ours);
            BOOL atTop = feed.contentOffset.y <= -feed.adjustedContentInset.top + 2;
            inset.top = base + want;
            room.ours = want;
            void (^change)(void) = ^{
                feed.contentInset = inset;
                // At the top the room opens in view and pushes the shelves down; scrolled away, nothing on screen moves.
                if (atTop) feed.contentOffset = CGPointMake(feed.contentOffset.x, -feed.adjustedContentInset.top);
                if (shelf) {
                    CGFloat h = cardHeight();
                    shelf.center = CGPointMake(width / 2, want > 0 ? -want + kTopGap + h / 2 : -kBottomGap - h / 2);
                    shelf.alpha = want > 0 ? 1 : 0;
                }
            };
            if (animated && !lowPower() && feed.window && fabs(delta) > 0.5)
                [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:change completion:nil];
            else [UIView performWithoutAnimation:change];
        } else if (shelf) {
            shelf.alpha = want > 0 ? 1 : 0;
        }
        room.lastSet = feed.contentInset.top;
    } @catch (NSException *e) {
        MRGDJLog(@"pop-up lyrics: feed layout threw %@", e.reason);
    }
    room.busy = NO;
}

static NSHashTable<UIView *> *sPages;

void MRGPopupPlace(UIView *page) {
    if (![page isKindOfClass:UIView.class]) return;
    UICollectionView *feed = feedIn(page);
    if (!feed) return;
    MRGLyricsShelf *shelf = objc_getAssociatedObject(feed, &kShelfKey);
    if (!shelf) {
        if (!MRGAddonInstalled(kAddon)) return;
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
- (NSString *)addonDescription { return @"A synced lyrics shelf at the top of Home, Apple Music style: the current line big and bright, the next ones soft, scrolling with the song. It pushes Home down like any shelf, closes when there are no synced lyrics, and opens the player when tapped."; }
- (NSArray<MRGAddonSetting *> *)addonSettings {
    MRGAddonSetting *size = [MRGAddonSetting slider:@"size" title:@"Text size" min:18 max:30 fallback:24];
    MRGAddonSetting *lines = [MRGAddonSetting picker:@"lines" title:@"Lines shown" options:@[@"3", @"4", @"5"] values:@[@3, @4, @5] fallback:@4];
    lines.footer = @"The lines and their timing come from Vitrine's lyrics. The shelf only opens for songs with synced lyrics; in Low Power Mode the lines change without the spring and the blur.";
    return @[size, lines];
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
