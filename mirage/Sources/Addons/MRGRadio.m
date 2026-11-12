// Add-on "Radio" (Library): an endless station that keeps Spotify's queue topped up so the music never runs out,
// and learns while it plays. Started from its page, it is seeded with the artist playing now (or, with nothing on,
// the artists you've played most lately, from Mirage's own history) plus artists like them (Spotify's related
// artists, or the same genres when that endpoint is closed to the app's token). Picks are songs of those artists
// (top tracks and catalog search), never one in Trash, never a song it already played this session, and never the
// same artist twice in a row.
//
// What it learns, live, per artist: a song skipped in its first 30 seconds weighs that artist down (×0.6); a song
// played through lifts them (×1.1); liking a song (the heart in the player) lifts them more (×1.5) and pulls in
// artists like them. When an artist sinks low, their songs already waiting in the queue are taken out and replaced.
// The weights are kept between sessions (artist names and numbers only).
//
// The queue is Spotify's own (MRGQueueTracks): three picks are kept waiting ahead, refilled after every song and
// every 20 seconds. Starting something else yourself (another playlist, album or station) stops the radio.
// Spotify Free can refuse to queue; the page says so when it does.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "MRGAddon.h"
#import "MRGAddons.h"
#import "MRGPrefs.h"
#import "MRGPlayer.h"
#import "MRGSpotifyWeb.h"
#import "MRGHistory.h"
#import "MRGTrash.h"
#import "MRGNowKit.h"
#import "MRGDJLog.h"

static NSString *const kAddon = @"radio";
static NSString *const kRadioChanged = @"MirageRadioChanged";
static const NSUInteger kAhead = 3;

static BOOL sOn;
static NSString *sContext;                    // what the player was playing from when the radio took over
static NSString *sStatus = @"Off";
static NSString *sSeedName;
static NSMutableDictionary<NSString *, NSNumber *> *sWeights;   // lowercased artist name → weight
static NSMutableArray<NSDictionary *> *sPool;                    // candidates: uri, title, artist, image
static NSMutableSet<NSString *> *sPlayed, *sSeenArtists, *sOurs;  // URIs played, artists expanded, URIs queued by us
static NSMutableArray<NSDictionary *> *sComing;                  // our picks, in queue order
static NSString *sLastArtist, *sCurURI, *sCurArtist;
static CFTimeInterval sCurStart;
static double sCurDuration;
static BOOL sFilling;
static NSTimer *sTimer;
static NSString *sLastError;

static void changed(void) { [NSNotificationCenter.defaultCenter postNotificationName:kRadioChanged object:nil]; }
static NSString *keyOf(NSString *artist) { return artist.lowercaseString ?: @""; }

static void loadWeights(void) {
    if (sWeights) return;
    NSDictionary *d = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"mirage.addon.radio.weights"];
    sWeights = [NSMutableDictionary dictionary];
    for (NSString *k in d) if ([d[k] isKindOfClass:NSNumber.class]) sWeights[k] = d[k];
}
static void saveWeights(void) {
    // The 200 most decided artists (furthest from neutral).
    NSArray *keys = [sWeights.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        double da = fabs(log([sWeights[a] doubleValue])), db = fabs(log([sWeights[b] doubleValue]));
        return da > db ? NSOrderedAscending : da < db ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *k in [keys subarrayWithRange:NSMakeRange(0, MIN(keys.count, (NSUInteger)200))]) out[k] = sWeights[k];
    [NSUserDefaults.standardUserDefaults setObject:out forKey:@"mirage.addon.radio.weights"];
}
static double weightOf(NSString *artist) { NSNumber *w = sWeights[keyOf(artist)]; return w ? w.doubleValue : 1.0; }
static void scale(NSString *artist, double by, NSString *why) {
    if (!artist.length) return;
    double w = MIN(4, MAX(0.05, weightOf(artist) * by));
    sWeights[keyOf(artist)] = @(w);
    saveWeights();
    MRGDJLog(@"radio: %@ %@ → %.2f", artist, why, w);
}

static void addTracks(NSArray<NSDictionary *> *tracks) {
    NSMutableSet *have = [NSMutableSet set];
    for (NSDictionary *t in sPool) [have addObject:t[@"uri"]];
    for (NSDictionary *t in tracks) {
        NSString *uri = t[@"uri"];
        if (![uri hasPrefix:@"spotify:track:"] || [have containsObject:uri] || [sPlayed containsObject:uri] || MRGTrashContains(uri)) continue;
        if (![t[@"artist"] length]) continue;
        [have addObject:uri];
        [sPool addObject:t];
    }
}

static void topUp(void);

// An artist's songs, and artists like them (related, or by genre when related is closed), into the pool.
static void expand(NSString *name, NSInteger depth, void (^done)(void)) {
    if (!name.length || [sSeenArtists containsObject:keyOf(name)]) { if (done) done(); return; }
    [sSeenArtists addObject:keyOf(name)];
    MRGWebFindArtist(name, ^(NSDictionary *artist, NSString *how) {
        if (!artist || !sOn) { if (done) done(); return; }
        MRGWebArtistTracks(artist, 10, ^(NSArray *tracks) {
            addTracks(tracks);
            if (depth <= 0) { if (done) done(); return; }
            MRGWebRelatedArtists(artist, ^(NSArray *related) {
                void (^withLike)(NSArray *) = ^(NSArray *like) {
                    NSArray *some = [like subarrayWithRange:NSMakeRange(0, MIN(like.count, (NSUInteger)4))];
                    dispatch_group_t g = dispatch_group_create();
                    for (NSDictionary *a in some) {
                        if (![a[@"name"] length] || [sSeenArtists containsObject:keyOf(a[@"name"])]) continue;
                        [sSeenArtists addObject:keyOf(a[@"name"])];
                        if (!sWeights[keyOf(a[@"name"])]) sWeights[keyOf(a[@"name"])] = @0.85;
                        dispatch_group_enter(g);
                        MRGWebArtistTracks(a, 5, ^(NSArray *t) { addTracks(t); dispatch_group_leave(g); });
                    }
                    dispatch_group_notify(g, dispatch_get_main_queue(), ^{ if (done) done(); });
                };
                if (related.count) { withLike(related); return; }
                NSString *genre = [artist[@"genres"] isKindOfClass:NSArray.class] ? [artist[@"genres"] firstObject] : nil;
                if (!genre.length) { withLike(@[]); return; }
                MRGWebSearch([NSString stringWithFormat:@"genre:\"%@\"", genre], @"artist", 8, ^(NSArray *results, NSString *error) {
                    NSMutableArray *others = [NSMutableArray array];
                    for (NSDictionary *a in results ?: @[]) if (!MRGNamesMatch(a[@"name"], name)) [others addObject:a];
                    withLike(others);
                });
            });
        });
    });
}

// A weighted draw: not the artist just queued, not a sunk artist, nothing played or trashed.
static NSDictionary *drawPick(void) {
    double total = 0;
    NSMutableArray *ok = [NSMutableArray array];
    for (NSDictionary *t in sPool) {
        if ([sPlayed containsObject:t[@"uri"]] || [sOurs containsObject:t[@"uri"]] || MRGTrashContains(t[@"uri"])) continue;
        if (sLastArtist && MRGNamesMatch(t[@"artist"], sLastArtist)) continue;
        double w = weightOf(t[@"artist"]);
        if (w < 0.25) continue;
        [ok addObject:t];
        total += w;
    }
    if (!ok.count) return nil;
    double r = drand48() * total;
    for (NSDictionary *t in ok) { r -= weightOf(t[@"artist"]); if (r <= 0) return t; }
    return ok.lastObject;
}

// Grow the pool from the artists it likes most, when it runs thin.
static void growIfThin(void (^done)(void)) {
    NSUInteger fresh = 0;
    for (NSDictionary *t in sPool) if (![sPlayed containsObject:t[@"uri"]] && ![sOurs containsObject:t[@"uri"]]) fresh++;
    if (fresh >= 12) { done(); return; }
    NSArray *best = [sWeights keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
    for (NSString *k in best) {
        if ([sSeenArtists containsObject:k] || [sWeights[k] doubleValue] < 0.9) continue;
        expand(k, 1, done);
        return;
    }
    // Everything liked has been expanded: the played artists' neighbours again, one level deeper.
    NSDictionary *any = sPool.count ? sPool[arc4random_uniform((uint32_t)sPool.count)] : nil;
    if (any) { [sSeenArtists removeObject:keyOf(any[@"artist"])]; expand(any[@"artist"], 1, done); }
    else done();
}

static void stopRadio(NSString *why) {
    if (!sOn) return;
    sOn = NO;
    [sTimer invalidate];
    sTimer = nil;
    sStatus = why ?: @"Off";
    MRGDJLog(@"radio: stopped (%@)", sStatus);
    changed();
}

static void topUp(void) {
    if (!sOn || sFilling) return;
    sFilling = YES;
    MRGFetchQueue(^(NSArray *queued, NSArray *upNext, NSString *error) {
        NSMutableArray *waiting = [NSMutableArray array];
        for (NSDictionary *t in queued ?: @[]) if ([sOurs containsObject:t[@"uri"]]) [waiting addObject:t];
        // Picks the radio has gone off since they were queued come out of the queue.
        NSMutableArray *sunk = [NSMutableArray array];
        for (NSDictionary *t in waiting) if (weightOf(t[@"artist"]) < 0.25 || MRGTrashContains(t[@"uri"])) [sunk addObject:t[@"uri"]];
        void (^fill)(void) = ^{
            NSUInteger have = waiting.count - sunk.count;
            if (have >= kAhead) { sFilling = NO; sComing = [waiting mutableCopy]; changed(); return; }
            growIfThin(^{
                NSMutableArray *picks = [NSMutableArray array];
                for (NSUInteger i = have; i < kAhead; i++) {
                    NSDictionary *p = drawPick();
                    if (!p) break;
                    [picks addObject:p];
                    [sOurs addObject:p[@"uri"]];
                    sLastArtist = p[@"artist"];
                }
                if (!picks.count) { sFilling = NO; sStatus = @"Out of songs to pick; try again"; changed(); return; }
                NSMutableArray *uris = [NSMutableArray array];
                for (NSDictionary *p in picks) [uris addObject:p[@"uri"]];
                MRGQueueTracks(uris, ^(BOOL ok, NSString *err) {
                    sFilling = NO;
                    if (!ok) {
                        for (NSString *u in uris) [sOurs removeObject:u];
                        sLastError = err ?: @"Spotify refused the queue";
                        sStatus = [@"Spotify won't queue: " stringByAppendingString:sLastError];
                        MRGDJLog(@"radio: queueing refused: %@", sLastError);
                    } else {
                        sLastError = nil;
                        sStatus = [NSString stringWithFormat:@"On · from %@", sSeedName ?: @"what you play"];
                        [waiting addObjectsFromArray:picks];
                        sComing = waiting;
                        MRGDJLog(@"radio: queued %@", [picks valueForKey:@"title"]);
                    }
                    changed();
                });
            });
        };
        if (sunk.count) {
            [waiting filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *t, id b) { return ![sunk containsObject:t[@"uri"]]; }]];
            MRGQueueRemove(sunk, ^(BOOL ok, NSString *e) { MRGDJLog(@"radio: took %lu sunk picks out of the queue: %@", (unsigned long)sunk.count, ok ? @"ok" : e); fill(); });
            sunk = [NSMutableArray array];
        } else fill();
    });
}

static void startRadio(void) {
    if (sOn) return;
    loadWeights();
    sOn = YES;
    sPool = [NSMutableArray array];
    sPlayed = [NSMutableSet set];
    sSeenArtists = [NSMutableSet set];
    sOurs = [NSMutableSet set];
    sComing = [NSMutableArray array];
    sLastArtist = nil;
    sStatus = @"Starting…";
    changed();
    NSDictionary *now = MRGNowPlaying();
    NSMutableArray *seeds = [NSMutableArray array];
    if ([now[@"artist"] length] && ![now[@"ad"] boolValue]) [seeds addObject:now[@"artist"]];
    NSDictionary *taste = MRGHistoryTaste();
    for (NSString *a in [taste[@"recentArtists"] isKindOfClass:NSArray.class] ? taste[@"recentArtists"] : @[]) { if (seeds.count >= 4) break; if ([a isKindOfClass:NSString.class] && ![seeds containsObject:a]) [seeds addObject:a]; }
    for (NSDictionary *t in [taste[@"onRepeat"] isKindOfClass:NSArray.class] ? taste[@"onRepeat"] : @[]) { if (seeds.count >= 5) break; NSString *a = t[@"artist"]; if ([a isKindOfClass:NSString.class] && ![seeds containsObject:a]) [seeds addObject:a]; }
    if (!seeds.count) { stopRadio(@"Play something first, so the radio knows where to start"); return; }
    sSeedName = seeds.firstObject;
    if (!sWeights[keyOf(seeds.firstObject)]) sWeights[keyOf(seeds.firstObject)] = @1.3;
    sContext = MRGPlayerContextURI();
    MRGDJLog(@"radio: starting from %@", seeds);
    dispatch_group_t g = dispatch_group_create();
    [seeds enumerateObjectsUsingBlock:^(NSString *a, NSUInteger i, BOOL *stop) {
        dispatch_group_enter(g);
        expand(a, i == 0 ? 1 : 0, ^{ dispatch_group_leave(g); });
    }];
    dispatch_group_notify(g, dispatch_get_main_queue(), ^{
        if (!sOn) return;
        if (!sPool.count) { stopRadio(@"Couldn't find songs to start from"); return; }
        if (!MRGNowPlaying()) {
            NSDictionary *first = drawPick();
            [sOurs addObject:first[@"uri"]];
            sLastArtist = first[@"artist"];
            MRGPlayContextURI(first[@"uri"], nil, ^(BOOL ok, NSString *error) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ sContext = MRGPlayerContextURI(); topUp(); });
            });
        } else topUp();
        sTimer = [NSTimer scheduledTimerWithTimeInterval:20 repeats:YES block:^(NSTimer *t) { @try { topUp(); } @catch (NSException *e) {} }];
        sTimer.tolerance = 5;
    });
}

// Each song change: how the last one went, then the queue topped up.
static void trackChanged(NSDictionary *info) {
    if (!sOn) return;
    NSString *ctx = MRGPlayerContextURI();
    // Spotify's own autoplay after a playlist ends (a station) is not the listener choosing: the radio carries on.
    BOOL autoplay = [ctx hasPrefix:@"spotify:station:"] || [ctx containsString:@"autoplay"];
    if (autoplay) sContext = ctx;
    if (sContext.length && ctx.length && ![ctx isEqualToString:sContext] && ![sOurs containsObject:info[@"uri"] ?: @""]) {
        stopRadio(@"Off · you started something else");
        return;
    }
    if (!sContext.length) sContext = ctx;
    CFTimeInterval held = CACurrentMediaTime() - sCurStart;
    if (sCurURI && sCurArtist && sCurStart > 0) {
        BOOL ours = [sOurs containsObject:sCurURI];
        if (held < 30) scale(sCurArtist, ours ? 0.6 : 0.8, @"skipped");
        else if ((sCurDuration > 0 && held >= sCurDuration * 0.8) || held >= 150) scale(sCurArtist, 1.1, @"played through");
    }
    sCurURI = info[@"uri"];
    sCurArtist = info[@"artist"];
    sCurStart = CACurrentMediaTime();
    sCurDuration = 0;
    if (sCurURI) [sPlayed addObject:sCurURI];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        double pos = 0, dur = 0;
        if (MRGPlayerProgress(&pos, &dur)) sCurDuration = dur;
        topUp();
    });
}

// The heart in the player (Spotify's add-to button in the information row): liked after the tap → lift and widen.
@interface MRGRadioLikeWatcher : NSObject
+ (instancetype)shared;
- (void)tapped:(UIControl *)button;
@end
@implementation MRGRadioLikeWatcher
+ (instancetype)shared { static MRGRadioLikeWatcher *w; if (!w) w = [MRGRadioLikeWatcher new]; return w; }
- (void)tapped:(UIControl *)button {
    if (!sOn) return;
    NSDictionary *now = MRGNowPlaying();
    NSString *artist = now[@"artist"];
    __weak UIControl *weak = button;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIControl *b = weak;
        NSString *label = [NSString stringWithFormat:@"%@ %@", b.accessibilityLabel ?: @"", b.accessibilityValue ?: @""].lowercaseString;
        BOOL liked = b.selected || [label containsString:@"remove"] || [label containsString:@"added"] || [label containsString:@"saved"];
        if (!liked || !artist.length) return;
        scale(artist, 1.5, @"liked");
        [sSeenArtists removeObject:keyOf(artist)];
        expand(artist, 1, ^{ changed(); });
    });
}
@end

static char kWatchedKey;
static void watchLikes(MRGNowPart part, id owner) {
    if (part != MRGNowInfo || !MRGAddonInstalled(kAddon)) return;
    UIView *root = [owner isKindOfClass:UIViewController.class] ? ((UIViewController *)owner).viewIfLoaded : nil;
    for (UIView *item in MRGNowRowIn(root).arrangedSubviews) {
        UIControl *c = [item isKindOfClass:UIControl.class] ? (UIControl *)item : nil;
        if (!c || !MRGNowClassNamed(item, @"AddToButton") || objc_getAssociatedObject(c, &kWatchedKey)) continue;
        [c addTarget:MRGRadioLikeWatcher.shared action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(c, &kWatchedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

#pragma mark - the page

@interface MRGRadioPage : UITableViewController
@end
@implementation MRGRadioPage
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Radio";
    self.tableView.tintColor = MRGAccent();
    [NSNotificationCenter.defaultCenter addObserver:self.tableView selector:@selector(reloadData) name:kRadioChanged object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self.tableView]; }
- (NSArray *)learned {
    loadWeights();
    NSArray *keys = [sWeights keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *k in keys) if (fabs([sWeights[k] doubleValue] - 1) > 0.05 && fabs([sWeights[k] doubleValue] - 0.85) > 0.01) [out addObject:k];
    return [out subarrayWithRange:NSMakeRange(0, MIN(out.count, (NSUInteger)12))];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 3; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 2;
    if (s == 1) return MAX(1, (NSInteger)sComing.count);
    return MAX(1, (NSInteger)[self learned].count) + 1;
}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return s == 1 ? @"Coming up from the radio" : s == 2 ? @"What it learned" : nil; }
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    return s == 0 ? @"Skips sink an artist, plays and likes lift them." : nil;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.textLabel.numberOfLines = 1;
    if (ip.section == 0 && ip.row == 0) {
        c.textLabel.text = @"Status";
        c.detailTextLabel.text = sStatus;
        c.detailTextLabel.numberOfLines = 2;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (ip.section == 0) {
        c.textLabel.text = sOn ? @"Stop the radio" : (MRGNowPlaying() ? @"Start from what's playing" : @"Start from your history");
        c.textLabel.textColor = sOn ? UIColor.systemRedColor : MRGAccent();
        c.imageView.image = [UIImage systemImageNamed:sOn ? @"stop.circle" : @"dot.radiowaves.left.and.right"];
        c.imageView.tintColor = c.textLabel.textColor;
    } else if (ip.section == 1) {
        NSDictionary *t2 = ip.row < (NSInteger)sComing.count ? sComing[ip.row] : nil;
        c.textLabel.text = t2 ? t2[@"title"] : (sOn ? @"Filling the queue…" : @"Nothing yet");
        c.detailTextLabel.text = t2[@"artist"];
        c.textLabel.textColor = t2 ? UIColor.labelColor : UIColor.secondaryLabelColor;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        NSArray *l = [self learned];
        if (ip.row == (NSInteger)MAX(1, l.count)) {
            c.textLabel.text = @"Forget what it learned";
            c.textLabel.textColor = UIColor.systemRedColor;
            return c;
        }
        NSString *k = ip.row < (NSInteger)l.count ? l[ip.row] : nil;
        c.textLabel.text = k ? k.capitalizedString : @"Nothing yet";
        c.textLabel.textColor = k ? UIColor.labelColor : UIColor.secondaryLabelColor;
        double w = k ? [sWeights[k] doubleValue] : 1;
        c.detailTextLabel.text = k ? (w > 1 ? [NSString stringWithFormat:@"↑ %.1f×", w] : [NSString stringWithFormat:@"↓ %.1f×", w]) : nil;
        c.detailTextLabel.textColor = w > 1 ? MRGAccent() : UIColor.secondaryLabelColor;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0 && ip.row == 1) {
        [[UIImpactFeedbackGenerator new] impactOccurred];
        if (sOn) stopRadio(@"Off"); else startRadio();
        [t reloadData];
    } else if (ip.section == 2 && ip.row == (NSInteger)MAX(1, [self learned].count)) {
        [sWeights removeAllObjects];
        saveWeights();
        [t reloadData];
    }
}
@end

@interface MRGRadioAddon : NSObject <MRGAddon>
@end
@implementation MRGRadioAddon
- (NSString *)addonID { return kAddon; }
- (NSString *)addonName { return @"Radio"; }
- (NSString *)addonCategory { return @"Library"; }
- (NSString *)addonVersion { return @"1.0"; }
- (NSString *)addonDescription { return @"An endless station that keeps the queue full and learns from your skips and likes."; }
- (NSInteger)addonBatteryImpact { return 1; }
- (NSString *)addonBatteryNote { return @"Some: checks the queue every 20 seconds and looks up songs online."; }
- (NSArray<MRGAddonSetting *> *)addonSettings { return @[]; }
- (UIViewController *)addonSettingsController { return [MRGRadioPage new]; }
- (void)addonDidEnable {}
- (void)addonDidDisable { stopRadio(@"Off"); }
- (NSString *)addonSummary { return sOn ? @"On" : @"Off"; }
@end

__attribute__((constructor)) static void MRGRadioInit(void) {
    MRGAddonRegister([MRGRadioAddon new]);
    MRGNowAddPartClient(^(MRGNowPart part, id owner) { watchLikes(part, owner); });
    srand48((long)time(NULL));
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:MRGPlayerTrackChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            @try { trackChanged(n.userInfo); } @catch (NSException *e) { MRGDJLog(@"radio: track change threw %@", e.reason); }
        }];
    });
}
