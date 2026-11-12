// Queue tools: a page with Spotify's real queue (drag to reorder, swipe to remove, and "Play next" on the
// playlist's own upcoming songs), and two rows in Spotify's track menu: Play next, and Queue after this album.
// Every change goes through the player's own queue (fetchQueue:on: / setQueue:, the call Mirage's queue clear has
// used since 0.4.3), so what the page shows is what plays. Spotify Free can refuse queue changes: the page says so.
#import "Addons/MRGAddon.h"
#import "Addons/MRGTrash.h"
#import "MRGAddons.h"
#import "MRGPlayer.h"
#import "MRGPrefs.h"
#import "MRGDJLog.h"
#import "MRGCompat.h"
#import <objc/runtime.h>

static NSString *const kAddon = @"queue-tools";
static char kMenuKey;

#pragma mark - after this album

// Songs waiting for the album that's playing to end. On every track change: once the next song isn't from the
// current song's album any more (or there is no album), they go in at the front of the queue.
static NSMutableArray<NSString *> *sAfterAlbum;
static NSString *sAfterAlbumOf;   // the album they wait for

static void flushAfterAlbum(NSString *why) {
    if (!sAfterAlbum.count) return;
    NSArray *uris = [sAfterAlbum copy];
    [sAfterAlbum removeAllObjects];
    sAfterAlbumOf = nil;
    MRGQueuePlayNext(uris, ^(BOOL ok, NSString *error) {
        MRGDJLog(@"queue tools: %lu song(s) after the album %@ (%@)", (unsigned long)uris.count, ok ? @"queued" : @"refused", why);
        if (!ok) MRGDJLog(@"queue tools: %@", error ?: @"?");
    });
}

static void checkAlbum(void) {
    if (!sAfterAlbum.count) return;
    NSDictionary *now = MRGNowPlaying();
    NSString *album = [now[@"album"] isKindOfClass:NSString.class] ? now[@"album"] : nil;
    if (!album.length) { flushAfterAlbum(@"no album on"); return; }
    if (sAfterAlbumOf.length && ![album isEqualToString:sAfterAlbumOf]) { flushAfterAlbum(@"the album ended"); return; }
    sAfterAlbumOf = album;
    MRGFetchQueue(^(NSArray *queued, NSArray *upNext, NSString *error) {
        NSDictionary *next = nil;
        for (NSDictionary *t in upNext) if (![t[@"provider"] isEqualToString:@"queue"]) { next = t; break; }
        // Spotify's queued songs play first anyway; the album's own next song is what decides.
        if (!next || ![next[@"album"] isEqualToString:album]) flushAfterAlbum(@"the album's last song is on");
    });
}

static void queueAfterAlbum(NSString *uri) {
    if (!sAfterAlbum) sAfterAlbum = [NSMutableArray array];
    if (![sAfterAlbum containsObject:uri]) [sAfterAlbum addObject:uri];
    checkAlbum();
}

#pragma mark - the page

@interface MRGQueuePage : UITableViewController
@end

@implementation MRGQueuePage {
    NSMutableArray<NSDictionary *> *_queued;
    NSArray<NSDictionary *> *_upNext;
    NSString *_note;
}
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Queue tools";
    self.tableView.backgroundColor = UIColor.blackColor;
    self.view.tintColor = MRGAccent();
    self.navigationItem.rightBarButtonItem = self.editButtonItem;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:MRGPlayerTrackChangedNotification object:nil];
    [self reload];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)reload {
    MRGFetchQueue(^(NSArray *queued, NSArray *upNext, NSString *error) {
        self->_queued = [queued mutableCopy] ?: [NSMutableArray array];
        NSMutableArray *rest = [NSMutableArray array];
        for (NSDictionary *t in upNext) if (![t[@"provider"] isEqualToString:@"queue"] && rest.count < 20) [rest addObject:t];
        self->_upNext = rest;
        self->_note = error;
        [self.refreshControl endRefreshing];
        if (!self.tableView.isEditing) [self.tableView reloadData];
    });
}
- (void)changed:(BOOL)ok error:(NSString *)error {
    _note = ok ? nil : [@"Spotify refused: " stringByAppendingString:error ?: @"?"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self reload]; });
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 3; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return MRGNowPlaying() ? 1 : 0;
    return s == 1 ? (NSInteger)_queued.count : (NSInteger)_upNext.count;
}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return @[@"Now playing", @"Queued", @"Next from the playlist"][s]; }
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    if (s == 1) return _note ?: (_queued.count ? @"Drag to reorder, swipe to remove." : @"Nothing queued.");
    if (s == 2 && _upNext.count) return @"Swipe a song to play it next.";
    if (s == 2 && sAfterAlbum.count) return [NSString stringWithFormat:@"%lu waiting for the album to end.", (unsigned long)sAfterAlbum.count];
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.9];
    c.textLabel.textColor = UIColor.whiteColor;
    c.detailTextLabel.textColor = UIColor.grayColor;
    NSDictionary *d = ip.section == 0 ? MRGNowPlaying() : ip.section == 1 ? (ip.row < (NSInteger)_queued.count ? _queued[ip.row] : nil) : (ip.row < (NSInteger)_upNext.count ? _upNext[ip.row] : nil);
    c.textLabel.text = [d[@"title"] isKindOfClass:NSString.class] ? d[@"title"] : @"—";
    c.detailTextLabel.text = [d[@"artist"] isKindOfClass:NSString.class] ? d[@"artist"] : @"";
    c.showsReorderControl = ip.section == 1;
    return c;
}
- (BOOL)tableView:(UITableView *)t canEditRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 1; }
- (BOOL)tableView:(UITableView *)t canMoveRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 1; }
- (NSIndexPath *)tableView:(UITableView *)t targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)from toProposedIndexPath:(NSIndexPath *)to {
    if (to.section == 1) return to;
    return [NSIndexPath indexPathForRow:(to.section < 1 ? 0 : MAX(0, (NSInteger)_queued.count - 1)) inSection:1];
}
- (void)tableView:(UITableView *)t moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    if (from.row >= (NSInteger)_queued.count || to.row >= (NSInteger)_queued.count) return;
    NSDictionary *d = _queued[from.row];
    [_queued removeObjectAtIndex:from.row];
    [_queued insertObject:d atIndex:to.row];
    NSMutableArray *order = [NSMutableArray array];
    for (NSDictionary *x in _queued) if ([x[@"uri"] isKindOfClass:NSString.class]) [order addObject:x[@"uri"]];
    MRGQueueReorder(order, ^(BOOL ok, NSString *error) { [self changed:ok error:error]; });
}
- (void)tableView:(UITableView *)t commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete || ip.section != 1 || ip.row >= (NSInteger)_queued.count) return;
    NSString *uri = _queued[ip.row][@"uri"];
    [_queued removeObjectAtIndex:ip.row];
    [t deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
    if (uri) MRGQueueRemove(@[uri], ^(BOOL ok, NSString *error) { [self changed:ok error:error]; });
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)t leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section != 2 || ip.row >= (NSInteger)_upNext.count) return nil;
    NSString *uri = _upNext[ip.row][@"uri"];
    UIContextualAction *next = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Play next" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        if (uri) MRGQueuePlayNext(@[uri], ^(BOOL ok, NSString *error) { [self changed:ok error:error]; });
        done(YES);
    }];
    next.backgroundColor = MRGAccent();
    return [UISwipeActionsConfiguration configurationWithActions:@[next]];
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip { [t deselectRowAtIndexPath:ip animated:YES]; }
@end

#pragma mark - Spotify's track menu

static UIButton *menuButton(NSString *title, NSString *symbol, void (^tap)(void)) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    b.tintColor = MRGAccent();
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    [b addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) { tap(); }] forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static void addMenuRows(UIViewController *menu) {
    if (!MRGAddonInstalled(kAddon) || objc_getAssociatedObject(menu, &kMenuKey)) return;
    NSString *uri = MRGContextMenuTrackURI(menu);
    UITableView *table = uri ? MRGContextMenuTable(menu) : nil;
    if (!table) return;
    BOOL footerFree = !table.tableFooterView || table.tableFooterView.bounds.size.height < 1;
    BOOL headerFree = !table.tableHeaderView || table.tableHeaderView.bounds.size.height < 1;
    if (!footerFree && !headerFree) return;
    objc_setAssociatedObject(menu, &kMenuKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIViewController *weakMenu = menu;
    NSString *kept = [uri copy];
    UIButton *next = menuButton(@" Play next", @"text.line.first.and.arrowtriangle.forward", ^{
        MRGQueuePlayNext(@[kept], ^(BOOL ok, NSString *error) { MRGDJLog(@"queue tools: play next %@", ok ? @"queued" : error ?: @"refused"); });
        [weakMenu dismissViewControllerAnimated:YES completion:nil];
    });
    UIButton *after = menuButton(@" After this album", @"square.stack", ^{
        queueAfterAlbum(kept);
        [weakMenu dismissViewControllerAnimated:YES completion:nil];
    });
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[next, after]];
    row.distribution = UIStackViewDistributionFillEqually;
    row.frame = CGRectMake(0, 0, table.bounds.size.width, 52);
    if (footerFree) table.tableFooterView = row; else table.tableHeaderView = row;
}

%group MRGQueueMenu
%hook _TtC24ContextMenu_InternalImpl25ContextMenuViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    @try { addMenuRows((UIViewController *)self); } @catch (NSException *e) { MRGDJLog(@"queue tools: menu rows threw %@", e.reason); }
}
%end
%end

@interface MRGQueueToolsAddon : NSObject <MRGAddon>
@end
@implementation MRGQueueToolsAddon
- (NSString *)addonID { return kAddon; }
- (NSString *)addonName { return @"Queue tools"; }
- (NSString *)addonCategory { return @"Playback"; }
- (NSString *)addonVersion { return @"1.0"; }
- (NSString *)addonDescription { return @"Reorder Spotify's real queue, Play next, and queue a song for after the album that's playing."; }
- (NSArray<MRGAddonSetting *> *)addonSettings { return @[]; }
- (UIViewController *)addonSettingsController { return [MRGQueuePage new]; }
- (void)addonDidEnable {}
- (void)addonDidDisable { [sAfterAlbum removeAllObjects]; sAfterAlbumOf = nil; }
- (NSString *)addonSummary { return sAfterAlbum.count ? [NSString stringWithFormat:@"%lu after this album", (unsigned long)sAfterAlbum.count] : @"Open the queue"; }
@end

%ctor {
    MRGAddonRegister([MRGQueueToolsAddon new]);
    if (NSClassFromString(@"_TtC24ContextMenu_InternalImpl25ContextMenuViewController") && MRGFragileHooksAllowed(@"Queue tools menu rows")) %init(MRGQueueMenu);
    [NSNotificationCenter.defaultCenter addObserverForName:MRGPlayerTrackChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        if (!sAfterAlbum.count) return;
        // a moment for the player's up-next to catch up with the new song
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ @try { checkAlbum(); } @catch (NSException *e) {} });
    }];
}
