// Add-on "Focus mode" (Now Playing): one button on the player strips it to the cover, previous / play-pause / next,
// the queue and the Connect (devices) button, on true black. Everything else (the header, title and like, the
// scrubber, shuffle and repeat, share, the lyrics preview and the cards under the player) goes invisible in place,
// so nothing moves, and comes back exactly as it was when Focus is turned off or the add-on removed.
// The button sits in the middle of the footer row (Connect · ◎ · queue) and is only there while the add-on is
// installed. Built on the Now Playing kit's hooks (MRGNowKit), which stay off on unverified Spotify builds.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "MRGAddon.h"
#import "MRGAddons.h"
#import "MRGPrefs.h"
#import "MRGNowKit.h"
#import "MRGDJLog.h"

static NSString *const kAddon = @"focus";
static NSString *const kOwner = @"focus";
static char kButtonKey, kBlackKey, kScrollKey;

static BOOL installed(void) { return MRGAddonInstalled(kAddon) && MRGNowKitRunning(); }
static BOOL focusOn(void) { return installed() && MRGAddonFlag(kAddon, @"on", NO); }
static BOOL keepLyrics(void) { return MRGAddonFlag(kAddon, @"lyrics", NO); }
static BOOL oled(void) { return MRGAddonFlag(kAddon, @"oled", YES); }

static void refreshIfChanged(void);

@interface MRGFocusButton : UIButton
@end
@implementation MRGFocusButton
+ (instancetype)make {
    MRGFocusButton *b = [MRGFocusButton buttonWithType:UIButtonTypeSystem];
    b.accessibilityIdentifier = @"Mirage.FocusButton";
    b.frame = CGRectMake(0, 0, 44, 44);
    [b addTarget:b action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    [b refresh];
    return b;
}
- (void)refresh {
    BOOL on = focusOn();
    UIImageSymbolConfiguration *c = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:on ? UIImageSymbolWeightSemibold : UIImageSymbolWeightRegular];
    [self setImage:[UIImage systemImageNamed:on ? @"viewfinder.circle.fill" : @"viewfinder" withConfiguration:c] forState:UIControlStateNormal];
    self.tintColor = on ? MRGAccent() : [UIColor colorWithWhite:1 alpha:0.72];
    self.accessibilityLabel = on ? @"Leave Focus mode" : @"Focus mode";
}
- (void)tapped {
    [[UIImpactFeedbackGenerator new] impactOccurred];
    BOOL on = !MRGAddonFlag(kAddon, @"on", NO);
    MRGDJLog(@"focus: %@", on ? @"on" : @"off");
    MRGAddonSetFlag(kAddon, @"on", on);
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        refreshIfChanged();
    } completion:nil];
}
@end

static void hideChildren(UIView *root) { for (UIView *v in root.subviews) if (![v isKindOfClass:MRGFocusButton.class]) MRGNowHide(v, kOwner); }

static void placeButton(UIViewController *footer) {
    UIView *root = footer.viewIfLoaded;
    MRGFocusButton *b = objc_getAssociatedObject(footer, &kButtonKey);
    if (!installed()) { [b removeFromSuperview]; return; }
    if (!root) return;
    if (!b) { b = [MRGFocusButton make]; objc_setAssociatedObject(footer, &kButtonKey, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    if (b.superview != root) [root addSubview:b];
    else if (root.subviews.lastObject != b) [root bringSubviewToFront:b];
    UIStackView *row = MRGNowRowIn(root);
    CGRect r = row ? [row convertRect:row.bounds toView:root] : root.bounds;
    CGPoint c = CGPointMake(CGRectGetMidX(root.bounds), CGRectGetMidY(r));
    if (!CGPointEqualToPoint(b.center, c)) b.center = c;
    [b refresh];
}

static void blackBackground(UIViewController *bg, BOOL on) {
    UIView *root = bg.viewIfLoaded;
    UIView *black = objc_getAssociatedObject(bg, &kBlackKey);
    if (!on) { if (black.alpha > 0) black.alpha = 0; return; }
    if (!root) return;
    if (!black) {
        black = [UIView new];
        black.backgroundColor = UIColor.blackColor;
        black.userInteractionEnabled = NO;
        black.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(bg, &kBlackKey, black, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    black.frame = root.bounds;
    if (black.superview != root) [root addSubview:black];
    else if (root.subviews.lastObject != black) [root bringSubviewToFront:black];
    black.alpha = 1;
}

static UIScrollView *scrollIn(UIView *v) {
    if ([v isKindOfClass:UIScrollView.class]) return (UIScrollView *)v;
    for (UIView *s in v.subviews) if ([s isKindOfClass:UIScrollView.class] && s.bounds.size.height > v.bounds.size.height * 0.6) return (UIScrollView *)s;
    return nil;
}

// The cards under the player: no scrolling to them while Focus is on (back at the top), scrolling again after.
static void lockScroll(UIViewController *vc, BOOL on) {
    UIScrollView *s = scrollIn(vc.viewIfLoaded);
    if (!s) return;
    NSNumber *was = objc_getAssociatedObject(vc, &kScrollKey);
    if (on) {
        if (!was) objc_setAssociatedObject(vc, &kScrollKey, @(s.scrollEnabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (s.scrollEnabled) s.scrollEnabled = NO;
        CGFloat top = -s.adjustedContentInset.top;
        if (fabs(s.contentOffset.y - top) > 0.5) [s setContentOffset:CGPointMake(s.contentOffset.x, top) animated:YES];
    } else if (was) {
        s.scrollEnabled = was.boolValue;
        objc_setAssociatedObject(vc, &kScrollKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void applyPart(MRGNowPart part, id owner) {
    BOOL on = focusOn();
    UIViewController *vc = [owner isKindOfClass:UIViewController.class] ? owner : nil;
    if (part == MRGNowFooter) placeButton(vc);
    if (part == MRGNowBackground) { blackBackground(vc, on && oled()); return; }
    if (part == MRGNowScroll) { lockScroll(vc, on); return; }
    if (!on) return;   // turning off restores everything at once (MRGNowRestoreAll), nothing per part
    UIView *root = vc.viewIfLoaded;
    switch (part) {
        case MRGNowHeader: case MRGNowInfo: case MRGNowDuration: case MRGNowFloating:
            hideChildren(root);
            break;
        case MRGNowControls: {
            NSArray<UIView *> *items = MRGNowRowIn(root).arrangedSubviews;
            if (items.count == 5 && MRGNowClassNamed(items[2], @"PlayButton")) { MRGNowHide(items[0], kOwner); MRGNowHide(items[4], kOwner); }
            break;
        }
        case MRGNowFooter:
            for (UIView *item in MRGNowRowIn(root).arrangedSubviews) {
                if (MRGNowClassNamed(item, @"Connect") || MRGNowClassNamed(item, @"QueueButton") || [item.accessibilityIdentifier containsString:@"Queue"]) continue;
                MRGNowHide(item, kOwner);
            }
            break;
        case MRGNowLyrics:
            if (!keepLyrics()) MRGNowHide((UIView *)owner, kOwner);
            break;
        default: break;
    }
}

@interface MRGFocusAddon : NSObject <MRGAddon>
@end
@implementation MRGFocusAddon
- (NSString *)addonID { return kAddon; }
- (NSString *)addonName { return @"Focus mode"; }
- (NSString *)addonCategory { return @"Now Playing"; }
- (NSString *)addonVersion { return @"1.0"; }
- (NSString *)addonDescription { return @"A player button that leaves just the cover, the controls, queue and devices on black."; }
- (NSInteger)addonBatteryImpact { return 0; }
- (NSString *)addonBatteryNote { return @"Low: nothing runs until you press it."; }
- (NSArray<MRGAddonSetting *> *)addonSettings {
    MRGAddonSetting *on = [MRGAddonSetting toggle:@"on" title:@"Focus mode on" fallback:NO];
    MRGAddonSetting *black = [MRGAddonSetting toggle:@"oled" title:@"True black background" fallback:YES];
    MRGAddonSetting *lyrics = [MRGAddonSetting toggle:@"lyrics" title:@"Keep the lyrics preview" fallback:NO];
    lyrics.footer = MRGNowKitRunning() ? @"Or tap ◎ in the player, between Connect and the queue." : @"Off on this Spotify build (see About).";
    return @[on, black, lyrics];
}
- (void)addonDidEnable {}
- (void)addonDidDisable { MRGAddonSetFlag(kAddon, @"on", NO); }
- (NSString *)addonSummary { return focusOn() ? @"On" : @"Off"; }
@end

// A Focus setting (or the add-on) changed: everything Focus hid comes back, then what stays hidden is hidden again.
static NSString *sLastState;
static void refreshIfChanged(void) {
    NSString *now = [NSString stringWithFormat:@"%d%d%d%d", installed(), focusOn(), oled(), keepLyrics()];
    if ([now isEqualToString:sLastState]) return;
    BOOL first = sLastState == nil;
    sLastState = now;
    if (first && !focusOn()) return;
    @try {
        MRGNowRestoreAll(kOwner);
        MRGNowRelayout();
    } @catch (NSException *e) { MRGDJLog(@"focus: relayout threw %@", e.reason); }
}

__attribute__((constructor)) static void MRGFocusInit(void) {
    MRGAddonRegister([MRGFocusAddon new]);
    MRGNowAddPartClient(^(MRGNowPart part, id owner) { applyPart(part, owner); });
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:MRGSettingsChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { refreshIfChanged(); }];
    });
}
