// Add-on "More like this" (Library): builds a real list of songs like what's playing, or like the playlist that's
// playing, and either puts it in Spotify's queue (a temporary queue, gone when it's played) or saves it as a new
// playlist. "Like this song": the playing artist's top songs and songs of artists like them. "Like this playlist":
// the playlist's main artists (its tracks, or what Spotify has up next from it when the list can't be read), then
// artists like each of them, leaving out songs already in it. "Artists like them" is Spotify's related artists, or
// the same genres when that endpoint is closed to the app's token. Never a song in Trash; artists take turns.
#import <UIKit/UIKit.h>
#import "MRGAddon.h"
#import "MRGAddons.h"
#import "MRGPrefs.h"
#import "MRGPlayer.h"
#import "MRGSpotifyWeb.h"
#import "MRGPlaylists.h"
#import "MRGTrash.h"
#import "MRGDJLog.h"

static NSString *const kAddon = @"more-like-this";

// Artists like this one: related, else by the artist's first genre.
static void likeArtist(NSDictionary *artist, void (^done)(NSArray<NSDictionary *> *artists)) {
    MRGWebRelatedArtists(artist, ^(NSArray *related) {
        if (related.count) { done(related); return; }
        NSString *genre = [artist[@"genres"] isKindOfClass:NSArray.class] ? [artist[@"genres"] firstObject] : nil;
        if (!genre.length) { done(@[]); return; }
        MRGWebSearch([NSString stringWithFormat:@"genre:\"%@\"", genre], @"artist", 8, ^(NSArray *results, NSString *error) {
            NSMutableArray *out = [NSMutableArray array];
            for (NSDictionary *a in results ?: @[]) if (!MRGNamesMatch(a[@"name"], artist[@"name"])) [out addObject:a];
            done(out);
        });
    });
}

// Round-robin across artists, skipping what's excluded or trashed, up to max.
static NSArray<NSDictionary *> *interleave(NSArray<NSArray<NSDictionary *> *> *groups, NSSet *exclude, NSUInteger max) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [exclude mutableCopy] ?: [NSMutableSet set];
    NSMutableSet *titles = [NSMutableSet set];
    for (NSUInteger round = 0; out.count < max; round++) {
        BOOL any = NO;
        for (NSArray *g in groups) {
            if (round >= g.count) continue;
            any = YES;
            NSDictionary *t = g[round];
            NSString *key = [NSString stringWithFormat:@"%@|%@", [t[@"title"] lowercaseString] ?: @"", [t[@"artist"] lowercaseString] ?: @""];
            if (![t[@"uri"] hasPrefix:@"spotify:track:"] || [seen containsObject:t[@"uri"]] || [titles containsObject:key] || MRGTrashContains(t[@"uri"])) continue;
            [seen addObject:t[@"uri"]];
            [titles addObject:key];
            [out addObject:t];
            if (out.count >= max) break;
        }
        if (!any) break;
    }
    return out;
}

// Songs of these artists and of artists like them: each seed's own top songs (ownCount) and perLike of each of its likes.
static void buildFrom(NSArray<NSString *> *seeds, NSInteger ownCount, NSInteger likes, NSInteger perLike, NSSet *exclude, void (^done)(NSArray *tracks)) {
    NSMutableArray<NSArray *> *groups = [NSMutableArray array];
    NSMutableSet *usedArtists = [NSMutableSet set];
    for (NSString *s in seeds) [usedArtists addObject:s.lowercaseString];
    dispatch_group_t g = dispatch_group_create();
    for (NSString *name in seeds) {
        dispatch_group_enter(g);
        MRGWebFindArtist(name, ^(NSDictionary *artist, NSString *how) {
            if (!artist) { dispatch_group_leave(g); return; }
            dispatch_group_enter(g);
            MRGWebArtistTracks(artist, ownCount, ^(NSArray *tracks) { if (ownCount > 0 && tracks.count) [groups addObject:tracks]; dispatch_group_leave(g); });
            likeArtist(artist, ^(NSArray *like) {
                NSUInteger taken = 0;
                for (NSDictionary *a in like) {
                    if (taken >= (NSUInteger)likes) break;
                    NSString *k = [a[@"name"] lowercaseString];
                    if (!k.length || [usedArtists containsObject:k]) continue;
                    [usedArtists addObject:k];
                    taken++;
                    dispatch_group_enter(g);
                    MRGWebArtistTracks(a, perLike, ^(NSArray *tracks) { if (tracks.count) [groups addObject:tracks]; dispatch_group_leave(g); });
                }
                dispatch_group_leave(g);
            });
        });
    }
    dispatch_group_notify(g, dispatch_get_main_queue(), ^{
        // Shuffled groups, so it doesn't open with the seed every time; songs inside a group stay most-played first.
        NSMutableArray *mixed = [groups mutableCopy];
        for (NSUInteger i = mixed.count; i > 1; i--) [mixed exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
        done(interleave(mixed, exclude, 30));
    });
}

static void likeThisSong(void (^done)(NSArray *tracks, NSString *name, NSString *error)) {
    NSDictionary *now = MRGNowPlaying();
    if (![now[@"artist"] length] || [now[@"ad"] boolValue]) { done(nil, nil, @"Play a song first."); return; }
    NSString *name = now[@"title"] ?: now[@"artist"];
    buildFrom(@[now[@"artist"]], 4, 6, 4, [NSSet setWithObject:now[@"uri"] ?: @""], ^(NSArray *tracks) {
        done(tracks, name, tracks.count ? nil : @"Couldn't find songs like it.");
    });
}

static void likeThisPlaylist(void (^done)(NSArray *tracks, NSString *name, NSString *error)) {
    NSString *ctx = MRGPlayerContextURI();
    if (![ctx hasPrefix:@"spotify:playlist:"] && ![ctx hasPrefix:@"spotify:album:"]) { done(nil, nil, @"Play a playlist or album first."); return; }
    void (^fromTracks)(NSArray *) = ^(NSArray *tracks) {
        NSCountedSet *artists = [NSCountedSet set];
        NSMutableSet *inIt = [NSMutableSet set];
        NSMutableDictionary *names = [NSMutableDictionary dictionary];
        for (NSDictionary *t in tracks) {
            if ([t[@"uri"] length]) [inIt addObject:t[@"uri"]];
            NSString *a = t[@"artist"];
            if (!a.length) continue;
            NSString *main = [a componentsSeparatedByString:@", "].firstObject;
            [artists addObject:main.lowercaseString];
            names[main.lowercaseString] = main;
        }
        NSArray *top = [artists.allObjects sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            NSUInteger x = [artists countForObject:a], y = [artists countForObject:b];
            return x > y ? NSOrderedAscending : x < y ? NSOrderedDescending : NSOrderedSame;
        }];
        NSMutableArray *seeds = [NSMutableArray array];
        for (NSString *k in [top subarrayWithRange:NSMakeRange(0, MIN(top.count, (NSUInteger)5))]) [seeds addObject:names[k]];
        if (!seeds.count) { done(nil, nil, @"Couldn't read what's in it."); return; }
        buildFrom(seeds, 0, 3, 3, inIt, ^(NSArray *out) {
            done(out, nil, out.count ? nil : @"Couldn't find songs like it.");
        });
    };
    void (^fromUpNext)(void) = ^{
        MRGFetchQueue(^(NSArray *queued, NSArray *upNext, NSString *error) {
            NSMutableArray *ts = [NSMutableArray array];
            NSDictionary *now = MRGNowPlaying();
            if (now) [ts addObject:now];
            for (NSDictionary *t in upNext ?: @[]) if (![t[@"provider"] isEqualToString:@"queue"]) [ts addObject:t];
            fromTracks(ts);
        });
    };
    if ([ctx hasPrefix:@"spotify:playlist:"]) MRGPlaylistContents(ctx, ^(NSArray *tracks, NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (tracks.count) fromTracks(tracks); else fromUpNext(); });
    });
    else fromUpNext();
}

@interface MRGMoreLikePage : UITableViewController
@end
@implementation MRGMoreLikePage {
    NSArray<NSDictionary *> *_tracks;
    NSString *_title, *_note;
    BOOL _busy;
}
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"More like this"; self.tableView.tintColor = MRGAccent(); }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return _tracks.count ? 3 : 1; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return s == 0 ? 2 : s == 1 ? 2 : (NSInteger)_tracks.count; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return s == 1 ? _title : s == 2 ? [NSString stringWithFormat:@"%lu songs", (unsigned long)_tracks.count] : nil; }
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s { return s == 0 ? (_busy ? @"Finding songs…" : _note) : nil; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (ip.section == 0) {
        NSDictionary *now = MRGNowPlaying();
        NSString *ctx = MRGPlayerContextURI();
        BOOL list = [ctx hasPrefix:@"spotify:playlist:"] || [ctx hasPrefix:@"spotify:album:"];
        c.textLabel.text = ip.row == 0 ? @"Like this song" : (list && [ctx hasPrefix:@"spotify:album:"] ? @"Like this album" : @"Like this playlist");
        c.detailTextLabel.text = ip.row == 0 ? (now[@"title"] ?: @"Nothing playing") : (list ? @"What's playing now" : @"Not playing a playlist");
        c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        c.imageView.image = [UIImage systemImageNamed:ip.row == 0 ? @"sparkles" : @"music.note.list"];
        BOOL ok = !_busy && (ip.row == 0 ? now != nil : list);
        c.textLabel.textColor = ok ? MRGAccent() : UIColor.secondaryLabelColor;
        c.imageView.tintColor = c.textLabel.textColor;
        return c;
    }
    if (ip.section == 1) {
        c.textLabel.text = ip.row == 0 ? @"Add them to the queue" : @"Save as a new playlist";
        c.imageView.image = [UIImage systemImageNamed:ip.row == 0 ? @"text.line.first.and.arrowtriangle.forward" : @"plus.rectangle.on.rectangle"];
        c.textLabel.textColor = MRGAccent();
        c.imageView.tintColor = MRGAccent();
        return c;
    }
    NSDictionary *tr = _tracks[ip.row];
    c.textLabel.text = tr[@"title"];
    c.detailTextLabel.text = tr[@"artist"];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    __weak typeof(self) weak = self;
    if (ip.section == 0) {
        if (_busy) return;
        _busy = YES;
        _note = nil;
        [t reloadData];
        void (^got)(NSArray *, NSString *, NSString *) = ^(NSArray *tracks, NSString *name, NSString *error) {
            MRGMoreLikePage *s = weak;
            if (!s) return;
            s->_busy = NO;
            s->_tracks = tracks.count ? tracks : nil;
            s->_title = ip.row == 0 ? [NSString stringWithFormat:@"More like %@", name ?: @"this"] : @"More like this playlist";
            s->_note = error;
            [s.tableView reloadData];
        };
        if (ip.row == 0) likeThisSong(got); else likeThisPlaylist(got);
        return;
    }
    if (ip.section != 1 || !_tracks.count) return;
    NSMutableArray *uris = [NSMutableArray array];
    for (NSDictionary *tr in _tracks) [uris addObject:tr[@"uri"]];
    void (^say)(NSString *) = ^(NSString *n) { MRGMoreLikePage *s = weak; if (!s) return; s->_note = n; [s.tableView reloadData]; };
    if (ip.row == 0) {
        say(@"Queueing…");
        MRGQueueTracks(uris, ^(BOOL ok, NSString *error) { say(ok ? @"Queued (a temporary queue, gone once played)." : [@"Spotify wouldn't queue them: " stringByAppendingString:error ?: @"refused"]); });
    } else {
        NSString *name = _title.length ? _title : @"More like this";
        say(@"Saving…");
        MRGPlaylistCreate(name, uris, ^(BOOL ok, NSString *uri, NSString *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ say(ok ? [NSString stringWithFormat:@"Saved \"%@\" to your library.", name] : (error ?: @"Spotify didn't make the playlist.")); });
        });
    }
}
@end

@interface MRGMoreLikeAddon : NSObject <MRGAddon>
@end
@implementation MRGMoreLikeAddon
- (NSString *)addonID { return kAddon; }
- (NSString *)addonName { return @"More like this"; }
- (NSString *)addonCategory { return @"Library"; }
- (NSString *)addonVersion { return @"1.0"; }
- (NSString *)addonDescription { return @"Songs like what's playing or like its playlist, queued or saved as a playlist."; }
- (NSInteger)addonBatteryImpact { return 0; }
- (NSString *)addonBatteryNote { return @"Low: works only when you use it."; }
- (NSArray<MRGAddonSetting *> *)addonSettings { return @[]; }
- (UIViewController *)addonSettingsController { return [MRGMoreLikePage new]; }
- (void)addonDidEnable {}
- (void)addonDidDisable {}
@end

__attribute__((constructor)) static void MRGMoreLikeInit(void) { MRGAddonRegister([MRGMoreLikeAddon new]); }
