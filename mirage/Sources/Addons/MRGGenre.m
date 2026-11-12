// Genre on Now Playing. Spotify's player track (SPTPlayerTrack) has no genre field. Its metadata
// dictionary is checked for any key containing "genre" and that value is used when it is there.
// Otherwise the artist's genres come from the same Web API artist object Mirage already uses
// (GET /artists/{id}), cached on disk by artist so a new track doesn't ask again.
#import "Addons/MRGAddon.h"
#import "MRGAddons.h"
#import "MRGPlayer.h"
#import "MRGSpotifyWeb.h"
#import "MRGPrefs.h"
#import "MRGDJLog.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kAddon = @"genres";
NSString *MRGGenreText(void);
static NSMutableDictionary *sCache;
static NSString *sShowing;
static BOOL sLoggedKeys;

static NSURL *cacheURL(void) {
    NSURL *lib = [NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [lib URLByAppendingPathComponent:@"Mirage" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:@"genres.plist"];
}

static void loadCache(void) {
    if (sCache) return;
    id saved = [NSDictionary dictionaryWithContentsOfURL:cacheURL()];
    sCache = [saved isKindOfClass:NSDictionary.class] ? [saved mutableCopy] : [NSMutableDictionary dictionary];
}

static id message(id obj, NSString *sel) {
    SEL s = NSSelectorFromString(sel);
    if (![obj respondsToSelector:s]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(obj, s); }
    @catch (NSException *e) { return nil; }
}

static NSDictionary *playerMeta(void) {
    id track = message(message(MRGPlayerInstance(), @"state"), @"track");
    id meta = message(track, @"metadata");
    return [meta isKindOfClass:NSDictionary.class] ? meta : nil;
}

static NSArray<NSString *> *stringsIn(id value) {
    NSMutableArray *out = [NSMutableArray array];
    if ([value isKindOfClass:NSString.class] && [value length]) {
        for (NSString *part in [value componentsSeparatedByString:@","]) {
            NSString *t = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (t.length) [out addObject:t];
        }
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id item in value) if ([item isKindOfClass:NSString.class] && [item length]) [out addObject:item];
    }
    return out;
}

static NSArray<NSString *> *genresInMetadata(NSDictionary *meta) {
    if (!sLoggedKeys && meta) {
        sLoggedKeys = YES;
        MRGDJLog(@"genres: player metadata keys: %@", [meta.allKeys componentsJoinedByString:@", "] ?: @"(none)");
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *key in meta) {
        if ([key.lowercaseString containsString:@"genre"]) [out addObjectsFromArray:stringsIn(meta[key])];
    }
    return out;
}

static NSString *joinGenres(NSArray *genres) {
    if (!genres.count) return nil;
    NSUInteger n = MIN(genres.count, (NSUInteger)3);
    return [[genres subarrayWithRange:NSMakeRange(0, n)] componentsJoinedByString:@" · "];
}

static void publish(NSString *text) {
    if ((!text.length && !sShowing.length) || [text isEqualToString:sShowing]) return;
    sShowing = [text copy];
    // Not a settings change: before 0.6.4 every song with genres posted MRGSettingsChangedNotification, which relaid
    // out every page in the app (and saved the settings) on each track change of a playlist.
    Class page = NSClassFromString(@"_TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController");
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            NSMutableArray *stack = [NSMutableArray arrayWithObject:window];
            NSUInteger seen = 0;
            while (stack.count && seen < 2000) {
                UIView *view = stack.lastObject; [stack removeLastObject]; seen++;
                if (page && [view.nextResponder isKindOfClass:page]) [view setNeedsLayout];
                [stack addObjectsFromArray:view.subviews];
            }
        }
    }
}

NSString *MRGGenreText(void) { return MRGAddonInstalled(kAddon) ? sShowing : nil; }

static void resolve(NSDictionary *now) {
    if (!MRGAddonInstalled(kAddon) || [now[@"ad"] boolValue]) { publish(nil); return; }
    NSDictionary *meta = playerMeta();
    NSArray *inlineGenres = genresInMetadata(meta);
    if (inlineGenres.count) { publish(joinGenres(inlineGenres)); return; }
    NSString *artistURI = [meta[@"artist_uri"] isKindOfClass:NSString.class] ? meta[@"artist_uri"] : nil;
    NSString *artist = now[@"artist"];
    NSString *key = artistURI.length ? artistURI : (artist.length ? [@"name:" stringByAppendingString:artist.lowercaseString] : nil);
    if (!key) { publish(nil); return; }
    loadCache();
    NSArray *cached = [sCache[key] isKindOfClass:NSArray.class] ? sCache[key] : nil;
    if (cached) { publish(joinGenres(cached)); return; }
    void (^keep)(NSDictionary *) = ^(NSDictionary *artistInfo) {
        // No answer (offline, no token yet) is not "no genres": nothing is cached, so the next song asks again.
        // 0.6.0 cached an empty list and that artist never showed genres again.
        if (![artistInfo isKindOfClass:NSDictionary.class]) { if ([MRGNowPlaying()[@"uri"] isEqual:now[@"uri"]]) publish(nil); return; }
        NSArray *genres = [artistInfo[@"genres"] isKindOfClass:NSArray.class] ? artistInfo[@"genres"] : @[];
        NSMutableArray *clean = [NSMutableArray array];
        for (id g in genres) if ([g isKindOfClass:NSString.class]) [clean addObject:g];
        sCache[key] = clean;
        if (sCache.count > 200) [sCache removeObjectForKey:sCache.allKeys.firstObject];
        NSDictionary *snapshot = [sCache copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [snapshot writeToURL:cacheURL() atomically:YES]; });
        MRGDJLog(@"genres: %@ → %@ (Web API artist, cached)", artist ?: key, joinGenres(clean) ?: @"none");
        // The song may have changed while the lookup ran: the answer is kept, but only shown for its own song.
        NSString *playing = MRGNowPlaying()[@"uri"];
        if (now[@"uri"] && playing && ![playing isEqualToString:now[@"uri"]]) return;
        publish(joinGenres(clean));
    };
    if ([artistURI hasPrefix:@"spotify:artist:"]) MRGWebArtist(artistURI, keep);
    else if (artist.length) MRGWebFindArtist(artist, ^(NSDictionary *found, NSString *how) { keep(found); });
    else publish(nil);
}

@interface MRGGenreAddon : NSObject <MRGAddon>
@end
@implementation MRGGenreAddon
- (NSString *)addonID { return kAddon; }
- (NSString *)addonName { return @"Genres"; }
- (NSString *)addonCategory { return @"Now Playing"; }
- (NSString *)addonVersion { return @"1.0"; }
- (NSString *)addonDescription { return @"Shows the genres of the song that's playing, under its title. Spotify's player metadata is used when it carries genres; otherwise the artist's genres, saved on this phone."; }
- (NSArray<MRGAddonSetting *> *)addonSettings { return @[]; }
- (void)addonDidEnable { resolve(MRGNowPlaying()); }
- (void)addonDidDisable { publish(nil); }
- (NSString *)addonSummary { return sShowing ?: @"On Now Playing"; }
@end

__attribute__((constructor)) static void mrgGenreConstructor(void) {
    MRGAddonRegister([MRGGenreAddon new]);
    [NSNotificationCenter.defaultCenter addObserverForName:MRGPlayerTrackChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        resolve(n.userInfo);
    }];
}
