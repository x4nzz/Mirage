// Add-on "On repeat" (Library): two lists from Mirage's own play history (what it records on this phone, plus an
// imported Spotify history): Recently played, newest first with when, and On repeat this week, the songs played
// most in the last 7 days (twice or more; the last 4 weeks when the week is thin). Tap a song to play it; Play all
// plays the list in order (the first song, the rest queued); Save makes it a playlist in your library.
// Nothing here guesses: a song is only listed if it was really played.
#import <UIKit/UIKit.h>
#import "MRGAddon.h"
#import "MRGAddons.h"
#import "MRGPrefs.h"
#import "MRGPlayer.h"
#import "MRGHistory.h"
#import "MRGPlaylists.h"
#import "MRGDJLog.h"

static NSString *const kAddon = @"on-repeat";

static NSArray<NSDictionary *> *recentList(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *e in MRGHistoryRecent(200)) {
        NSString *uri = e[@"uri"];
        if (![uri hasPrefix:@"spotify:track:"] || [seen containsObject:uri]) continue;
        [seen addObject:uri];
        [out addObject:e];
        if (out.count >= 50) break;
    }
    return out;
}

// Plays in the last 7 days, grouped by song; *weeks says when it had to use the last 4 weeks instead.
static NSArray<NSDictionary *> *repeatList(BOOL *weeks) {
    NSDate *since = [NSDate dateWithTimeIntervalSinceNow:-7 * 86400];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *by = [NSMutableDictionary dictionary];
    for (NSDictionary *e in MRGHistoryRecent(500)) {
        NSDate *at = e[@"at"];
        if (![at isKindOfClass:NSDate.class] || [at compare:since] == NSOrderedAscending) continue;
        NSString *uri = e[@"uri"];
        if (![uri hasPrefix:@"spotify:track:"]) continue;
        NSMutableDictionary *d = by[uri];
        if (!d) { d = [@{@"uri": uri, @"title": e[@"title"] ?: @"", @"artist": e[@"artist"] ?: @"", @"plays": @0} mutableCopy]; by[uri] = d; }
        d[@"plays"] = @([d[@"plays"] integerValue] + 1);
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in by.allValues) if ([d[@"plays"] integerValue] >= 2) [out addObject:d];
    [out sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"plays" ascending:NO]]];
    if (weeks) *weeks = NO;
    if (out.count < 3) {
        NSArray *month = MRGHistoryTaste()[@"onRepeat"];
        NSMutableArray *m = [NSMutableArray array];
        for (NSDictionary *t in [month isKindOfClass:NSArray.class] ? month : @[]) if ([t[@"uri"] hasPrefix:@"spotify:track:"]) [m addObject:t];
        if (m.count > out.count) { if (weeks) *weeks = YES; return [m subarrayWithRange:NSMakeRange(0, MIN(m.count, (NSUInteger)30))]; }
    }
    return [out subarrayWithRange:NSMakeRange(0, MIN(out.count, (NSUInteger)30))];
}

static void playList(NSArray<NSDictionary *> *list, NSUInteger from, void (^done)(NSString *note)) {
    if (from >= list.count) { done(@"Nothing to play"); return; }
    NSString *first = list[from][@"uri"];
    MRGPlayContextURI(first, nil, ^(BOOL ok, NSString *error) {
        if (!ok) { done(error ?: @"Spotify didn't start it"); return; }
        NSMutableArray *rest = [NSMutableArray array];
        for (NSUInteger i = from + 1; i < list.count && rest.count < 30; i++) [rest addObject:list[i][@"uri"]];
        if (!rest.count) { done(nil); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            MRGQueueTracks(rest, ^(BOOL qok, NSString *qerr) { done(qok ? nil : [@"Playing, but Spotify wouldn't queue the rest: " stringByAppendingString:qerr ?: @"refused"]); });
        });
    });
}

@interface MRGOnRepeatPage : UITableViewController
@end
@implementation MRGOnRepeatPage {
    UISegmentedControl *_tabs;
    NSArray<NSDictionary *> *_rows;
    BOOL _weeks;
    NSString *_note;
    id _observer;
}
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"On repeat";
    self.tableView.tintColor = MRGAccent();
    _tabs = [[UISegmentedControl alloc] initWithItems:@[@"Recently played", @"On repeat this week"]];
    _tabs.selectedSegmentIndex = MRGAddonInteger(kAddon, @"tab", 1);
    _tabs.selectedSegmentTintColor = MRGAccent();
    [_tabs setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateSelected];
    [_tabs addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = _tabs;
    __weak typeof(self) weak = self;
    _observer = [NSNotificationCenter.defaultCenter addObserverForName:MRGHistoryChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { [weak reload]; }];
    [self reload];
}
- (void)dealloc { if (_observer) [NSNotificationCenter.defaultCenter removeObserver:_observer]; }
- (void)reload {
    [NSUserDefaults.standardUserDefaults setInteger:_tabs.selectedSegmentIndex forKey:MRGAddonSettingKey(kAddon, @"tab")];
    BOOL weeks = NO;
    _rows = _tabs.selectedSegmentIndex == 0 ? recentList() : repeatList(&weeks);
    _weeks = weeks;
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 2; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return s == 0 ? 2 : MAX(1, (NSInteger)_rows.count); }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    if (s == 0) return nil;
    return _tabs.selectedSegmentIndex == 0 ? @"Newest first" : _weeks ? @"Most played, last 4 weeks" : @"Most played, last 7 days";
}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s { return s == 0 ? _note : nil; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (ip.section == 0) {
        c.textLabel.text = ip.row == 0 ? @"Play all" : @"Save as a playlist";
        c.imageView.image = [UIImage systemImageNamed:ip.row == 0 ? @"play.fill" : @"plus.rectangle.on.rectangle"];
        c.textLabel.textColor = _rows.count ? MRGAccent() : UIColor.secondaryLabelColor;
        c.imageView.tintColor = c.textLabel.textColor;
        return c;
    }
    if (!_rows.count) {
        c.textLabel.text = _tabs.selectedSegmentIndex == 0 ? @"Nothing played yet" : @"Nothing on repeat yet";
        c.detailTextLabel.text = @"Mirage lists what it has seen you play.";
        c.textLabel.textColor = UIColor.secondaryLabelColor;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    NSDictionary *e = _rows[ip.row];
    c.textLabel.text = [e[@"title"] length] ? e[@"title"] : @"Unknown song";
    NSString *sub = e[@"artist"] ?: @"";
    if (_tabs.selectedSegmentIndex == 0 && [e[@"at"] isKindOfClass:NSDate.class]) {
        static NSRelativeDateTimeFormatter *f;
        if (!f) { f = [NSRelativeDateTimeFormatter new]; f.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleShort; }
        sub = [NSString stringWithFormat:@"%@ · %@", sub, [f localizedStringForDate:e[@"at"] relativeToDate:NSDate.date]];
    } else if (e[@"plays"]) {
        sub = [NSString stringWithFormat:@"%@ · %@ plays", sub, e[@"plays"]];
    }
    c.detailTextLabel.text = sub;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    return c;
}
- (void)say:(NSString *)note { _note = note; [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone]; }
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (!_rows.count) return;
    __weak typeof(self) weak = self;
    if (ip.section == 1 || ip.row == 0) {
        NSUInteger from = ip.section == 1 ? (NSUInteger)ip.row : 0;
        [self say:@"Starting…"];
        playList(_rows, from, ^(NSString *note) { [weak say:note ?: @"Playing."]; });
        return;
    }
    NSMutableArray *uris = [NSMutableArray array];
    for (NSDictionary *e in _rows) [uris addObject:e[@"uri"]];
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"MMM d";
    NSString *name = [NSString stringWithFormat:@"%@ · %@", _tabs.selectedSegmentIndex == 0 ? @"Recently played" : @"On repeat", [df stringFromDate:NSDate.date]];
    [self say:@"Saving…"];
    MRGPlaylistCreate(name, uris, ^(BOOL ok, NSString *uri, NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weak say:ok ? [NSString stringWithFormat:@"Saved \"%@\" to your library.", name] : (error ?: @"Spotify didn't make the playlist.")]; });
    });
}
@end

@interface MRGOnRepeatAddon : NSObject <MRGAddon>
@end
@implementation MRGOnRepeatAddon
- (NSString *)addonID { return kAddon; }
- (NSString *)addonName { return @"On repeat"; }
- (NSString *)addonCategory { return @"Library"; }
- (NSString *)addonVersion { return @"1.0"; }
- (NSString *)addonDescription { return @"Recently played and this week's most played, from your real history."; }
- (NSInteger)addonBatteryImpact { return 0; }
- (NSString *)addonBatteryNote { return @"Low: reads your history when you open it."; }
- (NSArray<MRGAddonSetting *> *)addonSettings { return @[]; }
- (UIViewController *)addonSettingsController { return [MRGOnRepeatPage new]; }
- (void)addonDidEnable {}
- (void)addonDidDisable {}
@end

__attribute__((constructor)) static void MRGOnRepeatInit(void) { MRGAddonRegister([MRGOnRepeatAddon new]); }
