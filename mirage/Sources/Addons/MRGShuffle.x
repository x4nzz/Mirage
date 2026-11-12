// Shuffle+: when shuffle is turned on for a playlist or album, the upcoming queue is rebuilt so the same
// artist doesn't play twice in a row and tracks from the last little while wait their turn. Spotify's own
// queue is what actually plays. On Spotify Free the queue is often refused; then Spotify's shuffle is left as it is.
#import "Addons/MRGAddon.h"
#import "MRGCompat.h"
#import "MRGAddons.h"
#import "MRGPlayer.h"
#import "MRGPlaylists.h"
#import "MRGDJLog.h"
#import "MRGPrefs.h"
#import "MRGDiagnostics.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kAddon = @"shuffle-plus";
static NSMutableArray<NSString *> *sRecent;

static BOOL avoidArtist(void) { return MRGAddonFlag(kAddon, @"artist", YES); }
static BOOL holdRecent(void) { return MRGAddonFlag(kAddon, @"recent", YES); }
static NSInteger recentWindow(void) { return MIN(40, MAX(5, MRGAddonInteger(kAddon, @"window", 15))); }

static void remember(NSString *uri) {
    if (![uri hasPrefix:@"spotify:track:"]) return;
    if (!sRecent) {
        sRecent = [NSMutableArray array];
        for (id u in [NSUserDefaults.standardUserDefaults arrayForKey:@"mirage.addon.shuffle-plus.recent"])
            if ([u isKindOfClass:NSString.class]) [sRecent addObject:u];
    }
    [sRecent removeObject:uri];
    [sRecent insertObject:uri atIndex:0];
    while (sRecent.count > 40) [sRecent removeLastObject];
    [NSUserDefaults.standardUserDefaults setObject:sRecent forKey:@"mirage.addon.shuffle-plus.recent"];
}

// At most this many songs go into the queue, so only that many are ever ordered.
static const NSUInteger kQueueMax = 200;

static NSMutableArray *spaced(NSMutableArray *pool, BOOL separate, NSUInteger limit);

// Pure work on plain arrays (no defaults, no UIKit): runs on a utility queue. Before 0.6.4 this ran on the main
// thread over the whole playlist with an O(n²) artist search that lowercased the artist on every comparison; a
// long playlist dominated by one artist froze Spotify for seconds right as shuffle was turned on.
static NSArray<NSDictionary *> *orderTracks(NSArray<NSDictionary *> *tracks, NSString *current, NSArray<NSString *> *slice, BOOL separate) {
    NSMutableArray *fresh = [NSMutableArray array], *held = [NSMutableArray array];
    NSSet *recent = [NSSet setWithArray:slice ?: @[]];
    for (NSDictionary *t in tracks) {
        if (![t isKindOfClass:NSDictionary.class] || ![t[@"uri"] isKindOfClass:NSString.class] || [t[@"uri"] isEqualToString:current ?: @""]) continue;
        if ([recent containsObject:t[@"uri"]]) [held addObject:t];
        else [fresh addObject:t];
    }
    NSMutableArray *out = spaced(fresh, separate, kQueueMax);
    if (out.count < kQueueMax) [out addObjectsFromArray:spaced(held, separate, kQueueMax - out.count)];
    return out;
}

static NSString *artistKey(NSDictionary *t) {
    id a = t[@"artist"];
    return [a isKindOfClass:NSString.class] ? [(NSString *)a lowercaseString] : @"";
}

// Shuffles, then (when separating) takes songs in order, skipping ahead at most 64 places to find a different
// artist. Stops after `limit` songs.
static NSMutableArray *spaced(NSMutableArray *pool, BOOL separate, NSUInteger limit) {
    for (NSUInteger i = pool.count; i > 1; i--) [pool exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
    if (!separate) return [[pool subarrayWithRange:NSMakeRange(0, MIN(limit, pool.count))] mutableCopy];
    // Only the part that can end up in the queue (plus look-ahead room) is considered.
    if (pool.count > limit + 64) [pool removeObjectsInRange:NSMakeRange(limit + 64, pool.count - limit - 64)];
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:pool.count];
    for (NSDictionary *t in pool) [keys addObject:artistKey(t)];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:MIN(limit, pool.count)];
    NSString *last = nil;
    while (pool.count && out.count < limit) {
        NSUInteger pick = 0;
        if (last.length) {
            NSUInteger end = MIN(pool.count, (NSUInteger)64);
            for (NSUInteger i = 0; i < end; i++) if (![keys[i] isEqualToString:last]) { pick = i; break; }
        }
        [out addObject:pool[pick]];
        last = keys[pick];
        [pool removeObjectAtIndex:pick];
        [keys removeObjectAtIndex:pick];
    }
    return out;
}

static void webAlbum(NSString *albumURI, void (^done)(NSArray<NSDictionary *> *, NSString *)) {
    NSString *aid = [albumURI hasPrefix:@"spotify:album:"] ? [albumURI substringFromIndex:@"spotify:album:".length] : nil;
    NSString *auth = MRGSpotifyHeaders()[@"authorization"];
    if (!aid.length || !auth) { done(@[], @"Spotify hasn't signed a request yet."); return; }
    NSString *url = [[@"https://api.spotify.com/v1/albums/" stringByAppendingString:aid] stringByAppendingString:@"/tracks?limit=50"];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [r setValue:auth forHTTPHeaderField:@"Authorization"];
    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSMutableArray *out = [NSMutableArray array];
        NSArray *items = [json[@"items"] isKindOfClass:NSArray.class] ? json[@"items"] : nil;
        for (NSDictionary *tr in items) {
            if (![tr[@"uri"] isKindOfClass:NSString.class]) continue;
            NSString *artist = nil;
            NSArray *artists = [tr[@"artists"] isKindOfClass:NSArray.class] ? tr[@"artists"] : nil;
            NSDictionary *first = [artists.firstObject isKindOfClass:NSDictionary.class] ? artists.firstObject : nil;
            if ([first[@"name"] isKindOfClass:NSString.class]) artist = first[@"name"];
            NSMutableDictionary *d = [@{@"uri": tr[@"uri"]} mutableCopy];
            if ([tr[@"name"] isKindOfClass:NSString.class]) d[@"title"] = tr[@"name"];
            if ([artist isKindOfClass:NSString.class]) d[@"artist"] = artist;
            if ([tr[@"duration_ms"] isKindOfClass:NSNumber.class]) d[@"duration"] = @([tr[@"duration_ms"] doubleValue] / 1000.0);
            [out addObject:d];
        }
        NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *why = out.count ? nil : [NSString stringWithFormat:@"album HTTP %ld", (long)status];
            done(out, why);
        });
    }] resume];
}

static NSString *sAppliedContext;
static BOOL sPlus;             // Shuffle+ is the shuffle button's current state (see below)
static NSString *sQueuedFor;   // the context whose queue Shuffle+ filled, so turning shuffle (or Shuffle+) off can take it back
static CFTimeInterval sAppliedAt;

static void applyShuffle(NSString *context) {
    // Spotify's own button and the player state can both report the same switch; one rebuild per switch.
    if ([context isEqualToString:sAppliedContext ?: @""] && CACurrentMediaTime() - sAppliedAt < 5) return;
    sAppliedContext = [context copy];
    sAppliedAt = CACurrentMediaTime();
    void (^use)(NSArray<NSDictionary *> *, NSString *) = ^(NSArray<NSDictionary *> *tracks, NSString *error) {
        if (!MRGAddonInstalled(kAddon)) return;
        if (![context isEqualToString:MRGPlayerContextURI() ?: @""]) return;
        if (!tracks.count) { MRGDJLog(@"shuffle+: couldn't read %@: %@", context, error ?: @"no tracks"); return; }
        NSString *current = MRGNowPlaying()[@"uri"];
        NSArray *slice = @[];
        if (holdRecent() && sRecent.count) slice = [sRecent subarrayWithRange:NSMakeRange(0, MIN(sRecent.count, (NSUInteger)recentWindow()))];
        BOOL separate = avoidArtist();
        MRGCrumb(@"shuffle+ ordering %lu songs of %@", (unsigned long)tracks.count, context);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray *ordered = @[];
            @try { ordered = orderTracks(tracks, current, slice, separate); } @catch (NSException *e) {}
            NSMutableArray *uris = [NSMutableArray array];
            for (NSDictionary *t in ordered) if ([t[@"uri"] isKindOfClass:NSString.class]) [uris addObject:t[@"uri"]];
            dispatch_async(dispatch_get_main_queue(), ^{
                // Shuffle turned off, the add-on off or another playlist started while ordering: drop it.
                if (!uris.count || !sPlus || !MRGAddonInstalled(kAddon) || ![context isEqualToString:MRGPlayerContextURI() ?: @""]) return;
                MRGClearQueue(^(NSUInteger removed, NSString *clearError) {
                    MRGQueueTracks(uris, ^(BOOL ok, NSString *queueError) {
                        sQueuedFor = ok ? [context copy] : nil;
                        MRGCrumb(@"shuffle+ queued %lu (%@)", (unsigned long)uris.count, ok ? @"ok" : @"refused");
                        MRGDJLog(@"shuffle+: %@ %lu tracks%@", context, (unsigned long)uris.count, ok ? @"" : [NSString stringWithFormat:@" — queue refused (%@). Spotify's own shuffle stays. Free accounts often can't queue.", queueError ?: clearError ?: @"?"]);
                    });
                });
            });
        });
    };
    if ([context hasPrefix:@"spotify:playlist:"]) MRGPlaylistContents(context, use);
    else if ([context hasPrefix:@"spotify:album:"]) webAlbum(context, use);
}

// Shuffle off (or Shuffle+ turned off) while Shuffle+'s order is queued: the queue it filled is cleared, so Spotify goes
// back to playing the playlist in its own order instead of working through 200 queued songs.
static void takeBackQueue(void) {
    if (!sQueuedFor.length) return;
    NSString *was = sQueuedFor;
    sQueuedFor = nil;
    sAppliedContext = nil;
    if (![was isEqualToString:MRGPlayerContextURI() ?: @""]) return;
    MRGClearQueue(^(NSUInteger removed, NSString *error) {
        MRGDJLog(@"shuffle+: shuffle off, took back %lu queued songs%@", (unsigned long)removed, error ? [@" — " stringByAppendingString:error] : @"");
    });
}

@interface MRGShuffleAddon : NSObject <MRGAddon>
@end
@implementation MRGShuffleAddon
- (NSString *)addonID { return kAddon; }
- (NSString *)addonName { return @"Shuffle+"; }
- (NSString *)addonCategory { return @"Playback"; }
- (NSString *)addonVersion { return @"1.0"; }
- (NSString *)addonDescription { return @"Shuffle with no artist twice in a row; pick it in Listening modes."; }
- (NSArray<MRGAddonSetting *> *)addonSettings {
    MRGAddonSetting *artist = [MRGAddonSetting toggle:@"artist" title:@"Separate the same artist" fallback:YES];
    MRGAddonSetting *recent = [MRGAddonSetting toggle:@"recent" title:@"Hold back recent songs" fallback:YES];
    MRGAddonSetting *window = [MRGAddonSetting slider:@"window" title:@"How many count as recent" min:5 max:40 fallback:15];
    window.footer = @"Spotify Free can refuse the queue; then its own shuffle stays.";
    return @[artist, recent, window];
}
- (void)addonDidEnable {}
- (void)addonDidDisable { takeBackQueue(); }
- (NSString *)addonSummary { return sPlus ? @"Shuffling now" : (avoidArtist() ? @"Artists separated" : @"On"); }
@end

#pragma mark - Shuffle+ as a state of Spotify's shuffle button

// Spotify's shuffle button cycles Off → Shuffle → Smart Shuffle (when offered) → Off. With the add-on on, Shuffle+
// is a fourth state: the tap that would take shuffle back to Off lands on Shuffle+ instead (shuffle stays on and the
// upcoming queue is Shuffle+'s), and the next tap goes to Off. The button gets a small "+" badge while it's on.
//
// The tap itself is watched on the button (Spotify names it Components.UI.ShuffleButton, on playlist, album and
// player pages alike); what the tap did is read from the player's state, since Spotify's own button doesn't have
// to go through setShufflingContext:. Long-press the button for a small menu (Shuffle+ / Spotify's shuffle / Off):
// on accounts where Spotify keeps a playlist shuffled and the cycle never reaches Off, that is the way in.
static NSString *const kShuffleButtonID = @"Components.UI.ShuffleButton";
static BOOL sArmed;                    // the add-on is installed (cached for the UIControl hook)
static NSString *sPlusContext;
static CFTimeInterval sTapAt;          // a shuffle-button tap Spotify handled, and whether shuffle was on then
static BOOL sTapFromOn;
static BOOL sOwnSet;                   // our own setShufflingContext: in flight
static NSHashTable<UIView *> *sButtons;
static char kBadgeKey, kPressKey;

static BOOL shufflable(NSString *context) { return [context hasPrefix:@"spotify:playlist:"] || [context hasPrefix:@"spotify:album:"]; }

static void forceApply(NSString *context) {
    sAppliedContext = nil;
    applyShuffle(context);
}

static void badge(UIView *button) {
    UIView *b = objc_getAssociatedObject(button, &kBadgeKey);
    if (!sPlus) { b.hidden = YES; button.accessibilityValue = nil; return; }
    if (!b) {
        UIImageView *v = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"plus" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:7 weight:UIImageSymbolWeightBlack]]];
        v.contentMode = UIViewContentModeCenter;
        v.tintColor = UIColor.whiteColor;
        v.userInteractionEnabled = NO;
        v.layer.cornerRadius = 6.5;
        v.layer.borderWidth = 1;
        v.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.35].CGColor;
        v.accessibilityElementsHidden = YES;
        objc_setAssociatedObject(button, &kBadgeKey, v, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [button addSubview:v];
        b = v;
    }
    b.backgroundColor = MRGAccent();
    CGRect r = button.bounds;
    b.frame = CGRectMake(CGRectGetMidX(r) + 5, CGRectGetMidY(r) - 15, 13, 13);
    b.hidden = NO;
    [button bringSubviewToFront:b];
    button.accessibilityValue = @"Shuffle+";
}

static void badgeAll(void) {
    for (UIView *button in sButtons.allObjects) if (button.window) badge(button);
}

static void setPlus(BOOL on, NSString *context) {
    if (sPlus == on && (!on || [context isEqualToString:sPlusContext ?: @""])) { badgeAll(); return; }
    sPlus = on;
    sPlusContext = on ? [context copy] : nil;
    MRGCrumb(@"shuffle+ state %@", on ? @"on" : @"off");
    badgeAll();
}

static void enterPlus(NSString *context) {
    if (!shufflable(context)) return;
    setPlus(YES, context);
    if (MRGPlayerShuffleState() != 1) {
        sOwnSet = YES;
        MRGPlayerSetShuffle(YES);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ sOwnSet = NO; });
    }
    forceApply(context);
    [[UIImpactFeedbackGenerator new] impactOccurred];
}

static void leavePlus(BOOL shuffleOff) {
    setPlus(NO, nil);
    takeBackQueue();
    if (shuffleOff && MRGPlayerShuffleState() == 1) {
        sOwnSet = YES;
        MRGPlayerSetShuffle(NO);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ sOwnSet = NO; });
    }
}

@interface MRGShufflePress : NSObject
@end
@implementation MRGShufflePress
+ (instancetype)shared { static MRGShufflePress *p; if (!p) p = [MRGShufflePress new]; return p; }
- (void)pressed:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan || !sArmed) return;
    UIView *button = g.view;
    UIViewController *top = button.window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (!top) return;
    NSString *context = MRGPlayerContextURI();
    [[UIImpactFeedbackGenerator new] impactOccurred];
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:nil message:shufflable(context) ? nil : @"Shuffle+ works on playlists and albums." preferredStyle:UIAlertControllerStyleActionSheet];
    if (shufflable(context))
        [menu addAction:[UIAlertAction actionWithTitle:sPlus ? @"Shuffle+ ✓" : @"Shuffle+" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { if (!sPlus) enterPlus(context); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Spotify's shuffle" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        leavePlus(NO);
        if (MRGPlayerShuffleState() != 1) MRGPlayerSetShuffle(YES);
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Shuffle off" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { leavePlus(YES); if (MRGPlayerShuffleState() == 1) MRGPlayerSetShuffle(NO); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = button;
    menu.popoverPresentationController.sourceRect = button.bounds;
    [top presentViewController:menu animated:YES completion:nil];
}
@end

static void adoptButton(UIView *button) {
    if (!button || [sButtons containsObject:button]) return;
    if (!sButtons) sButtons = [NSHashTable weakObjectsHashTable];
    [sButtons addObject:button];
    if (!objc_getAssociatedObject(button, &kPressKey)) {
        UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc] initWithTarget:MRGShufflePress.shared action:@selector(pressed:)];
        g.minimumPressDuration = 0.45;
        [button addGestureRecognizer:g];
        objc_setAssociatedObject(button, &kPressKey, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    badge(button);
}

%group MRGShuffleButton
%hook UIControl
- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    if (!sArmed || !event || ![self.accessibilityIdentifier isEqualToString:kShuffleButtonID]) { %orig; return; }
    // One decision per tap, however many targets the button sends it to.
    static __weak UIEvent *decided;
    static CFTimeInterval decidedStamp;
    static BOOL swallow;
    if (event != decided || event.timestamp != decidedStamp) {
        decided = event;
        decidedStamp = event.timestamp;
        swallow = NO;
        @try {
            adoptButton(self);
            if (sPlus) {
                // Shuffle+ → Off: Spotify doesn't see this tap (it would go to Smart Shuffle from "on").
                swallow = YES;
                MRGCrumb(@"shuffle button: Shuffle+ → off");
                leavePlus(YES);
                [[UISelectionFeedbackGenerator new] selectionChanged];
            } else {
                sTapAt = CACurrentMediaTime();
                sTapFromOn = MRGPlayerShuffleState() == 1;
            }
        } @catch (NSException *e) { swallow = NO; }
    }
    if (!swallow) %orig;
}
%end
%end

// Off after a tap that started from on: Spotify's cycle reached Off, so this is where Shuffle+ comes in.
static void shuffleWentOff(NSString *context) {
    if (sOwnSet) return;
    if (sPlus) { leavePlus(NO); return; }   // turned off some other way
    takeBackQueue();
    if (!sArmed || !sTapFromOn || CACurrentMediaTime() - sTapAt > 2.5 || !shufflable(context)) return;
    sTapAt = 0;
    MRGCrumb(@"shuffle button: cycle → Shuffle+");
    enterPlus(context);
}

%hook SPTEsperantoPlayer
// Only a turn-off is acted on here (from any caller but Mirage): Shuffle+ is entered from the button's cycle, never
// just because shuffle came on.
- (id)setShufflingContext:(BOOL)on {
    id result = %orig;
    if (!on && !sOwnSet && sPlus && sArmed) dispatch_async(dispatch_get_main_queue(), ^{ @try { leavePlus(NO); } @catch (NSException *e) {} });
    return result;
}
%end

#pragma mark - Shuffle+ in Spotify's Listening modes sheet

// 9.1.90 opens a "Listening modes" sheet from a playlist's shuffle button (SmartShuffle_CoreImpl.PlayModePickerView-
// Controller: a header and one Components.UI.PlayModeRow per mode, Shuffle and Smart Shuffle). Shuffle+ joins it as a
// third row in the same stack, styled from Spotify's own rows. Picking it picks Spotify's plain Shuffle first (so
// Smart Shuffle is left and the playlist starts shuffled the way Spotify does it), then Shuffle+ takes over the queue
// once shuffle is on. With the playlist not playing and no row that can be triggered, the page's playlist is played
// shuffled by Mirage instead. The row shows a check while Shuffle+ is on for what's playing.
static NSString *const kModeRowID = @"Components.UI.PlayModeRow";
static CFTimeInterval sPendingUntil;   // a Shuffle+ pick waiting for shuffle to come on
static char kPlusRowKey;

static void findRows(UIView *v, NSMutableArray *into, int depth) {
    if (!v || depth > 14 || into.count > 6) return;
    if ([v.accessibilityIdentifier isEqualToString:kModeRowID]) { [into addObject:v]; return; }
    for (UIView *s in v.subviews) findRows(s, into, depth + 1);
}

static NSArray<UILabel *> *labelsIn(UIView *v) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:v];
    while (stack.count && out.count < 6) {
        UIView *x = stack.firstObject; [stack removeObjectAtIndex:0];
        if ([x isKindOfClass:UILabel.class] && [(UILabel *)x text].length) [out addObject:x];
        [stack addObjectsFromArray:x.subviews];
    }
    return out;
}

// The page under the sheet names its playlist or album (spt_pageURI / pageURI), for when nothing is playing yet.
static NSString *pageContextUnder(UIViewController *sheet) {
    NSMutableArray *vcs = [NSMutableArray array];
    for (UIViewController *p = sheet.presentingViewController; p; p = p.parentViewController) [vcs addObject:p];
    NSMutableArray *stack = [vcs mutableCopy];
    NSUInteger seen = 0;
    while (stack.count && seen < 60) {
        UIViewController *vc = stack.lastObject; [stack removeLastObject]; seen++;
        for (NSString *name in @[@"spt_pageURI", @"pageURI"]) {
            SEL sel = NSSelectorFromString(name);
            if (![vc respondsToSelector:sel]) continue;
            id u = nil;
            @try { u = ((id (*)(id, SEL))objc_msgSend)(vc, sel); } @catch (NSException *e) { u = nil; }
            NSString *str = [u isKindOfClass:NSURL.class] ? [(NSURL *)u absoluteString] : [u isKindOfClass:NSString.class] ? u : nil;
            if (shufflable(str) && vc.viewIfLoaded.window) return str;
        }
        if ([vc isKindOfClass:UINavigationController.class]) { UIViewController *top = ((UINavigationController *)vc).topViewController; if (top) [stack addObject:top]; }
        else [stack addObjectsFromArray:vc.childViewControllers];
        if (vc.presentedViewController && vc.presentedViewController != sheet) [stack addObject:vc.presentedViewController];
    }
    return nil;
}

// Spotify's own Shuffle row, the way a tap reaches it: a control's action, a cell's selection, or VoiceOver's activate.
static BOOL triggerRow(UIView *row) {
    @try {
        for (UIView *v = row; v; v = v.superview) {
            if ([v isKindOfClass:UIControl.class]) { [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside]; return YES; }
            if (v != row) break;
        }
        for (UIView *v = row; v; v = v.superview) {
            if ([v isKindOfClass:UICollectionViewCell.class]) {
                UIView *cv = v.superview;
                while (cv && ![cv isKindOfClass:UICollectionView.class]) cv = cv.superview;
                UICollectionView *list = (UICollectionView *)cv;
                NSIndexPath *ip = [list indexPathForCell:(UICollectionViewCell *)v];
                if (ip && [list.delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) { [list.delegate collectionView:list didSelectItemAtIndexPath:ip]; return YES; }
            }
            if ([v isKindOfClass:UITableViewCell.class]) {
                UIView *tv = v.superview;
                while (tv && ![tv isKindOfClass:UITableView.class]) tv = tv.superview;
                UITableView *list = (UITableView *)tv;
                NSIndexPath *ip = [list indexPathForCell:(UITableViewCell *)v];
                if (ip && [list.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) { [list.delegate tableView:list didSelectRowAtIndexPath:ip]; return YES; }
            }
        }
        if ([row accessibilityActivate]) return YES;
        for (UIView *s in row.subviews) if ([s isKindOfClass:UIControl.class] && ![s.accessibilityIdentifier containsString:@"LearnMore"]) { [(UIControl *)s sendActionsForControlEvents:UIControlEventTouchUpInside]; return YES; }
    } @catch (NSException *e) { MRGDJLog(@"shuffle+: triggering Spotify's Shuffle row threw %@", e.reason); }
    return NO;
}

@interface MRGPlusModeRow : UIControl
@property (nonatomic, weak) UIViewController *sheet;
@property (nonatomic, weak) UIView *shuffleRow;
@property (nonatomic, strong) UIImageView *icon, *check;
@property (nonatomic, strong) UILabel *title, *subtitle;
- (void)refresh;
@end

@implementation MRGPlusModeRow
- (instancetype)initWithTemplate:(UIView *)row {
    if (!(self = [super initWithFrame:row.bounds])) return nil;
    self.accessibilityIdentifier = @"Mirage.ShufflePlusModeRow";
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"Shuffle+";
    self.accessibilityTraits = UIAccessibilityTraitButton;
    NSArray<UILabel *> *labels = labelsIn(row);
    UILabel *t0 = labels.count ? labels[0] : nil, *t1 = labels.count > 1 ? labels[1] : nil;
    UIImageSymbolConfiguration *conf = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
    _icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"shuffle" withConfiguration:conf]];
    _icon.tintColor = t0.textColor ?: UIColor.whiteColor;
    _icon.contentMode = UIViewContentModeCenter;
    UILabel *plus = [UILabel new];
    plus.text = @"+";
    plus.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBlack];
    plus.textColor = UIColor.whiteColor;
    plus.textAlignment = NSTextAlignmentCenter;
    plus.backgroundColor = MRGAccent();
    plus.layer.cornerRadius = 7;
    plus.layer.masksToBounds = YES;
    plus.frame = CGRectMake(20, -2, 14, 14);
    [_icon addSubview:plus];
    _title = [UILabel new];
    _title.text = @"Shuffle+";
    _title.font = t0.font ?: [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _title.textColor = t0.textColor ?: UIColor.whiteColor;
    _subtitle = [UILabel new];
    _subtitle.text = @"No artist twice in a row; songs you just heard wait.";
    _subtitle.font = t1.font ?: [UIFont systemFontOfSize:13];
    _subtitle.textColor = t1.textColor ?: [UIColor colorWithWhite:0.7 alpha:1];
    _subtitle.numberOfLines = 2;
    _check = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]]];
    _check.tintColor = MRGAccent();
    for (UIView *v in @[_icon, _title, _subtitle, _check]) { v.userInteractionEnabled = NO; [self addSubview:v]; }
    [self addTarget:self action:@selector(picked) forControlEvents:UIControlEventTouchUpInside];
    [self refresh];
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat h = b.size.height, left = 24, textX = 66;
    // Spotify's rows: the icon at about 24pt, the text column after it. Taken from the template row when it has labels.
    UIView *shuffle = self.shuffleRow;
    NSArray<UILabel *> *labels = shuffle ? labelsIn(shuffle) : @[];
    if (labels.count) {
        CGRect r = [labels[0].superview convertRect:labels[0].frame toView:shuffle];
        if (r.origin.x > 30 && r.origin.x < 120) textX = r.origin.x;
    }
    _icon.frame = CGRectMake(left - 4, (h - 32) / 2, 32, 32);
    CGFloat w = b.size.width - textX - 44;
    CGSize ts = [_title sizeThatFits:CGSizeMake(w, h)], ss = [_subtitle sizeThatFits:CGSizeMake(w, h)];
    CGFloat total = ts.height + 2 + ss.height, y = (h - total) / 2;
    _title.frame = CGRectMake(textX, y, w, ts.height);
    _subtitle.frame = CGRectMake(textX, y + ts.height + 2, w, ss.height);
    _check.frame = CGRectMake(b.size.width - 40, (h - 24) / 2, 24, 24);
}
- (void)setHighlighted:(BOOL)h { [super setHighlighted:h]; self.alpha = h ? 0.6 : 1; }
- (void)refresh {
    BOOL on = sPlus && [sPlusContext isEqualToString:MRGPlayerContextURI() ?: @""];
    _check.hidden = !on;
    self.accessibilityValue = on ? @"Selected" : nil;
}
- (void)picked {
    [[UISelectionFeedbackGenerator new] selectionChanged];
    UIViewController *sheet = self.sheet;
    NSString *playing = MRGPlayerContextURI();
    NSString *page = sheet ? pageContextUnder(sheet) : nil;
    MRGCrumb(@"listening modes: Shuffle+ picked (page %@, playing %@)", page ?: @"?", playing ?: @"nothing");
    // Already on this playlist: Shuffle+ right away (shuffle goes on if it isn't).
    if (shufflable(playing) && (!page || [page isEqualToString:playing])) {
        [sheet dismissViewControllerAnimated:YES completion:^{ enterPlus(playing); }];
        return;
    }
    sPendingUntil = CACurrentMediaTime() + 10;
    UIView *row = self.shuffleRow;
    if (row && triggerRow(row)) {
        MRGDJLog(@"shuffle+: Spotify's Shuffle picked for the page; Shuffle+ follows when shuffle is on");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (sheet.presentingViewController && !sheet.isBeingDismissed) [sheet dismissViewControllerAnimated:YES completion:nil];
        });
        return;
    }
    if (page) {
        [sheet dismissViewControllerAnimated:YES completion:nil];
        MRGPlayContext(page, nil, @YES, ^(BOOL ok, NSString *error) {
            MRGDJLog(@"shuffle+: played %@ shuffled for Shuffle+: %@", page, ok ? @"ok" : error ?: @"refused");
            if (!ok) sPendingUntil = 0;
        });
        return;
    }
    sPendingUntil = 0;
    MRGDJLog(@"shuffle+: Listening modes gave no way to start the playlist; long-press the shuffle button instead");
}
@end

// Shuffle came on (or the track changed) after a Shuffle+ pick from the sheet.
static void pendingCheck(NSString *context) {
    if (sPendingUntil <= 0 || CACurrentMediaTime() > sPendingUntil) return;
    if (!shufflable(context) || MRGPlayerShuffleState() != 1) return;
    sPendingUntil = 0;
    enterPlus(context);
}

static void addPlusRow(UIViewController *sheet) {
    if (!sArmed || !sheet.viewIfLoaded) return;
    MRGPlusModeRow *mine = objc_getAssociatedObject(sheet, &kPlusRowKey);
    if (mine.superview) { [mine refresh]; return; }
    NSMutableArray<UIView *> *rows = [NSMutableArray array];
    findRows(sheet.view, rows, 0);
    if (!rows.count) return;
    // Spotify's Shuffle row: the one without Smart Shuffle's Learn more button.
    UIView *shuffleRow = rows.firstObject;
    for (UIView *r in rows) {
        __block BOOL learn = NO;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:r];
        while (stack.count && !learn) { UIView *x = stack.lastObject; [stack removeLastObject]; if ([x.accessibilityIdentifier containsString:@"LearnMore"]) learn = YES; [stack addObjectsFromArray:x.subviews]; }
        if (!learn) { shuffleRow = r; break; }
    }
    // The stack the rows are arranged in (the row itself or a wrapper of it).
    UIView *last = rows.lastObject, *item = last;
    UIStackView *stack = nil;
    while (item.superview && item != sheet.view) {
        if ([item.superview isKindOfClass:UIStackView.class] && [((UIStackView *)item.superview).arrangedSubviews containsObject:item]) { stack = (UIStackView *)item.superview; break; }
        item = item.superview;
    }
    if (!stack) {
        static BOOL said;
        if (!said) { said = YES; MRGDJLog(@"shuffle+: the Listening modes rows aren't in a stack; no Shuffle+ row (long-press the shuffle button)"); }
        return;
    }
    mine = [[MRGPlusModeRow alloc] initWithTemplate:shuffleRow];
    mine.sheet = sheet;
    mine.shuffleRow = shuffleRow;
    mine.translatesAutoresizingMaskIntoConstraints = NO;
    CGFloat h = MAX(56, MIN(96, shuffleRow.bounds.size.height));
    [mine.heightAnchor constraintEqualToConstant:h].active = YES;
    NSUInteger at = [stack.arrangedSubviews indexOfObject:item];
    [stack insertArrangedSubview:mine atIndex:at == NSNotFound ? stack.arrangedSubviews.count : at + 1];
    objc_setAssociatedObject(sheet, &kPlusRowKey, mine, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    MRGCrumb(@"listening modes: Shuffle+ row added (%lu rows)", (unsigned long)rows.count);
    [sheet.view setNeedsLayout];
}

%group MRGShuffleModes
%hook _TtC21SmartShuffle_CoreImpl28PlayModePickerViewController
- (void)viewDidLayoutSubviews {
    %orig;
    @try { addPlusRow((UIViewController *)self); } @catch (NSException *e) { MRGDJLog(@"shuffle+: Listening modes row threw %@", e.reason); }
}
%end
%end

static void rearm(void) {
    BOOL was = sArmed;
    sArmed = MRGAddonInstalled(kAddon);
    if (was && !sArmed && sPlus) leavePlus(NO);
}

%ctor {
    MRGAddonRegister([MRGShuffleAddon new]);
    if (NSClassFromString(@"SPTEsperantoPlayer")) %init;
    if (MRGFragileHooksAllowed(@"Shuffle+ button")) %init(MRGShuffleButton);
    if (NSClassFromString(@"_TtC21SmartShuffle_CoreImpl28PlayModePickerViewController") && MRGFragileHooksAllowed(@"Shuffle+ in Listening modes")) %init(MRGShuffleModes);
    dispatch_async(dispatch_get_main_queue(), ^{ rearm(); });
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:MRGSettingsChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { rearm(); }];
    [nc addObserverForName:MRGPlayerTrackChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        remember(n.userInfo[@"uri"]);
        @try { pendingCheck(MRGPlayerContextURI()); } @catch (NSException *e) {}
        // Something else started playing: Shuffle+ belonged to the playlist it was turned on for.
        if (sPlus && ![sPlusContext isEqualToString:MRGPlayerContextURI() ?: @""]) setPlus(NO, nil);
    }];
    [nc addObserverForName:MRGPlayerShuffleOnNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSString *context = [n.userInfo[@"context"] isKindOfClass:NSString.class] && [n.userInfo[@"context"] length] ? n.userInfo[@"context"] : MRGPlayerContextURI();
        @try { pendingCheck(context); } @catch (NSException *e) {}
    }];
    [nc addObserverForName:MRGPlayerShuffleOffNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSString *context = [n.userInfo[@"context"] isKindOfClass:NSString.class] ? n.userInfo[@"context"] : MRGPlayerContextURI();
        @try { shuffleWentOff(context); } @catch (NSException *e) {}
    }];
}
