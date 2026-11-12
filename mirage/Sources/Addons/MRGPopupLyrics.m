// Pop-up lyrics: Apple Music-style synced lines at the top of Home, using Vitrine's own lyric lines,
// lead line and playback position (SGKaraokeLinesForTrack, SGKaraokeLeadLine, SGKaraokePositionMs).
// The full player lyrics view is not embedded here, so Home's scroll view and the DJ chip stay as they are.
#import "Addons/MRGPopupLyrics.h"
#import "Addons/MRGAddon.h"
#import "MRGAddons.h"
#import "MRGPlayer.h"
#import "MRGPrefs.h"
#import "MRGDJLog.h"
#import <objc/runtime.h>
#import <dlfcn.h>

static NSString *const kAddon = @"popup-lyrics";
static char kViewKey;

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

static NSInteger idleMode(void) { return MRGAddonInteger(kAddon, @"idle", 1); }
static CGFloat fontSize(void) { return MIN(34, MAX(15, MRGAddonNumber(kAddon, @"size", 22))); }

@interface MRGPopupLyricsView : UIView
- (CGFloat)wantedHeight;
- (void)refresh;
@end

@implementation MRGPopupLyricsView {
    UILabel *_now, *_next;
    NSTimer *_timer;
    NSString *_lastShown, *_asked;
}
- (void)dealloc { [_timer invalidate]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    self.layer.cornerRadius = 16;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    _now = [UILabel new];
    _now.textColor = UIColor.whiteColor;
    _now.numberOfLines = 2;
    _next = [UILabel new];
    _next.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    _next.numberOfLines = 1;
    for (UILabel *l in @[_now, _next]) { l.translatesAutoresizingMaskIntoConstraints = NO; [self addSubview:l]; }
    UILayoutGuide *g = self.layoutMarginsGuide;
    self.layoutMargins = UIEdgeInsetsMake(8, 14, 8, 14);
    [NSLayoutConstraint activateConstraints:@[
        [_now.topAnchor constraintEqualToAnchor:g.topAnchor],
        [_now.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_now.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [_next.topAnchor constraintEqualToAnchor:_now.bottomAnchor constant:2],
        [_next.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_next.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [_next.bottomAnchor constraintLessThanOrEqualToAnchor:g.bottomAnchor],
    ]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:MRGPlayerTrackChangedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(changed) name:MRGSettingsChangedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(changed) name:NSProcessInfoPowerStateDidChangeNotification object:nil];
    NSString * __strong *kept = (NSString * __strong *)dlsym(RTLD_DEFAULT, "SGKaraokeLinesKeptNotification");
    if (kept && [*kept isKindOfClass:NSString.class])
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:*kept object:nil];
    return self;
}
- (CGFloat)wantedHeight { return fontSize() * 2.6 + 20; }
- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updateTimer];
}
// The line advances 4 times a second while Home is on screen, the add-on is on and Low Power Mode is off. Re-checked
// when any of those change (0.6.0 only checked when the view joined a window, so turning it on, or Low Power Mode
// going off, left the line frozen until Home was rebuilt). The timer holds a weak proxy, not the view.
- (void)updateTimer {
    BOOL want = self.window && !NSProcessInfo.processInfo.isLowPowerModeEnabled && MRGAddonInstalled(kAddon);
    if (want && _timer) return;
    [_timer invalidate];
    _timer = nil;
    if (want) {
        __weak MRGPopupLyricsView *weak = self;
        _timer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
            MRGPopupLyricsView *view = weak;
            if (!view) { [t invalidate]; return; }
            @try { [view refresh]; } @catch (NSException *e) {}
        }];
    }
    [self refresh];
}
- (void)changed {
    [self updateTimer];
}
- (void)refresh {
    if (!MRGAddonInstalled(kAddon)) { self.hidden = YES; return; }
    resolveSymbols();
    _now.font = [UIFont systemFontOfSize:fontSize() weight:UIFontWeightBold];
    _next.font = [UIFont systemFontOfSize:MAX(13, fontSize() - 6) weight:UIFontWeightMedium];
    NSDictionary *playing = MRGNowPlaying();
    BOOL playingSong = playing && ![playing[@"ad"] boolValue];
    if (!playingSong) {
        _next.text = nil;
        if (idleMode() == 0) { self.alpha = 0; return; }
        if (idleMode() == 2 && _lastShown.length) _now.text = _lastShown;
        else _now.text = @"Nothing playing";
        self.alpha = 1;
        return;
    }
    self.alpha = 1;
    if (!sgLines || !sgLead || !sgText) {
        _now.text = @"Lyrics need Vitrine";
        _next.text = nil;
        return;
    }
    NSString *track = sgTrack ? sgTrack() : nil;
    if (!track.length) {
        NSString *uri = playing[@"uri"];
        NSRange colon = [uri rangeOfString:@"spotify:track:"];
        if (colon.location != NSNotFound) track = [uri substringFromIndex:colon.location + colon.length];
    }
    NSArray *lines = track.length ? sgLines(track) : nil;
    if (!lines.count) {
        // Asked once per song, not on every tick (0.6.0 asked Vitrine for the lyrics 4 times a second until they came).
        if (sgAsk && track.length && ![track isEqualToString:_asked]) { _asked = [track copy]; sgAsk(track); }
        _now.text = @"♪";
        _next.text = nil;
        return;
    }
    NSInteger ms = sgPos ? sgPos() : 0;
    NSInteger index = sgLead(lines, ms);
    if (index < 0 || index >= (NSInteger)lines.count) index = 0;
    NSString *text = sgText(lines[index]);
    NSString *upcoming = index + 1 < (NSInteger)lines.count ? sgText(lines[index + 1]) : nil;
    if (text.length) _lastShown = text;
    _now.text = text.length ? text : @"♪";
    _next.text = upcoming;
}
@end

static NSHashTable<UIView *> *sPages;

void MRGPopupPlace(UIView *page) {
    if (![page isKindOfClass:UIView.class]) return;
    if (!sPages) sPages = [NSHashTable weakObjectsHashTable];
    [sPages addObject:page];
    MRGPopupLyricsView *view = objc_getAssociatedObject(page, &kViewKey);
    if (!MRGAddonInstalled(kAddon)) { view.hidden = YES; return; }
    if (!view) {
        view = [MRGPopupLyricsView new];
        objc_setAssociatedObject(page, &kViewKey, view, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [page addSubview:view];
    }
    view.hidden = NO;
    // Below the status bar and the DJ chip's row, so the chip stays tappable and the list still scrolls
    // (this view takes no touches).
    CGFloat top = page.safeAreaInsets.top + 52;
    CGFloat height = [view wantedHeight];
    CGRect frame = CGRectMake(12, top, MAX(40, page.bounds.size.width - 24), height);
    if (!CGRectEqualToRect(view.frame, frame)) view.frame = frame;
    if (page.subviews.lastObject != view) [page bringSubviewToFront:view];
    [view refresh];
}

@interface MRGPopupAddon : NSObject <MRGAddon>
@end
@implementation MRGPopupAddon
- (NSString *)addonID { return kAddon; }
- (NSString *)addonName { return @"Pop-up lyrics"; }
- (NSString *)addonCategory { return @"Home"; }
- (NSString *)addonVersion { return @"1.0"; }
- (NSString *)addonDescription { return @"Apple Music-style synced lyrics at the top of Home, using Vitrine's lyrics. Home still scrolls, and the DJ chip stays where it is."; }
- (NSArray<MRGAddonSetting *> *)addonSettings {
    MRGAddonSetting *size = [MRGAddonSetting slider:@"size" title:@"Font size" min:15 max:34 fallback:22];
    MRGAddonSetting *idle = [MRGAddonSetting picker:@"idle" title:@"When nothing is playing" options:@[@"Hidden", @"Nothing playing", @"Last line"] values:@[@0, @1, @2] fallback:@1];
    idle.footer = @"The lines, the timing and which line is current come from Vitrine. This row shows the current line and the next one, and it doesn't take touches, so Home keeps scrolling.";
    return @[size, idle];
}
// On or off takes effect on Home right away: the pages Mirage has seen are laid out again, and a Home that is already
// on screen but was never seen (the add-on was off) is found through its view controller.
static void relayoutHome(void) {
    for (UIView *page in sPages.allObjects) { [page setNeedsLayout]; MRGPopupPlace(page); }
    Class home = NSClassFromString(@"_TtC19Home_FunkisPageImpl20FunkisViewController");
    if (!home) return;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            NSMutableArray *stack = [NSMutableArray arrayWithObject:window];
            NSUInteger seen = 0;
            while (stack.count && seen < 3000) {
                UIView *view = stack.lastObject; [stack removeLastObject]; seen++;
                if ([view.nextResponder isKindOfClass:home]) { MRGPopupPlace(view); continue; }
                [stack addObjectsFromArray:view.subviews];
            }
        }
    }
}
- (void)addonDidEnable { dispatch_async(dispatch_get_main_queue(), ^{ @try { relayoutHome(); } @catch (NSException *e) {} }); }
- (void)addonDidDisable { @try { for (UIView *page in sPages.allObjects) MRGPopupPlace(page); } @catch (NSException *e) {} }
@end

__attribute__((constructor)) static void mrgPopupConstructor(void) { MRGAddonRegister([MRGPopupAddon new]); }
