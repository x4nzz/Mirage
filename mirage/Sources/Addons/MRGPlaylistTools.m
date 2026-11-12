// Playlist tools: sort, drop duplicates, and save a shuffled copy. Every change asks first.
// Sort and duplicate removal can be undone from this page; a shuffled copy is undone by deleting that playlist.
#import "Addons/MRGAddon.h"
#import "MRGAddons.h"
#import "MRGPlaylists.h"
#import "MRGPlayer.h"
#import "MRGPrefs.h"
#import "MRGSafe.h"
#import "MRGDJLog.h"

static NSString *const kAddon = @"playlist-tools";
static NSDictionary *sUndo;   // kind, playlist, uris, name

static NSString *norm(NSString *s) {
    if (![s isKindOfClass:NSString.class]) return @"";
    return [[s lowercaseString] stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:nil];
}

static NSString *dupKey(NSDictionary *t) {
    if ([t[@"title"] length] && [t[@"artist"] length]) return [NSString stringWithFormat:@"%@|%@", norm(t[@"title"]), norm(t[@"artist"])];
    return t[@"uri"] ?: @"";
}

static NSArray<NSString *> *urisOf(NSArray<NSDictionary *> *tracks) {
    NSMutableArray *u = [NSMutableArray array];
    for (NSDictionary *t in tracks) if ([t[@"uri"] hasPrefix:@"spotify:track:"]) [u addObject:t[@"uri"]];
    return u;
}

static NSComparisonResult cmpAdded(NSDictionary *a, NSDictionary *b) {
    id x = a[@"added"], y = b[@"added"];
    if ([x isKindOfClass:NSNumber.class] && [y isKindOfClass:NSNumber.class]) return [x compare:y];
    if ([x isKindOfClass:NSString.class] && [y isKindOfClass:NSString.class]) return [x compare:y];
    return 0;
}

@interface MRGPlaylistToolsPage : UITableViewController
@property (nonatomic, copy) NSDictionary *playlist;   // uri, name
@property (nonatomic, copy) NSArray<NSDictionary *> *tracks;
@property (nonatomic, copy) NSString *status;
@end

@implementation MRGPlaylistToolsPage
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Playlist tools";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.tableView.backgroundColor = UIColor.blackColor;
    UIEdgeInsets inset = self.tableView.contentInset; inset.bottom = 150; self.tableView.contentInset = inset;
    NSString *context = MRGPlayerContextURI();
    if ([context hasPrefix:@"spotify:playlist:"]) self.playlist = @{@"uri": context, @"name": @"Playing now"};
    if (self.playlist) [self loadTracks];
}
- (void)loadTracks {
    self.status = @"Reading the playlist…";
    [self.tableView reloadData];
    MRGPlaylistContents(self.playlist[@"uri"], ^(NSArray<NSDictionary *> *tracks, NSString *error) {
        self.tracks = tracks;
        self.status = error ?: [NSString stringWithFormat:@"%lu songs", (unsigned long)tracks.count];
        [self.tableView reloadData];
    });
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 4; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 1;
    if (s == 1) return 4;
    if (s == 2) return 2;
    return sUndo ? 1 : 0;
}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    return @[@"Playlist", @"Sort", @"More", @"Undo"][s];
}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    if (s == 0) return self.status;
    if (s == 2) return @"Sorting and removing duplicates ask first, and can be undone here. A shuffled copy is a new playlist; undoing it removes that playlist from your library. Spotify Free can edit playlists you own. Playing a chosen order can still be shuffled by Spotify, and the skip limit still applies.";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    return MRGSafeCell(ip, ^UITableViewCell *{
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        c.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.9];
        c.textLabel.textColor = UIColor.whiteColor;
        c.detailTextLabel.textColor = UIColor.grayColor;
        if (ip.section == 0) {
            c.textLabel.text = self.playlist[@"name"] ?: @"Choose a playlist";
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        if (ip.section == 1) c.textLabel.text = @[@"Date added", @"Title", @"Artist", @"Duration"][ip.row];
        else if (ip.section == 2) c.textLabel.text = ip.row == 0 ? @"Find duplicates" : @"Save a shuffled copy";
        else c.textLabel.text = @"Undo the last change";
        c.textLabel.textColor = self.tracks.count || ip.section == 3 || ip.section == 0 ? MRGAccent() : UIColor.grayColor;
        return c;
    });
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) { [self pickPlaylist]; return; }
    if (ip.section == 3 && sUndo) { [self undo]; return; }
    if (!self.tracks.count) return;
    if (ip.section == 1) [self sort:ip.row];
    else if (ip.row == 0) [self duplicates];
    else [self shuffleCopy];
}
- (void)pickPlaylist {
    MRGPlaylistLibrary(^(NSArray<NSDictionary *> *playlists, NSString *error) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Playlist" message:error preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSDictionary *p in playlists) {
            if (![p[@"uri"] hasPrefix:@"spotify:playlist:"]) continue;
            [a addAction:[UIAlertAction actionWithTitle:(p[@"name"] ?: p[@"uri"]) style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
                self.playlist = p;
                [self loadTracks];
            }]];
            if (a.actions.count > 40) break;
        }
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        a.popoverPresentationController.sourceView = self.view;
        [self presentViewController:a animated:YES completion:nil];
    });
}
- (void)confirm:(NSString *)title message:(NSString *)message go:(NSString *)go run:(void (^)(void))run {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:go style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { run(); }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)note:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (NSArray<NSDictionary *> *)sorted:(NSInteger)mode {
    return [self.tracks sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        if (mode == 0) return cmpAdded(a, b);
        NSString *ka = mode == 2 ? @"artist" : mode == 3 ? @"duration" : @"title";
        if (mode == 3) {
            double da = [a[@"duration"] doubleValue], db = [b[@"duration"] doubleValue];
            if (da == db) return 0;
            return da < db ? NSOrderedAscending : NSOrderedDescending;
        }
        return [norm(a[ka]) compare:norm(b[ka])];
    }];
}
- (void)rewrite:(NSArray<NSString *> *)uris done:(void (^)(BOOL ok, NSString *error))done {
    NSString *playlist = self.playlist[@"uri"];
    NSArray *current = urisOf(self.tracks);
    MRGPlaylistRemove(playlist, current, ^(BOOL ok, NSString *u, NSString *error) {
        if (!ok) { done(NO, error); return; }
        MRGPlaylistAdd(playlist, uris, ^(BOOL ok2, NSString *u2, NSString *error2) { done(ok2, error2); });
    });
}
- (void)sort:(NSInteger)mode {
    NSArray *sorted = [self sorted:mode];
    NSString *how = @[@"date added", @"title", @"artist", @"duration"][mode];
    BOOL dated = mode != 0 || self.tracks.firstObject[@"added"];
    NSString *extra = (mode == 0 && !dated) ? @" Spotify didn't send dates for these songs, so the order may not change." : @"";
    [self confirm:[@"Sort by " stringByAppendingString:how] message:[NSString stringWithFormat:@"This rewrites %lu songs.%@ You can undo it.", (unsigned long)sorted.count, extra] go:@"Sort" run:^{
        NSArray *original = urisOf(self.tracks);
        [self rewrite:urisOf(sorted) done:^(BOOL ok, NSString *error) {
            if (!ok) { [self note:@"Couldn't sort" message:error ?: @"Spotify refused the change."]; return; }
            sUndo = @{@"kind": @"rewrite", @"playlist": self.playlist[@"uri"], @"uris": original};
            self.tracks = sorted;
            self.status = [NSString stringWithFormat:@"Sorted by %@", how];
            [self.tableView reloadData];
        }];
    }];
}
- (void)duplicates {
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *drop = [NSMutableArray array], *keep = [NSMutableArray array];
    for (NSDictionary *t in self.tracks) {
        NSString *key = dupKey(t);
        if (!key.length || [seen containsObject:key] || [seen containsObject:t[@"uri"]]) [drop addObject:t];
        else { [seen addObject:key]; if (t[@"uri"]) [seen addObject:t[@"uri"]]; [keep addObject:t]; }
    }
    if (!drop.count) { [self note:@"No duplicates" message:@"Every song in this playlist is different."]; return; }
    // Spotify removes a track by its URI everywhere it appears, so when a copy is the very same track (not another
    // release of the song), removing it would take the kept one too (0.6.0 did that). Then the playlist is rewritten
    // with the kept songs in their order instead, the same way sorting works, and undo puts the old list back.
    NSSet *kept = [NSSet setWithArray:urisOf(keep)];
    BOOL sameURI = NO;
    for (NSString *u in urisOf(drop)) if ([kept containsObject:u]) { sameURI = YES; break; }
    if (sameURI) {
        [self confirm:@"Remove duplicates?" message:[NSString stringWithFormat:@"%lu copies will be removed and the playlist rewritten in the same order. You can undo it.", (unsigned long)drop.count] go:@"Remove" run:^{
            NSArray *original = urisOf(self.tracks);
            [self rewrite:urisOf(keep) done:^(BOOL ok, NSString *error) {
                if (!ok) { [self note:@"Couldn't remove them" message:error ?: @"Spotify refused."]; return; }
                sUndo = @{@"kind": @"rewrite", @"playlist": self.playlist[@"uri"], @"uris": original};
                self.tracks = keep;
                self.status = [NSString stringWithFormat:@"Removed %lu", (unsigned long)drop.count];
                [self.tableView reloadData];
            }];
        }];
        return;
    }
    [self confirm:@"Remove duplicates?" message:[NSString stringWithFormat:@"%lu copies will be removed. You can undo it.", (unsigned long)drop.count] go:@"Remove" run:^{
        MRGPlaylistRemove(self.playlist[@"uri"], urisOf(drop), ^(BOOL ok, NSString *u, NSString *error) {
            if (!ok) { [self note:@"Couldn't remove them" message:error ?: @"Spotify refused."]; return; }
            sUndo = @{@"kind": @"add", @"playlist": self.playlist[@"uri"], @"uris": urisOf(drop)};
            self.tracks = keep;
            self.status = [NSString stringWithFormat:@"Removed %lu", (unsigned long)drop.count];
            [self.tableView reloadData];
        });
    }];
}
- (void)shuffleCopy {
    NSMutableArray *ordered = [urisOf(self.tracks) mutableCopy];
    for (NSUInteger i = ordered.count; i > 1; i--) [ordered exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
    NSString *name = [NSString stringWithFormat:@"%@ · shuffled", self.playlist[@"name"] ?: @"Playlist"];
    [self confirm:@"Save a shuffled copy?" message:[NSString stringWithFormat:@"A new playlist, \"%@\", with %lu songs. The original stays as it is.", name, (unsigned long)ordered.count] go:@"Save" run:^{
        MRGPlaylistCreate(name, ordered, ^(BOOL ok, NSString *uri, NSString *error) {
            if (!ok || !uri.length) { [self note:@"Couldn't create it" message:error ?: @"Spotify refused."]; return; }
            sUndo = @{@"kind": @"delete", @"playlist": uri, @"name": name};
            self.status = [@"Saved " stringByAppendingString:name];
            [self.tableView reloadData];
        });
    }];
}
- (void)undo {
    NSDictionary *undo = sUndo;
    NSString *kind = undo[@"kind"];
    if ([kind isEqualToString:@"delete"]) {
        MRGPlaylistDelete(undo[@"playlist"], ^(BOOL ok, NSString *u, NSString *error) {
            if (!ok) { [self note:@"Couldn't undo" message:error]; return; }
            sUndo = nil;
            self.status = @"Removed the shuffled copy";
            [self.tableView reloadData];
        });
        return;
    }
    if ([kind isEqualToString:@"add"]) {
        MRGPlaylistAdd(undo[@"playlist"], undo[@"uris"], ^(BOOL ok, NSString *u, NSString *error) {
            if (!ok) { [self note:@"Couldn't undo" message:error]; return; }
            sUndo = nil;
            [self loadTracks];
        });
        return;
    }
    self.playlist = @{@"uri": undo[@"playlist"], @"name": self.playlist[@"name"] ?: @"Playlist"};
    MRGPlaylistContents(undo[@"playlist"], ^(NSArray<NSDictionary *> *tracks, NSString *error) {
        self.tracks = tracks;
        [self rewrite:undo[@"uris"] done:^(BOOL ok, NSString *rewriteError) {
            if (!ok) { [self note:@"Couldn't undo" message:rewriteError]; return; }
            sUndo = nil;
            [self loadTracks];
        }];
    });
}
@end

@interface MRGPlaylistToolsAddon : NSObject <MRGAddon>
@end
@implementation MRGPlaylistToolsAddon
- (NSString *)addonID { return kAddon; }
- (NSString *)addonName { return @"Playlist tools"; }
- (NSString *)addonCategory { return @"Library"; }
- (NSString *)addonVersion { return @"1.0"; }
- (NSString *)addonDescription { return @"Sort a playlist, remove duplicates, or save a shuffled copy. Nothing changes until you confirm, and you can undo it."; }
- (NSArray<MRGAddonSetting *> *)addonSettings { return @[]; }
- (UIViewController *)addonSettingsController { return [MRGPlaylistToolsPage new]; }
- (void)addonDidEnable {}
- (void)addonDidDisable {}
@end

__attribute__((constructor)) static void mrgPlaylistToolsConstructor(void) { MRGAddonRegister([MRGPlaylistToolsAddon new]); }
