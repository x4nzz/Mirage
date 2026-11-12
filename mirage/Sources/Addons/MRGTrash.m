#import "Addons/MRGTrash.h"
#import "Addons/MRGAddon.h"
#import "MRGAddons.h"
#import "MRGPlayer.h"
#import "MRGPrefs.h"
#import "MRGSafe.h"
#import "MRGDJLog.h"
#import "MRGDiagnostics.h"

static NSString *const kAddon = @"trash";
static NSMutableArray<NSDictionary *> *sItems;
static NSUInteger sSkips;
static NSDate *sSkipHour;

static NSURL *fileURL(void) {
    NSURL *lib = [NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [lib URLByAppendingPathComponent:@"Mirage" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:@"trash.plist"];
}

static void load(void) {
    if (sItems) return;
    sItems = [NSMutableArray array];
    id saved = [NSArray arrayWithContentsOfURL:fileURL()];
    NSArray *list = [saved isKindOfClass:NSArray.class] ? saved : nil;
    for (id item in list) if ([item isKindOfClass:NSDictionary.class] && [item[@"uri"] isKindOfClass:NSString.class]) [sItems addObject:item];
}

static void save(void) { [sItems writeToURL:fileURL() atomically:YES]; }

BOOL MRGTrashContains(NSString *uri) {
    if (!MRGAddonInstalled(kAddon) || !uri.length) return NO;
    load();
    for (NSDictionary *item in sItems) if ([item[@"uri"] isEqualToString:uri]) return YES;
    return NO;
}

// A track trashed from a menu that isn't about the playing song: its name and artist from the Web API (GET /v1/tracks),
// with the token of Spotify's own requests. Left as "Track" when that isn't possible.
static void fillName(NSString *uri) {
    NSString *tid = [uri hasPrefix:@"spotify:track:"] ? [uri substringFromIndex:@"spotify:track:".length] : nil;
    NSString *auth = MRGSpotifyHeaders()[@"authorization"];
    if (!tid.length || !auth.length) return;
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"https://api.spotify.com/v1/tracks/" stringByAppendingString:tid]]];
    [r setValue:auth forHTTPHeaderField:@"Authorization"];
    r.timeoutInterval = 12;
    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *name = [json isKindOfClass:NSDictionary.class] && [json[@"name"] isKindOfClass:NSString.class] ? json[@"name"] : nil;
        NSArray *artists = [json isKindOfClass:NSDictionary.class] && [json[@"artists"] isKindOfClass:NSArray.class] ? json[@"artists"] : nil;
        NSDictionary *first = [artists.firstObject isKindOfClass:NSDictionary.class] ? artists.firstObject : nil;
        NSString *artist = [first[@"name"] isKindOfClass:NSString.class] ? first[@"name"] : nil;
        if (!name.length) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            load();
            for (NSUInteger i = 0; i < sItems.count; i++) {
                if (![sItems[i][@"uri"] isEqualToString:uri]) continue;
                NSMutableDictionary *row = [sItems[i] mutableCopy];
                row[@"title"] = name;
                if (artist.length) row[@"artist"] = artist;
                sItems[i] = row;
                save();
                MRGPostChange();
                break;
            }
        });
    }] resume];
}

void MRGTrashAdd(NSDictionary *track) {
    NSString *uri = track[@"uri"];
    if (![uri isKindOfClass:NSString.class] || ![uri hasPrefix:@"spotify:track:"]) return;
    load();
    for (NSDictionary *item in sItems) if ([item[@"uri"] isEqualToString:uri]) return;
    NSMutableDictionary *row = [@{@"uri": uri, @"date": NSDate.date} mutableCopy];
    if ([track[@"title"] isKindOfClass:NSString.class] && [track[@"title"] length]) row[@"title"] = track[@"title"];
    if ([track[@"artist"] isKindOfClass:NSString.class]) row[@"artist"] = track[@"artist"];
    [sItems insertObject:row atIndex:0];
    save();
    if (!row[@"title"] || ![row[@"title"] length]) fillName(uri);
    MRGDJLog(@"trash: kept %@", row[@"title"] ?: uri);
    MRGPostChange();
}

void MRGTrashRestore(NSString *uri) {
    load();
    NSUInteger i = [sItems indexOfObjectPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) { return [item[@"uri"] isEqualToString:uri]; }];
    if (i == NSNotFound) return;
    [sItems removeObjectAtIndex:i];
    save();
    MRGPostChange();
}

NSArray<NSDictionary *> *MRGTrashAll(void) { load(); return sItems; }

static BOOL skipBudget(void) {
    if (!sSkipHour || [sSkipHour timeIntervalSinceNow] < -3600) { sSkipHour = NSDate.date; sSkips = 0; }
    if (sSkips >= 6) return NO;
    sSkips++;
    return YES;
}

static void skipIfTrashed(NSDictionary *track) {
    if (!MRGAddonInstalled(kAddon) || [track[@"ad"] boolValue]) return;
    if (!MRGTrashContains(track[@"uri"])) return;
    if (!skipBudget()) {
        MRGDJLog(@"trash: not skipping %@ — Spotify Free allows about 6 skips an hour", track[@"title"] ?: track[@"uri"]);
        return;
    }
    MRGDJLog(@"trash: skipping %@", track[@"title"] ?: track[@"uri"]);
    MRGCrumb(@"trash skip %@", track[@"uri"]);
    MRGPlayerControl(@"next", nil);
}

@interface MRGTrashList : UITableViewController
@end
@implementation MRGTrashList
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Trash";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.tableView.backgroundColor = UIColor.blackColor;
    UIEdgeInsets inset = self.tableView.contentInset; inset.bottom = 150; self.tableView.contentInset = inset;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:MRGSettingsChangedNotification object:nil];
}
- (void)reload { [self.tableView reloadData]; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return MAX((NSInteger)MRGTrashAll().count, 1); }
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    return @"Swipe a song to put it back.";
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    return MRGSafeCell(ip, ^UITableViewCell *{
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        c.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.9];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        NSArray *items = MRGTrashAll();
        if (!items.count) {
            c.textLabel.text = @"Nothing in the trash";
            c.textLabel.textColor = UIColor.grayColor;
            return c;
        }
        NSDictionary *item = items[ip.row];
        c.textLabel.text = item[@"title"] ?: @"Track";
        c.textLabel.textColor = UIColor.whiteColor;
        c.detailTextLabel.text = item[@"artist"];
        c.detailTextLabel.textColor = UIColor.grayColor;
        return c;
    });
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)t trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (!MRGTrashAll().count) return nil;
    NSString *uri = MRGTrashAll()[ip.row][@"uri"];
    UIContextualAction *restore = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Restore" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        MRGTrashRestore(uri);
        done(YES);
    }];
    restore.backgroundColor = MRGAccent();
    return [UISwipeActionsConfiguration configurationWithActions:@[restore]];
}
@end

UIViewController *MRGTrashPage(void) { return [MRGTrashList new]; }

@interface MRGTrashAddon : NSObject <MRGAddon>
@end
@implementation MRGTrashAddon
- (NSString *)addonID { return kAddon; }
- (NSString *)addonName { return @"Trash"; }
- (NSString *)addonCategory { return @"Playback"; }
- (NSString *)addonVersion { return @"1.0"; }
- (NSString *)addonDescription { return @"Trash songs from Now Playing or their menu; they're skipped everywhere."; }
- (NSArray<MRGAddonSetting *> *)addonSettings { return @[]; }
- (UIViewController *)addonSettingsController { return MRGTrashPage(); }
- (void)addonDidEnable {}
- (void)addonDidDisable {}
- (NSString *)addonSummary { return [NSString stringWithFormat:@"%lu", (unsigned long)MRGTrashAll().count]; }
@end

__attribute__((constructor)) static void mrgTrashConstructor(void) {
    MRGAddonRegister([MRGTrashAddon new]);
    [NSNotificationCenter.defaultCenter addObserverForName:MRGPlayerTrackChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        skipIfTrashed(n.userInfo);
    }];
}
