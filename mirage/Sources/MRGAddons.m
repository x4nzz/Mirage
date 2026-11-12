#import "MRGAddons.h"
#import "MRGPrefs.h"
#import "MRGSafe.h"
#import "MRGDJLog.h"
#import "Addons/MRGAddonArt.h"

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }
static NSString *const kIndexURL = @"https://raw.githubusercontent.com/x4nzz/Mirage/main/addons/index.json";

// The same as addons/index.json in the repo, for a first launch offline or a GitHub that doesn't answer.
static NSString *const kBundledIndex = @"{\"format\":1,\"addons\":[{\"id\":\"vinyl\",\"name\":\"Vinyl\",\"description\":\"Turns the Now Playing cover into a record sleeve. The cover slides to one side and a vinyl record peeks out from behind it. The record spins while music plays, stops when you pause, and its label shows the album art. You can pick the spin speed and the side the record sits on.\",\"preview\":\"https://raw.githubusercontent.com/x4nzz/Mirage/main/addons/previews/vinyl.png\",\"version\":\"1.1\",\"type\":\"Now Playing\",\"author\":\"Mirage\",\"min_mirage\":\"0.5.0\"},{\"id\":\"dynamic-colors\",\"name\":\"Dynamic colors\",\"description\":\"Takes a color from the album cover and tints Mirage's accent, toggles and Vitrine's glass. Cached per song, so a track change doesn't flash or stutter. A theme can keep its own accent.\",\"version\":\"1.0\",\"type\":\"Look\",\"author\":\"Mirage\",\"min_mirage\":\"0.6.0\"},{\"id\":\"playlist-tools\",\"name\":\"Playlist tools\",\"description\":\"Sort a playlist, remove duplicates, or save a shuffled copy. Every change asks first and can be undone.\",\"version\":\"1.0\",\"type\":\"Library\",\"author\":\"Mirage\",\"min_mirage\":\"0.6.0\"},{\"id\":\"genres\",\"name\":\"Genres\",\"description\":\"Shows the current song's genres on Now Playing. Uses Spotify's own player data when it has genres, otherwise the artist's genres, cached on this phone.\",\"version\":\"1.0\",\"type\":\"Now Playing\",\"author\":\"Mirage\",\"min_mirage\":\"0.6.0\"},{\"id\":\"popup-lyrics\",\"name\":\"Pop-up lyrics\",\"description\":\"A synced lyrics shelf at the top of Home, Apple Music style: the current line big and bright, the next ones soft, scrolling with the song. It pushes Home down like any shelf and opens the player when tapped.\",\"version\":\"2.0\",\"type\":\"Home\",\"author\":\"Mirage\",\"min_mirage\":\"0.6.0\"},{\"id\":\"trash\",\"name\":\"Trash\",\"description\":\"Move a song to the trash from Now Playing or its menu. Trashed songs are skipped in queues, playlists and the AI DJ. Restore them from the list.\",\"version\":\"1.0\",\"type\":\"Playback\",\"author\":\"Mirage\",\"min_mirage\":\"0.6.0\"},{\"id\":\"shuffle-plus\",\"name\":\"Shuffle+\",\"description\":\"Shuffle a playlist or album without playing the same artist twice in a row, and without starting on songs you just heard. Uses Spotify's own queue.\",\"version\":\"1.0\",\"type\":\"Playback\",\"author\":\"Mirage\",\"min_mirage\":\"0.6.0\"}]}";

BOOL MRGAddonBuiltIn(NSString *addonID) {
    return MRGAddonObject(addonID) != nil || [@[@"vinyl"] containsObject:addonID ?: @""];
}
BOOL MRGAddonInstalled(NSString *addonID) { return addonID.length && MRGAddonBuiltIn(addonID) && [D() boolForKey:[@"mirage.addon." stringByAppendingString:addonID]]; }
void MRGAddonSetInstalled(NSString *addonID, BOOL on) {
    if (!addonID.length || !MRGAddonBuiltIn(addonID)) return;
    [D() setBool:on forKey:[@"mirage.addon." stringByAppendingString:addonID]];
    if (on) MRGAddonClearCrashNotice(addonID);
    MRGDJLog(@"addons: %@ %@", addonID, on ? @"installed" : @"removed");
    if (on) MRGAddonRunEnable(addonID);
    else MRGAddonRunDisable(addonID);
    MRGPostChange();
}
NSUInteger MRGAddonsInstalledCount(void) {
    NSUInteger n = 0;
    for (NSDictionary *a in MRGAddonIndex()) if (MRGAddonInstalled(a[@"id"])) n++;
    return n;
}

double MRGVinylSecondsPerTurn(void) { id v = [D() objectForKey:@"mirage.addon.vinyl.turn"]; double s = [v isKindOfClass:NSNumber.class] ? [v doubleValue] : 1.8; return MIN(8, MAX(0.8, s)); }
void MRGVinylSetSecondsPerTurn(double s) { [D() setDouble:s forKey:@"mirage.addon.vinyl.turn"]; MRGPostChange(); }
BOOL MRGVinylOnLeft(void) { return [D() boolForKey:@"mirage.addon.vinyl.left"]; }
void MRGVinylSetOnLeft(BOOL left) { [D() setBool:left forKey:@"mirage.addon.vinyl.left"]; MRGPostChange(); }

static NSArray<NSDictionary *> *parseIndex(NSData *data) {
    id j = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray *list = [j isKindOfClass:NSDictionary.class] && [j[@"addons"] isKindOfClass:NSArray.class] ? j[@"addons"] : nil;
    NSMutableArray *out = [NSMutableArray array];
    for (id a in list) {
        if (![a isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (NSString *k in @[@"id", @"name", @"description", @"preview", @"version", @"type", @"author", @"min_mirage"])
            if ([a[k] isKindOfClass:NSString.class]) m[k] = a[k];
        if ([m[@"id"] length] && [m[@"name"] length]) [out addObject:m];
    }
    return out.count ? out : nil;
}

// Registered add-ons always appear, even when the fetched index is older than this build.
static NSArray<NSDictionary *> *mergeRegistered(NSArray<NSDictionary *> *index) {
    NSMutableArray *out = [NSMutableArray arrayWithArray:index ?: @[]];
    NSMutableSet *ids = [NSMutableSet set];
    for (NSDictionary *a in out) if ([a[@"id"] isKindOfClass:NSString.class]) [ids addObject:a[@"id"]];
    // 0.6.6: an add-on built into this Mirage describes itself (its one-line description and version), whatever an
    // older fetched index says; the index still gives its preview art and anything else.
    for (NSUInteger i = 0; i < out.count; i++) {
        id<MRGAddon> addon = [out[i][@"id"] isKindOfClass:NSString.class] ? MRGAddonObject(out[i][@"id"]) : nil;
        if (!addon) continue;
        NSMutableDictionary *m = [out[i] mutableCopy];
        if (addon.addonDescription.length) m[@"description"] = addon.addonDescription;
        if (addon.addonVersion.length) m[@"version"] = addon.addonVersion;
        out[i] = m;
    }
    for (id<MRGAddon> addon in MRGRegisteredAddons()) {
        if ([ids containsObject:addon.addonID]) continue;
        [out addObject:@{@"id": addon.addonID, @"name": addon.addonName ?: addon.addonID,
                         @"description": addon.addonDescription ?: @"", @"version": addon.addonVersion ?: @"1",
                         @"type": addon.addonCategory ?: @"Add-on", @"author": @"Mirage", @"min_mirage": @"0.6.0"}];
    }
    return out;
}

NSArray<NSDictionary *> *MRGAddonIndex(void) {
    NSData *cached = [D() dataForKey:@"mirage.addons.index"];
    return mergeRegistered(parseIndex(cached) ?: parseIndex([kBundledIndex dataUsingEncoding:NSUTF8StringEncoding]) ?: @[]);
}

void MRGAddonRefresh(void (^done)(NSArray<NSDictionary *> *, NSString *)) {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kIndexURL]];
    r.timeoutInterval = 12;
    r.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSInteger st = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        NSArray *list = st == 200 ? parseIndex(data) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (list) [D() setObject:data forKey:@"mirage.addons.index"];
            NSString *err = list ? nil : [NSString stringWithFormat:@"Couldn't load the shop from GitHub (%@); showing the built-in list.", error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)st]];
            if (err) MRGDJLog(@"addons: %@", err);
            done(MRGAddonIndex(), err);
        });
    }] resume];
}

// "0.5.0" ≥ "0.4.10" by numbers.
static BOOL versionAtLeast(NSString *have, NSString *need) {
    if (!need.length) return YES;
    return [have compare:need options:NSNumericSearch] != NSOrderedAscending;
}

#pragma mark - preview images (downloaded once, kept in Caches)

static NSCache *sImages;
static NSURL *imageFile(NSDictionary *a) {
    NSURL *dir = [[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"MirageAddons"];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *name = [NSString stringWithFormat:@"%@-%@.img", a[@"id"], a[@"version"] ?: @"0"];
    return [dir URLByAppendingPathComponent:[name stringByReplacingOccurrencesOfString:@"/" withString:@"_"]];
}
static void loadPreview(NSDictionary *a, void (^done)(UIImage *)) {
    if (!sImages) sImages = [NSCache new];
    NSString *key = [NSString stringWithFormat:@"%@-%@", a[@"id"], a[@"version"]];
    UIImage *hit = [sImages objectForKey:key];
    if (hit) { done(hit); return; }
    NSURL *file = imageFile(a);
    UIImage *disk = [UIImage imageWithContentsOfFile:file.path];
    if (disk) { [sImages setObject:disk forKey:key]; done(disk); return; }
    NSURL *url = [a[@"preview"] hasPrefix:@"https://"] ? [NSURL URLWithString:a[@"preview"]] : nil;
    if (!url) { done(nil); return; }
    [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        UIImage *img = data.length ? [UIImage imageWithData:data] : nil;
        if (img) [data writeToURL:file atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{ if (img) [sImages setObject:img forKey:key]; done(img); });
    }] resume];
}

#pragma mark - a card

// One card per add-on: its own picture, name, what it does, and one switch. The switch is the only control and its
// label reads the stored state ("On" / "Off"), so the card can't say one thing while the add-on does another.
@interface MRGAddonCard : UITableViewCell
@property (nonatomic, copy) NSDictionary *addon;
@property (nonatomic, copy) void (^onToggle)(BOOL on);
- (void)refreshState;
@end

@implementation MRGAddonCard {
    UIImageView *_art, *_icon;
    UILabel *_name, *_meta, *_desc, *_state, *_badge, *_chip, *_battery;
    UIView *_rule, *_dot;
    UISwitch *_switch;
}

static UILabel *pill(UIFont *font) {
    UILabel *l = [UILabel new];
    l.font = font;
    l.textAlignment = NSTextAlignmentCenter;
    l.layer.cornerRadius = 11;
    l.layer.cornerCurve = kCACornerCurveContinuous;
    l.clipsToBounds = YES;
    return l;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    if (!(self = [super initWithStyle:style reuseIdentifier:rid])) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.86];
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    _art = [UIImageView new];
    _art.contentMode = UIViewContentModeScaleAspectFill;
    _art.clipsToBounds = YES;
    _art.layer.cornerRadius = 16;
    _art.layer.cornerCurve = kCACornerCurveContinuous;
    _art.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1];
    _art.layer.borderWidth = 0.5;
    _art.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
    _chip = pill([UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]);
    _chip.textColor = UIColor.whiteColor;
    _chip.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    _badge = pill([UIFont systemFontOfSize:12 weight:UIFontWeightHeavy]);
    _icon = [UIImageView new];
    _icon.layer.shadowColor = UIColor.blackColor.CGColor;
    _icon.layer.shadowOpacity = 0.35;
    _icon.layer.shadowRadius = 5;
    _icon.layer.shadowOffset = CGSizeMake(0, 2);
    _name = [UILabel new];
    _name.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    _name.textColor = UIColor.whiteColor;
    _name.adjustsFontSizeToFitWidth = YES;
    _name.minimumScaleFactor = 0.8;
    _meta = [UILabel new];
    _meta.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _meta.textColor = [UIColor colorWithWhite:0.6 alpha:1];
    _desc = [UILabel new];
    _desc.font = [UIFont systemFontOfSize:15];
    _desc.textColor = [UIColor colorWithWhite:0.78 alpha:1];
    _desc.numberOfLines = 0;
    _battery = [UILabel new];
    _battery.numberOfLines = 0;
    _rule = [UIView new];
    _rule.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _dot = [UIView new];
    _dot.layer.cornerRadius = 4;
    _state = [UILabel new];
    _state.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _switch = [UISwitch new];
    [_switch addTarget:self action:@selector(flipped) forControlEvents:UIControlEventValueChanged];
    for (UIView *v in @[_art, _chip, _badge, _icon, _name, _meta, _desc, _battery, _rule, _dot, _state, _switch]) { v.translatesAutoresizingMaskIntoConstraints = NO; [self.contentView addSubview:v]; }
    UILayoutGuide *g = self.contentView.layoutMarginsGuide;
    NSLayoutConstraint *bottom = [_switch.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-14];
    bottom.priority = UILayoutPriorityRequired - 1;
    [NSLayoutConstraint activateConstraints:@[
        [_art.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:14],
        [_art.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_art.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [_art.heightAnchor constraintEqualToAnchor:_art.widthAnchor multiplier:9.0 / 16.0],
        [_chip.topAnchor constraintEqualToAnchor:_art.topAnchor constant:10],
        [_chip.leadingAnchor constraintEqualToAnchor:_art.leadingAnchor constant:10],
        [_chip.heightAnchor constraintEqualToConstant:22],
        [_badge.topAnchor constraintEqualToAnchor:_art.topAnchor constant:10],
        [_badge.trailingAnchor constraintEqualToAnchor:_art.trailingAnchor constant:-10],
        [_badge.heightAnchor constraintEqualToConstant:22],
        [_icon.topAnchor constraintEqualToAnchor:_art.bottomAnchor constant:14],
        [_icon.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_icon.widthAnchor constraintEqualToConstant:44],
        [_icon.heightAnchor constraintEqualToConstant:44],
        [_name.topAnchor constraintEqualToAnchor:_icon.topAnchor constant:-1],
        [_name.leadingAnchor constraintEqualToAnchor:_icon.trailingAnchor constant:12],
        [_name.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [_meta.topAnchor constraintEqualToAnchor:_name.bottomAnchor constant:1],
        [_meta.leadingAnchor constraintEqualToAnchor:_name.leadingAnchor],
        [_meta.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [_desc.topAnchor constraintEqualToAnchor:_icon.bottomAnchor constant:12],
        [_desc.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_desc.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [_battery.topAnchor constraintEqualToAnchor:_desc.bottomAnchor constant:8],
        [_battery.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_battery.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [_rule.topAnchor constraintEqualToAnchor:_battery.bottomAnchor constant:14],
        [_rule.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_rule.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [_rule.heightAnchor constraintEqualToConstant:1],
        [_switch.topAnchor constraintEqualToAnchor:_rule.bottomAnchor constant:12],
        [_switch.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        bottom,
        [_dot.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_dot.centerYAnchor constraintEqualToAnchor:_switch.centerYAnchor],
        [_dot.widthAnchor constraintEqualToConstant:8],
        [_dot.heightAnchor constraintEqualToConstant:8],
        [_state.leadingAnchor constraintEqualToAnchor:_dot.trailingAnchor constant:8],
        [_state.centerYAnchor constraintEqualToAnchor:_switch.centerYAnchor],
        [_state.trailingAnchor constraintLessThanOrEqualToAnchor:_switch.leadingAnchor constant:-8],
    ]];
    return self;
}

- (void)setAddon:(NSDictionary *)a {
    _addon = [a copy];
    _name.text = a[@"name"];
    NSMutableArray *meta = [NSMutableArray array];
    if (a[@"version"]) [meta addObject:[@"Version " stringByAppendingString:a[@"version"]]];
    if (a[@"author"]) [meta addObject:[@"by " stringByAppendingString:a[@"author"]]];
    _meta.text = [meta componentsJoinedByString:@"  ·  "];
    _desc.text = a[@"description"];
    _battery.attributedText = MRGAddonBatteryLine(a[@"id"], [UIFont systemFontOfSize:13 weight:UIFontWeightMedium]);
    _chip.text = [a[@"type"] length] ? [NSString stringWithFormat:@"  %@  ", a[@"type"]] : nil;
    _chip.hidden = !_chip.text.length;
    NSString *mine = a[@"id"];
    CGFloat w = MAX(300, self.contentView.bounds.size.width);
    _art.image = MRGAddonArt(mine, CGSizeMake(w, round(w * 9 / 16)));
    _icon.image = MRGAddonIcon(mine, 44);
    // A preview from the index is only used for add-ons this build doesn't draw itself.
    if (!MRGAddonHasArt(mine))
        loadPreview(a, ^(UIImage *img) { if (img && [self->_addon[@"id"] isEqualToString:mine]) self->_art.image = img; });
    [self refreshState];
}

- (void)refreshState {
    NSDictionary *a = _addon;
    BOOL builtIn = MRGAddonBuiltIn(a[@"id"]) && versionAtLeast(@MRG_VERSION, a[@"min_mirage"]);
    BOOL on = builtIn && MRGAddonInstalled(a[@"id"]);
    UIColor *accent = MRGAccent();
    if (_switch.on != on) [_switch setOn:on animated:self.window != nil];
    _switch.enabled = builtIn;
    _switch.onTintColor = accent;
    _state.text = !builtIn ? [NSString stringWithFormat:@"Needs Mirage %@", a[@"min_mirage"] ?: @"update"] : on ? @"On" : @"Off";
    _state.textColor = on ? UIColor.whiteColor : [UIColor colorWithWhite:0.55 alpha:1];
    _dot.backgroundColor = on ? accent : [UIColor colorWithWhite:0.35 alpha:1];
    _badge.hidden = !on;
    _badge.text = @"  ON  ";
    _badge.backgroundColor = accent;
    _badge.textColor = MRGOnAccent();
    self.accessibilityValue = _state.text;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Redrawn once the real width is known, so the picture is sharp on any phone.
    if (_addon && _art.image && fabs(_art.image.size.width - _art.bounds.size.width) > 2 && _art.bounds.size.width > 100 && MRGAddonHasArt(_addon[@"id"]))
        _art.image = MRGAddonArt(_addon[@"id"], _art.bounds.size);
}

- (void)flipped {
    [[UISelectionFeedbackGenerator new] selectionChanged];
    if (self.onToggle) self.onToggle(_switch.on);
}
@end

#pragma mark - the shop

static NSString *addonSummary(NSDictionary *a) {
    id<MRGAddon> addon = MRGAddonObject(a[@"id"]);
    if ([addon respondsToSelector:@selector(addonSummary)]) {
        NSString *s = [addon addonSummary];
        if (s.length) return s;
    }
    if ([a[@"id"] isEqualToString:@"vinyl"])
        return [NSString stringWithFormat:@"%@ · %@", MRGVinylSecondsPerTurn() > 2.5 ? @"Slow" : MRGVinylSecondsPerTurn() > 1.5 ? @"33⅓ RPM" : @"45 RPM", MRGVinylOnLeft() ? @"Left" : @"Right"];
    return nil;
}

static BOOL addonHasSettings(NSDictionary *a) {
    id<MRGAddon> addon = MRGAddonObject(a[@"id"]);
    BOOL page = [addon respondsToSelector:@selector(addonSettingsController)];
    return MRGAddonInstalled(a[@"id"]) && ([addon addonSettings].count > 0 || page);
}

@interface MRGAddonShop : UITableViewController
@end

@implementation MRGAddonShop {
    UILabel *_titleLabel, *_subLabel, *_kickerLabel;
    NSArray<NSDictionary *> *_addons;
    NSString *_note;
    BOOL _changing, _reloadQueued;
    CFTimeInterval _ownChangeAt;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Add-on Shop";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.estimatedRowHeight = 420;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.sectionHeaderTopPadding = 6;
    // Room for Spotify's mini player and tab bar, so the last card's switch is never under them.
    UIEdgeInsets inset = self.tableView.contentInset; inset.bottom = 190; self.tableView.contentInset = inset;
    UIEdgeInsets bar = self.tableView.verticalScrollIndicatorInsets; bar.bottom = 190; self.tableView.verticalScrollIndicatorInsets = bar;
    self.tableView.tableHeaderView = [self header];
    self.refreshControl = [UIRefreshControl new];
    self.refreshControl.tintColor = MRGAccent();
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    _addons = MRGAddonIndex();
    [self reload];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(externalChange) name:MRGSettingsChangedNotification object:nil];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

// Another page (or an add-on itself) changed something: one reload on the next turn, never in the middle of a switch.
- (void)externalChange {
    if (_changing || _reloadQueued) return;
    _reloadQueued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_reloadQueued = NO;
        // The change notification arrives a moment after a switch here (it is coalesced): that one is our own, and the
        // rows were already updated in place, so the table isn't reloaded under the switch's animation.
        if (self->_changing || CACurrentMediaTime() - self->_ownChangeAt < 0.6) return;
        self->_addons = MRGAddonIndex();
        [self updateCount];
        [self.tableView reloadData];
    });
}

- (UIView *)header {
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 100)];
    _titleLabel = [UILabel new];
    _kickerLabel = [UILabel new];
    _kickerLabel.text = @"ADD-ON SHOP";
    _kickerLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightHeavy];
    _kickerLabel.textColor = MRGAccent();
    [h addSubview:_kickerLabel];
    _titleLabel.text = @"Make Spotify yours";
    _titleLabel.font = [UIFont systemFontOfSize:30 weight:UIFontWeightHeavy];
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.7;
    _subLabel = [UILabel new];
    _subLabel.numberOfLines = 0;
    _subLabel.font = [UIFont systemFontOfSize:14];
    _subLabel.textColor = [UIColor colorWithWhite:0.68 alpha:1];
    [h addSubview:_titleLabel];
    [h addSubview:_subLabel];
    [self updateCount];
    return h;
}

- (void)updateCount {
    NSUInteger on = 0, all = 0;
    for (NSDictionary *a in _addons) { if (MRGAddonBuiltIn(a[@"id"])) all++; if (MRGAddonInstalled(a[@"id"])) on++; }
    _subLabel.text = [NSString stringWithFormat:@"%lu of %lu add-ons on. A switch works right away and is saved automatically; you can also switch add-ons from the main Mirage page. Everything is built into Mirage, nothing is downloaded and run.", (unsigned long)on, (unsigned long)all];
    [self.view setNeedsLayout];
}

// The header is sized to the table's width every layout, so its text wraps instead of running off the right edge.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *h = self.tableView.tableHeaderView;
    if (!h || !_subLabel) return;
    CGFloat w = self.tableView.bounds.size.width;
    UIEdgeInsets safe = self.tableView.safeAreaInsets;
    CGFloat x = 20 + safe.left, tw = MAX(100, w - x - 20 - safe.right);
    _kickerLabel.frame = CGRectMake(x, 8, tw, 16);
    _kickerLabel.textColor = MRGAccent();
    _titleLabel.frame = CGRectMake(x, 26, tw, 36);
    CGFloat sh = ceil([_subLabel sizeThatFits:CGSizeMake(tw, CGFLOAT_MAX)].height);
    _subLabel.frame = CGRectMake(x, 66, tw, sh);
    CGRect f = CGRectMake(0, 0, w, 66 + sh + 12);
    if (!CGRectEqualToRect(h.frame, f)) { h.frame = f; self.tableView.tableHeaderView = h; }
}

- (void)reload {
    MRGAddonRefresh(^(NSArray<NSDictionary *> *addons, NSString *error) {
        self->_addons = addons;
        self->_note = error;
        [self.refreshControl endRefreshing];
        [self updateCount];
        [self.tableView reloadData];
    });
}

- (NSInteger)leadingSections { return MRGShopHeaderRows() > 0 ? 1 : 0; }
- (NSDictionary *)addonInSection:(NSInteger)s {
    NSInteger i = s - [self leadingSections];
    return (i >= 0 && i < (NSInteger)self->_addons.count) ? self->_addons[i] : nil;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t {
    return [self leadingSections] + MAX((NSInteger)_addons.count, 1);
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    return MRGSafeCount(^NSInteger {
        if (s < [self leadingSections]) return MRGShopHeaderRows();
        NSDictionary *a = [self addonInSection:s];
        if (!a) return 0;
        // The card (with its one switch), and a Settings row while it's on and has settings.
        return 1 + (addonHasSettings(a) ? 1 : 0);
    });
}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    if (s < [self leadingSections]) return MRGShopHeaderTitle();
    if (s == [self leadingSections]) return @"Add-ons";
    return nil;
}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    if (s < [self leadingSections]) return MRGShopHeaderFooter();
    NSDictionary *a = [self addonInSection:s];
    if (a) {
        NSString *notice = MRGAddonCrashNotice(a[@"id"]);
        if (notice.length) return notice;
    }
    NSInteger last = [self leadingSections] + (NSInteger)self->_addons.count - 1;
    return s == last || !self->_addons.count ? (self->_note ?: @"Pull down to check for new add-ons.") : nil;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    return MRGSafeCell(ip, ^UITableViewCell *{
        if (ip.section < [self leadingSections]) return MRGShopHeaderCell(t, ip.row);
        NSDictionary *a = [self addonInSection:ip.section];
        if (ip.row == 1) {
            UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
            c.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.94];
            c.textLabel.text = @"Settings";
            c.textLabel.textColor = UIColor.whiteColor;
            c.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
            c.imageView.image = [UIImage systemImageNamed:@"slider.horizontal.3"];
            c.imageView.tintColor = MRGAccent();
            c.detailTextLabel.text = addonSummary(a);
            c.detailTextLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        MRGAddonCard *card = [[MRGAddonCard alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        card.addon = a;
        NSString *addonID = a[@"id"];
        __weak typeof(self) weak = self;
        __weak MRGAddonCard *weakCard = card;
        card.onToggle = ^(BOOL on) { [weak setAddon:addonID on:on card:weakCard]; };
        return card;
    });
}

- (void)setAddon:(NSString *)addonID on:(BOOL)on card:(MRGAddonCard *)card {
    if (!addonID.length) return;
    _changing = YES;
    _ownChangeAt = CACurrentMediaTime();
    @try { MRGAddonSetInstalled(addonID, on); } @catch (NSException *e) { MRGDJLog(@"addons: switching %@ threw %@", addonID, e.reason); }
    _changing = NO;
    [card refreshState];
    [self updateCount];
    NSInteger section = NSNotFound;
    for (NSInteger i = 0; i < (NSInteger)_addons.count; i++) if ([_addons[i][@"id"] isEqualToString:addonID]) section = i + [self leadingSections];
    if (section == NSNotFound || section >= self.tableView.numberOfSections) { [self.tableView reloadData]; return; }
    // Only the Settings row comes and goes; the card stays, so the switch finishes its own animation.
    NSInteger have = [self.tableView numberOfRowsInSection:section];
    NSInteger want = [self tableView:self.tableView numberOfRowsInSection:section];
    NSArray *settings = @[[NSIndexPath indexPathForRow:1 inSection:section]];
    @try {
        [self.tableView performBatchUpdates:^{
            if (want > have) [self.tableView insertRowsAtIndexPaths:settings withRowAnimation:UITableViewRowAnimationFade];
            else if (want < have) [self.tableView deleteRowsAtIndexPaths:settings withRowAnimation:UITableViewRowAnimationFade];
            if (want == have && want > 1) [self.tableView reloadRowsAtIndexPaths:settings withRowAnimation:UITableViewRowAnimationNone];
        } completion:^(BOOL finished) {
            [UIView performWithoutAnimation:^{ [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:section] withRowAnimation:UITableViewRowAnimationNone]; }];
        }];
    } @catch (NSException *e) {
        [self.tableView reloadData];
    }
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section < [self leadingSections]) { MRGShopHeaderSelect(self, ip.row); return; }
    if (ip.row == 1) {
        UIViewController *page = MRGAddonSettingsFor([self addonInSection:ip.section][@"id"]);   // nil once it's off
        if (page) MRGPushPage(self, page);
    }
}

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; _addons = MRGAddonIndex(); [self updateCount]; [self.tableView reloadData]; }
@end

UIViewController *MRGAddonShopPage(void) { return [MRGAddonShop new]; }

NSString *MRGAddonRowSummary(NSString *addonID) { return addonID.length ? addonSummary(@{@"id": addonID}) : nil; }
// Settings exist only for an add-on that is installed (on): nothing of an add-on that isn't shows anywhere.
BOOL MRGAddonHasSettings(NSString *addonID) {
    id<MRGAddon> addon = MRGAddonObject(addonID);
    return addon && MRGAddonInstalled(addonID) && ([addon addonSettings].count > 0 || [addon respondsToSelector:@selector(addonSettingsController)]);
}
UIViewController *MRGAddonSettingsFor(NSString *addonID) {
    id<MRGAddon> addon = MRGAddonObject(addonID);
    if (!addon || !MRGAddonInstalled(addonID)) return nil;
    UIViewController *page = nil;
    @try { page = [addon respondsToSelector:@selector(addonSettingsController)] ? [addon addonSettingsController] : nil; } @catch (NSException *e) {}
    // A page of the add-on's own gets the battery line too, when it has no header of its own.
    if ([page isKindOfClass:UITableViewController.class]) {
        UITableViewController *tvc = (UITableViewController *)page;
        if (!tvc.tableView.tableHeaderView) tvc.tableView.tableHeaderView = MRGAddonBatteryHeader(addonID, UIScreen.mainScreen.bounds.size.width);
    }
    return page ?: MRGAddonSettingsPage(addon.addonID);
}
