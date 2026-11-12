// Add-on "Up Next" (Now Playing): a compact glass row at the bottom of the player's cover names the next song
// ("Next · Title — Artist", then the two after it), and holding the middle of the cover brings up a card with the
// next three, their art, and where each comes from (your queue or what's playing). Both read Spotify's own queue
// from the player's state (MRGFetchQueue), so they show what Spotify will really play, without a network call.
// The hold is the middle third of the cover only: Vitrine's hold-to-play-faster uses the sides.
// Lives on the cover, so it moves with it. Off by default; the row can be turned off to keep only the card.
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

static NSString *const kAddon = @"up-next";
static char kRowKey, kCardKey, kHoldKey;

static BOOL showRow(void) { return MRGAddonFlag(kAddon, @"row", YES); }
static BOOL holdCard(void) { return MRGAddonFlag(kAddon, @"card", YES); }
static BOOL nearEndOnly(void) { return MRGAddonInteger(kAddon, @"when", 0) == 1; }   // the row only in a song's last 30 s

static NSArray<NSDictionary *> *sNext;   // the next few, newest read
static NSHashTable *sViews;              // rows and cards on screen, to refresh

static NSCache *imageCache(void) { static NSCache *c; if (!c) { c = [NSCache new]; c.countLimit = 40; } return c; }
static void loadArt(UIImageView *view, NSString *url) {
    view.image = nil;
    objc_setAssociatedObject(view, &kRowKey, url, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (![url hasPrefix:@"https://"]) return;
    UIImage *hit = [imageCache() objectForKey:url];
    if (hit) { view.image = hit; return; }
    __weak UIImageView *weak = view;
    [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        UIImage *img = data.length ? [UIImage imageWithData:data] : nil;
        if (!img) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [imageCache() setObject:img forKey:url];
            UIImageView *v = weak;
            if ([objc_getAssociatedObject(v, &kRowKey) isEqualToString:url]) v.image = img;
        });
    }] resume];
}

static NSString *line(NSDictionary *t) {
    NSString *title = t[@"title"], *artist = t[@"artist"];
    if (!title.length) return @"Unknown song";
    return artist.length ? [NSString stringWithFormat:@"%@ — %@", title, artist] : title;
}

static UIVisualEffectView *glass(CGFloat radius) {
    UIVisualEffectView *g = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    g.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    g.layer.cornerRadius = radius;
    g.layer.cornerCurve = kCACornerCurveContinuous;
    g.clipsToBounds = YES;
    g.userInteractionEnabled = NO;
    return g;
}

@protocol MRGUpNextShowing
- (void)show:(NSArray<NSDictionary *> *)next;
@end

#pragma mark - the row

@interface MRGUpNextRow : UIView <MRGUpNextShowing>
@end
@implementation MRGUpNextRow {
    UIVisualEffectView *_glass;
    UIImageView *_art;
    UILabel *_kicker, *_title, *_then;
    NSTimer *_clock;
    BOOL _hasNext;
}
- (void)dealloc { [_clock invalidate]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updateClock];
}
// Near the end only: the row fades in over the song's last 30 seconds (checked every 2 s, every 5 s in Low Power Mode).
- (void)updateClock {
    BOOL run = self.window && nearEndOnly() && MRGAddonInstalled(kAddon);
    NSTimeInterval every = NSProcessInfo.processInfo.isLowPowerModeEnabled ? 5 : 2;
    if (!run) { [_clock invalidate]; _clock = nil; [self place]; return; }
    if (!_clock || fabs(_clock.timeInterval - every) > 0.01) {
        [_clock invalidate];
        __weak typeof(self) weak = self;
        _clock = [NSTimer scheduledTimerWithTimeInterval:every repeats:YES block:^(NSTimer *t) {
            MRGUpNextRow *s = weak;
            if (!s || !s.window) { [t invalidate]; return; }
            @try { [s place]; } @catch (NSException *e) {}
        }];
        _clock.tolerance = 0.5;
    }
    [self place];
}
- (void)place {
    BOOL show = _hasNext;
    if (show && nearEndOnly()) {
        double pos = 0, dur = 0;
        show = MRGPlayerProgress(&pos, &dur) && dur > 40 && dur - pos <= 30;
    }
    if (show) self.hidden = NO;
    CGFloat want = show ? 1 : 0;
    if (fabs(self.alpha - want) < 0.01) { if (!show) self.hidden = YES; return; }
    [UIView animateWithDuration:0.35 animations:^{ self.alpha = want; } completion:^(BOOL f) { if (self.alpha < 0.01) self.hidden = YES; }];
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.layer.zPosition = 30;
    _glass = glass(14);
    _art = [UIImageView new];
    _art.contentMode = UIViewContentModeScaleAspectFill;
    _art.clipsToBounds = YES;
    _art.layer.cornerRadius = 5;
    _art.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    _kicker = [UILabel new];
    _kicker.text = @"NEXT";
    _kicker.font = [UIFont systemFontOfSize:10 weight:UIFontWeightHeavy];
    _title = [UILabel new];
    _title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _title.textColor = UIColor.whiteColor;
    _then = [UILabel new];
    _then.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    _then.textColor = [UIColor colorWithWhite:1 alpha:0.62];
    [self addSubview:_glass];
    for (UIView *v in @[_art, _kicker, _title, _then]) [_glass.contentView addSubview:v];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateClock) name:MRGSettingsChangedNotification object:nil];
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    _glass.frame = b;
    CGFloat h = b.size.height, a = h - 12;
    _art.frame = CGRectMake(6, 6, a, a);
    CGFloat x = CGRectGetMaxX(_art.frame) + 8, w = b.size.width - x - 10;
    [_kicker sizeToFit];
    BOOL two = _then.text.length > 0;
    CGFloat top = two ? (h - 32) / 2 : (h - 16) / 2;
    _kicker.frame = CGRectMake(x, top + 1, _kicker.bounds.size.width, 14);
    CGFloat tx = CGRectGetMaxX(_kicker.frame) + 6;
    _title.frame = CGRectMake(tx, top, MAX(0, b.size.width - tx - 10), 16);
    _then.frame = CGRectMake(x, top + 18, w, 14);
    _then.hidden = !two;
}
- (void)show:(NSArray<NSDictionary *> *)next {
    _kicker.textColor = MRGAccent();
    _hasNext = next.count > 0;
    [self updateClock];
    if (!next.count) return;
    _title.text = line(next[0]);
    NSMutableArray *rest = [NSMutableArray array];
    for (NSUInteger i = 1; i < MIN(next.count, (NSUInteger)3); i++) [rest addObject:next[i][@"title"] ?: @"?"];
    _then.text = rest.count ? [@"then " stringByAppendingString:[rest componentsJoinedByString:@" · "]] : nil;
    loadArt(_art, next[0][@"image"]);
    [self setNeedsLayout];
}
@end

#pragma mark - the card

@interface MRGUpNextCard : UIView <MRGUpNextShowing>
- (void)present;
- (void)dismissSoon;
@end
@implementation MRGUpNextCard {
    UIVisualEffectView *_glass;
    UILabel *_header;
    NSMutableArray<UIImageView *> *_arts;
    NSMutableArray<UILabel *> *_titles, *_subs;
    NSUInteger _token;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.layer.zPosition = 40;
    self.alpha = 0;
    _glass = glass(18);
    [self addSubview:_glass];
    _header = [UILabel new];
    _header.text = @"Up next";
    _header.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    _header.textColor = UIColor.whiteColor;
    [_glass.contentView addSubview:_header];
    _arts = [NSMutableArray array]; _titles = [NSMutableArray array]; _subs = [NSMutableArray array];
    for (int i = 0; i < 3; i++) {
        UIImageView *a = [UIImageView new];
        a.contentMode = UIViewContentModeScaleAspectFill;
        a.clipsToBounds = YES;
        a.layer.cornerRadius = 6;
        a.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
        UILabel *t = [UILabel new];
        t.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        t.textColor = UIColor.whiteColor;
        UILabel *s = [UILabel new];
        s.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        s.textColor = [UIColor colorWithWhite:1 alpha:0.62];
        for (UIView *v in @[a, t, s]) [_glass.contentView addSubview:v];
        [_arts addObject:a]; [_titles addObject:t]; [_subs addObject:s];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    _glass.frame = b;
    CGFloat pad = 14, rowH = 56;
    _header.frame = CGRectMake(pad, pad - 2, b.size.width - 2 * pad, 22);
    for (int i = 0; i < 3; i++) {
        CGFloat y = 44 + i * rowH;
        _arts[i].frame = CGRectMake(pad, y + 4, 46, 46);
        CGFloat x = pad + 46 + 10, w = b.size.width - x - pad;
        _titles[i].frame = CGRectMake(x, y + 8, w, 20);
        _subs[i].frame = CGRectMake(x, y + 29, w, 16);
    }
}
+ (CGFloat)height { return 44 + 3 * 56 + 8; }
- (void)show:(NSArray<NSDictionary *> *)next {
    _header.text = next.count ? @"Up next" : @"Nothing up next";
    for (NSUInteger i = 0; i < 3; i++) {
        NSDictionary *t = i < next.count ? next[i] : nil;
        _arts[i].hidden = _titles[i].hidden = _subs[i].hidden = t == nil;
        if (!t) continue;
        _titles[i].text = t[@"title"] ?: @"Unknown song";
        NSString *artist = t[@"artist"] ?: @"";
        NSString *from = [t[@"provider"] isEqualToString:@"queue"] ? @"In your queue" : @"From what's playing";
        _subs[i].text = artist.length ? [NSString stringWithFormat:@"%@ · %@", artist, from] : from;
        loadArt(_arts[i], t[@"image"]);
    }
}
- (void)present {
    _token++;
    [self show:sNext ?: @[]];
    BOOL calm = NSProcessInfo.processInfo.isLowPowerModeEnabled || UIAccessibilityIsReduceMotionEnabled();
    if (self.alpha < 0.01) self.transform = calm ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.94, 0.94);
    [UIView animateWithDuration:calm ? 0.15 : 0.3 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.alpha = 1;
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, sNext.count ? [@"Up next: " stringByAppendingString:line(sNext[0])] : @"Nothing up next");
}
- (void)dismissSoon {
    NSUInteger token = ++_token;
    __weak typeof(self) weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        MRGUpNextCard *s = weak;
        if (!s || s->_token != token) return;
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{ s.alpha = 0; } completion:nil];
    });
}
@end

#pragma mark - the hold

@interface MRGUpNextHold : UILongPressGestureRecognizer <UIGestureRecognizerDelegate>
@end
@implementation MRGUpNextHold
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (!MRGAddonInstalled(kAddon) || !holdCard()) return NO;
    UIView *v = self.view;
    CGFloat x = [self locationInView:v].x, third = v.bounds.size.width / 3;
    return x > third && x < 2 * third;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b { return YES; }
- (void)held {
    UIView *tilt = self.view;
    MRGUpNextCard *card = objc_getAssociatedObject(tilt, &kCardKey);
    if (self.state == UIGestureRecognizerStateBegan) {
        [[UIImpactFeedbackGenerator new] impactOccurred];
        MRGFetchQueue(^(NSArray *queued, NSArray *upNext, NSString *error) {
            if (upNext) sNext = upNext;
            [card show:sNext ?: @[]];
        });
        [card present];
    } else if (self.state >= UIGestureRecognizerStateEnded) {
        [card dismissSoon];
    }
}
@end

#pragma mark - placing

static void refreshAll(void) {
    for (id<MRGUpNextShowing> v in sViews.allObjects) [v show:sNext ?: @[]];
}

static void fetch(void) {
    MRGFetchQueue(^(NSArray *queued, NSArray *upNext, NSString *error) {
        if (!upNext) return;
        NSMutableArray *songs = [NSMutableArray array];
        for (NSDictionary *t in upNext) if (![t[@"ad"] boolValue] && [t[@"uri"] hasPrefix:@"spotify:track:"]) [songs addObject:t];
        sNext = songs;
        refreshAll();
    });
}

static void applyCover(UIView *tilt) {
    MRGUpNextRow *row = objc_getAssociatedObject(tilt, &kRowKey);
    MRGUpNextCard *card = objc_getAssociatedObject(tilt, &kCardKey);
    MRGUpNextHold *hold = objc_getAssociatedObject(tilt, &kHoldKey);
    BOOL on = MRGAddonInstalled(kAddon);
    UIView *cover = MRGNowCoverIn(tilt);
    if (!on) {
        [row removeFromSuperview]; [card removeFromSuperview];
        if (hold) { [tilt removeGestureRecognizer:hold]; objc_setAssociatedObject(tilt, &kHoldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        return;
    }
    if (!cover) return;
    if (!sViews) sViews = [NSHashTable weakObjectsHashTable];
    CGRect b = cover.bounds;
    if (showRow()) {
        if (!row) { row = [MRGUpNextRow new]; objc_setAssociatedObject(tilt, &kRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC); [sViews addObject:row]; [row show:sNext ?: @[]]; }
        CGFloat h = 46, inset = 12;
        CGRect f = CGRectMake(inset, b.size.height - h - inset, b.size.width - 2 * inset, h);
        if (row.superview != cover) [cover addSubview:row];
        if (!CGRectEqualToRect(row.frame, f)) row.frame = f;
    } else [row removeFromSuperview];
    if (holdCard()) {
        if (!card) { card = [MRGUpNextCard new]; objc_setAssociatedObject(tilt, &kCardKey, card, OBJC_ASSOCIATION_RETAIN_NONATOMIC); [sViews addObject:card]; }
        CGFloat inset = 14, h = MIN([MRGUpNextCard height], b.size.height - 2 * inset);
        CGRect f = CGRectMake(inset, (b.size.height - h) / 2, b.size.width - 2 * inset, h);
        if (card.superview != cover) [cover addSubview:card];
        if (!CGRectEqualToRect(card.frame, f)) card.frame = f;
        if (!hold) {
            hold = [[MRGUpNextHold alloc] initWithTarget:nil action:nil];
            [hold addTarget:hold action:@selector(held)];
            hold.delegate = hold;
            hold.minimumPressDuration = 0.45;
            hold.cancelsTouchesInView = NO;
            [tilt addGestureRecognizer:hold];
            objc_setAssociatedObject(tilt, &kHoldKey, hold, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else {
        [card removeFromSuperview];
        if (hold) { [tilt removeGestureRecognizer:hold]; objc_setAssociatedObject(tilt, &kHoldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    }
    static CFTimeInterval lastFetch;
    if (!sNext || CACurrentMediaTime() - lastFetch > 15) { lastFetch = CACurrentMediaTime(); fetch(); }
}

@interface MRGUpNextAddon : NSObject <MRGAddon>
@end
@implementation MRGUpNextAddon
- (NSString *)addonID { return kAddon; }
- (NSString *)addonName { return @"Up Next"; }
- (NSString *)addonCategory { return @"Now Playing"; }
- (NSString *)addonVersion { return @"1.0"; }
- (NSString *)addonDescription { return @"The next songs on the Now Playing cover; hold its middle for a card."; }
- (NSInteger)addonBatteryImpact { return 0; }
- (NSString *)addonBatteryNote { return @"Low: one queue read per song, no animation."; }
- (NSArray<MRGAddonSetting *> *)addonSettings {
    MRGAddonSetting *row = [MRGAddonSetting toggle:@"row" title:@"Row on the cover" fallback:YES];
    MRGAddonSetting *when = [MRGAddonSetting picker:@"when" title:@"Row shows" options:@[@"Always", @"Near the end"] values:@[@0, @1] fallback:@0];
    when.footer = @"Near the end shows the row over a song's last 30 seconds, like a radio's coming-up.";
    MRGAddonSetting *card = [MRGAddonSetting toggle:@"card" title:@"Card on hold" fallback:YES];
    card.footer = MRGNowKitRunning() ? @"Hold the middle of the cover; the sides stay Vitrine's." : @"Off on this Spotify build (see About).";
    return @[row, when, card];
}
- (void)addonDidEnable { fetch(); }
- (void)addonDidDisable {}
@end

__attribute__((constructor)) static void MRGUpNextInit(void) {
    MRGAddonRegister([MRGUpNextAddon new]);
    MRGNowAddCoverClient(^(UIView *tilt) { applyCover(tilt); });
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:MRGPlayerTrackChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            if (!MRGAddonInstalled(kAddon)) return;
            // The state's future list updates a beat after the track does.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ @try { fetch(); } @catch (NSException *e) {} });
        }];
        [nc addObserverForName:MRGSettingsChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            static NSString *last;
            NSString *now = [NSString stringWithFormat:@"%d%d%d", MRGAddonInstalled(kAddon), showRow(), holdCard()];
            if ([now isEqualToString:last]) return;
            BOOL first = last == nil;
            last = now;
            if (first && !MRGAddonInstalled(kAddon)) return;
            @try { MRGNowRelayout(); } @catch (NSException *e) {}
        }];
    });
}
