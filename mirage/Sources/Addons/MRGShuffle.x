// Shuffle+: when shuffle is turned on for a playlist or album, the upcoming queue is rebuilt so the same
// artist doesn't play twice in a row and tracks from the last little while wait their turn. Spotify's own
// queue is what actually plays. On Spotify Free the queue is often refused; then Spotify's shuffle is left as it is.
#import "Addons/MRGAddon.h"
#import "MRGAddons.h"
#import "MRGPlayer.h"
#import "MRGPlaylists.h"
#import "MRGDJLog.h"
#import "MRGPrefs.h"
#import "MRGDiagnostics.h"
#import <QuartzCore/QuartzCore.h>

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
                if (!uris.count || !MRGAddonInstalled(kAddon) || ![context isEqualToString:MRGPlayerContextURI() ?: @""]) return;
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
- (NSString *)addonDescription { return @"A shuffle for playlists and albums that doesn't play the same artist twice in a row and holds back songs you just heard. It uses Spotify's own queue."; }
- (NSArray<MRGAddonSetting *> *)addonSettings {
    MRGAddonSetting *artist = [MRGAddonSetting toggle:@"artist" title:@"Separate the same artist" fallback:YES];
    MRGAddonSetting *recent = [MRGAddonSetting toggle:@"recent" title:@"Hold back recent songs" fallback:YES];
    MRGAddonSetting *window = [MRGAddonSetting slider:@"window" title:@"How many count as recent" min:5 max:40 fallback:15];
    window.footer = @"Turn shuffle on while a playlist or album is playing. Spotify Free often refuses a queue and a chosen track, and its skip limit still applies. When the queue is refused, Spotify's own shuffle is left as it is.";
    return @[artist, recent, window];
}
- (void)addonDidEnable {}
- (void)addonDidDisable { takeBackQueue(); }
- (NSString *)addonSummary { return avoidArtist() ? @"Artists separated" : @"On"; }
@end

%hook SPTEsperantoPlayer
- (id)setShufflingContext:(BOOL)on {
    id result = %orig;
    if (!on || !MRGAddonInstalled(kAddon)) return result;
    NSString *context = MRGPlayerContextURI();
    if ([context hasPrefix:@"spotify:playlist:"] || [context hasPrefix:@"spotify:album:"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ @try { applyShuffle(context); } @catch (NSException *e) { MRGDJLog(@"shuffle+: threw %@", e.reason); } });
    }
    return result;
}
%end

%ctor {
    MRGAddonRegister([MRGShuffleAddon new]);
    if (NSClassFromString(@"SPTEsperantoPlayer")) %init;
    [NSNotificationCenter.defaultCenter addObserverForName:MRGPlayerTrackChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        remember(n.userInfo[@"uri"]);
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:MRGPlayerShuffleOffNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        @try { takeBackQueue(); } @catch (NSException *e) {}
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:MRGPlayerShuffleOnNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        if (!MRGAddonInstalled(kAddon)) return;
        NSString *context = [n.userInfo[@"context"] isKindOfClass:NSString.class] ? n.userInfo[@"context"] : MRGPlayerContextURI();
        if ([context hasPrefix:@"spotify:playlist:"] || [context hasPrefix:@"spotify:album:"]) {
            @try { applyShuffle(context); } @catch (NSException *e) { MRGDJLog(@"shuffle+: threw %@", e.reason); }
        }
    }];
}
