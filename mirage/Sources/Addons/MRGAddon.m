#import "Addons/MRGAddon.h"
#import "MRGAddons.h"
#import "MRGPrefs.h"
#import "MRGSafe.h"
#import "MRGDJLog.h"
#import "MRGDiagnostics.h"

static NSMutableArray<id<MRGAddon>> *sAddons;
static NSString *sHeaderTitle;
static NSInteger sHeaderRows;
static UITableViewCell *(^sHeaderCell)(UITableView *, NSInteger);
static void (^sHeaderSelect)(UIViewController *, NSInteger);
static NSString *(^sHeaderFooter)(void);

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }

UIColor *MRGColorFromRGB(NSInteger rgb) {
    // colorWithCGColor, not colorWithRed: Vitrine and the theme hook both sit on colorWithRed, and a color
    // built here must be the exact RGB we asked for.
    rgb &= 0xFFFFFF;
    CGFloat c[4] = {((rgb >> 16) & 0xFF) / 255.0, ((rgb >> 8) & 0xFF) / 255.0, (rgb & 0xFF) / 255.0, 1};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGColorRef cg = CGColorCreate(space, c);
    UIColor *color = [UIColor colorWithCGColor:cg];
    CGColorRelease(cg);
    CGColorSpaceRelease(space);
    return color;
}

NSInteger MRGRGBFromColor(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat w = 0;
        if (![color getWhite:&w alpha:&a]) return 0x1ED760;
        r = g = b = w;
    }
    return ((NSInteger)lround(r * 255) << 16) | ((NSInteger)lround(g * 255) << 8) | (NSInteger)lround(b * 255);
}

#pragma mark - settings schema

@implementation MRGAddonSetting
+ (instancetype)toggle:(NSString *)key title:(NSString *)title fallback:(BOOL)on {
    MRGAddonSetting *s = [self new];
    s.key = key; s.title = title; s.control = MRGAddonControlToggle; s.fallback = @(on);
    return s;
}
+ (instancetype)slider:(NSString *)key title:(NSString *)title min:(double)min max:(double)max fallback:(double)v {
    MRGAddonSetting *s = [self new];
    s.key = key; s.title = title; s.control = MRGAddonControlSlider; s.minimum = min; s.maximum = max; s.fallback = @(v);
    return s;
}
+ (instancetype)picker:(NSString *)key title:(NSString *)title options:(NSArray<NSString *> *)options values:(NSArray *)values fallback:(id)fallback {
    MRGAddonSetting *s = [self new];
    s.key = key; s.title = title; s.control = MRGAddonControlPicker; s.options = options; s.values = values; s.fallback = fallback;
    return s;
}
+ (instancetype)color:(NSString *)key title:(NSString *)title fallbackRGB:(NSInteger)rgb {
    MRGAddonSetting *s = [self new];
    s.key = key; s.title = title; s.control = MRGAddonControlColor; s.fallback = @(rgb);
    return s;
}
@end

NSString *MRGAddonSettingKey(NSString *addonID, NSString *key) {
    if ([key hasPrefix:@"mirage."]) return key;
    return [NSString stringWithFormat:@"mirage.addon.%@.%@", addonID ?: @"", key ?: @""];
}

id MRGAddonValue(NSString *addonID, MRGAddonSetting *setting) {
    if (!setting) return nil;
    id stored = [D() objectForKey:MRGAddonSettingKey(addonID, setting.key)];
    if ([stored isKindOfClass:NSNumber.class] || [stored isKindOfClass:NSString.class]) return stored;
    return setting.fallback;
}

void MRGAddonSetValue(NSString *addonID, MRGAddonSetting *setting, id value) {
    if (!setting) return;
    NSString *key = MRGAddonSettingKey(addonID, setting.key);
    if ([value isKindOfClass:NSNumber.class] && setting.control == MRGAddonControlToggle) [D() setBool:[value boolValue] forKey:key];
    else if (value) [D() setObject:value forKey:key];
    else [D() removeObjectForKey:key];
    MRGPostChange();
}

BOOL MRGAddonFlag(NSString *addonID, NSString *key, BOOL fallback) {
    id v = [D() objectForKey:MRGAddonSettingKey(addonID, key)];
    return [v isKindOfClass:NSNumber.class] ? [v boolValue] : fallback;
}
void MRGAddonSetFlag(NSString *addonID, NSString *key, BOOL on) {
    [D() setBool:on forKey:MRGAddonSettingKey(addonID, key)];
    MRGPostChange();
}
double MRGAddonNumber(NSString *addonID, NSString *key, double fallback) {
    id v = [D() objectForKey:MRGAddonSettingKey(addonID, key)];
    return [v isKindOfClass:NSNumber.class] ? [v doubleValue] : fallback;
}
void MRGAddonSetNumber(NSString *addonID, NSString *key, double value) {
    [D() setDouble:value forKey:MRGAddonSettingKey(addonID, key)];
    MRGPostChange();
}
NSInteger MRGAddonInteger(NSString *addonID, NSString *key, NSInteger fallback) {
    id v = [D() objectForKey:MRGAddonSettingKey(addonID, key)];
    return [v isKindOfClass:NSNumber.class] ? [v integerValue] : fallback;
}
void MRGAddonSetInteger(NSString *addonID, NSString *key, NSInteger value) {
    [D() setInteger:value forKey:MRGAddonSettingKey(addonID, key)];
    MRGPostChange();
}

#pragma mark - registry and crash guard

static NSString *noticeKey(NSString *addonID) { return [NSString stringWithFormat:@"mirage.addon.%@.notice", addonID]; }
static NSString *launchKey(NSString *addonID) { return [NSString stringWithFormat:@"mirage.addon.%@.launching", addonID]; }

void MRGAddonRegister(id<MRGAddon> addon) {
    if (!addon.addonID.length) return;
    if (!sAddons) sAddons = [NSMutableArray array];
    for (id<MRGAddon> have in sAddons) if ([have.addonID isEqualToString:addon.addonID]) return;
    [sAddons addObject:addon];
}

NSArray<id<MRGAddon>> *MRGRegisteredAddons(void) { return sAddons ?: @[]; }

id<MRGAddon> MRGAddonObject(NSString *addonID) {
    for (id<MRGAddon> a in sAddons) if ([a.addonID isEqualToString:addonID]) return a;
    return nil;
}

NSString *MRGAddonCrashNotice(NSString *addonID) {
    NSString *s = [D() stringForKey:noticeKey(addonID)];
    return s.length ? s : nil;
}
void MRGAddonClearCrashNotice(NSString *addonID) { [D() removeObjectForKey:noticeKey(addonID)]; }

static void failAddon(id<MRGAddon> addon, NSString *reason) {
    NSString *text = reason.length ? reason : @"This add-on was turned off because it crashed the last time Spotify opened.";
    [D() setBool:NO forKey:[@"mirage.addon." stringByAppendingString:addon.addonID]];
    [D() setObject:text forKey:noticeKey(addon.addonID)];
    [D() removeObjectForKey:launchKey(addon.addonID)];
    MRGDJLog(@"addons: %@ turned off (%@)", addon.addonID, text);
    @try { [addon addonDidDisable]; } @catch (NSException *e) {}
    MRGPostChange();
}

// Called from the shop's switch as well as from launch, so a throw while turning an add-on on
// disables it instead of taking Spotify down.
void MRGAddonRunEnable(NSString *addonID) {
    id<MRGAddon> addon = MRGAddonObject(addonID);
    if (!addon) return;
    @try { [addon addonDidEnable]; }
    @catch (NSException *e) {
        failAddon(addon, [NSString stringWithFormat:@"Turned off because it failed to start (%@).", e.reason ?: e.name]);
    }
}

void MRGAddonRunDisable(NSString *addonID) {
    id<MRGAddon> addon = MRGAddonObject(addonID);
    if (!addon) return;
    @try { [addon addonDidDisable]; }
    @catch (NSException *e) { MRGDJLog(@"addons: %@ disable threw %@", addonID, e.reason); }
}

// Each add-on's flag is up only while its own enable hook runs, so a crash inside one start-up blames that add-on
// and nobody else. Before, every installed add-on stayed flagged for the first 12 seconds and any crash in that
// window (Spotify's own included) turned them all off with a crash notice. Crashes after start-up are handled by
// safe mode (MRGDiagnostics.m): two launches in a row that die early start the next one with add-ons off.
static void launchAddons(void) {
    for (id<MRGAddon> addon in MRGRegisteredAddons()) {
        NSString *flag = launchKey(addon.addonID);
        if (!MRGAddonInstalled(addon.addonID)) { if ([D() objectForKey:flag]) [D() removeObjectForKey:flag]; continue; }
        if ([D() boolForKey:flag]) {
            MRGCrumb(@"%@ crashed while starting last time, turned off", addon.addonID);
            failAddon(addon, @"This add-on crashed while starting the last time Spotify opened, so it was turned off. Turn it back on to try again.");
            continue;
        }
        [D() setBool:YES forKey:flag];
        MRGCrumb(@"enable %@", addon.addonID);
        MRGAddonRunEnable(addon.addonID);
        [D() removeObjectForKey:flag];
    }
}

BOOL MRGEffectsPaused(void) {
    if (NSProcessInfo.processInfo.isLowPowerModeEnabled) return YES;
    return UIApplication.sharedApplication.applicationState != UIApplicationStateActive;
}

#pragma mark - shop header

void MRGSetShopHeader(NSString *title, NSInteger rows, UITableViewCell *(^cell)(UITableView *, NSInteger), void (^select)(UIViewController *, NSInteger), NSString *(^footer)(void)) {
    sHeaderTitle = [title copy];
    sHeaderRows = MAX(0, rows);
    sHeaderCell = [cell copy];
    sHeaderSelect = [select copy];
    sHeaderFooter = [footer copy];
}
NSString *MRGShopHeaderTitle(void) { return sHeaderRows > 0 ? sHeaderTitle : nil; }
NSInteger MRGShopHeaderRows(void) { return sHeaderRows; }
UITableViewCell *MRGShopHeaderCell(UITableView *table, NSInteger row) {
    return sHeaderCell ? sHeaderCell(table, row) : [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
}
void MRGShopHeaderSelect(UIViewController *shop, NSInteger row) { if (sHeaderSelect) sHeaderSelect(shop, row); }
NSString *MRGShopHeaderFooter(void) { return sHeaderFooter ? sHeaderFooter() : nil; }

#pragma mark - the schema page

static NSInteger pickerIndex(MRGAddonSetting *setting, id value) {
    NSArray *values = setting.values;
    for (NSUInteger i = 0; i < values.count; i++) {
        id v = values[i];
        if ([v isKindOfClass:NSNumber.class] && [value isKindOfClass:NSNumber.class]) {
            if (fabs([v doubleValue] - [value doubleValue]) < 0.05) return (NSInteger)i;
        } else if ([v isEqual:value]) return (NSInteger)i;
    }
    return 0;
}

@interface MRGAddonSettingsController : UITableViewController
@property (nonatomic, copy) NSString *addonID;
@end

@implementation MRGAddonSettingsController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    id<MRGAddon> addon = MRGAddonObject(self.addonID);
    self.title = addon.addonName ?: @"Add-on";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.tableView.backgroundColor = UIColor.blackColor;
    UIEdgeInsets inset = self.tableView.contentInset; inset.bottom = 150; self.tableView.contentInset = inset;
    self.tableView.tableHeaderView = MRGAddonBatteryHeader(self.addonID, self.view.bounds.size.width);
}
- (NSArray<MRGAddonSetting *> *)settings { return [MRGAddonObject(self.addonID) addonSettings] ?: @[]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return MAX((NSInteger)self.settings.count, 1); }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return self.settings.count ? 1 : 0; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    return s < (NSInteger)self.settings.count ? self.settings[s].title : nil;
}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    if (!self.settings.count) return @"No settings.";
    return self.settings[s].footer;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    return MRGSafeCell(ip, ^UITableViewCell *{
        MRGAddonSetting *setting = self.settings[ip.section];
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        c.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.9];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        c.textLabel.textColor = UIColor.whiteColor;
        id value = MRGAddonValue(self.addonID, setting);
        if (setting.control == MRGAddonControlToggle) {
            c.textLabel.text = setting.title;
            UISwitch *sw = [UISwitch new];
            sw.on = [value boolValue];
            sw.tag = ip.section;
            sw.onTintColor = MRGAccent();
            [sw addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
            return c;
        }
        if (setting.control == MRGAddonControlSlider) {
            UILabel *label = [UILabel new];
            label.text = setting.title;
            label.textColor = UIColor.whiteColor;
            label.font = [UIFont systemFontOfSize:15];
            UISlider *slider = [UISlider new];
            slider.minimumValue = setting.minimum;
            slider.maximumValue = setting.maximum;
            slider.value = MIN(setting.maximum, MAX(setting.minimum, [value doubleValue]));
            slider.tag = ip.section;
            slider.continuous = setting.live;
            slider.minimumTrackTintColor = MRGAccent();
            [slider addTarget:self action:@selector(slid:) forControlEvents:UIControlEventValueChanged];
            UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, slider]];
            stack.axis = UILayoutConstraintAxisVertical;
            stack.spacing = 4;
            stack.translatesAutoresizingMaskIntoConstraints = NO;
            [c.contentView addSubview:stack];
            [NSLayoutConstraint activateConstraints:@[
                [stack.leadingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.leadingAnchor],
                [stack.trailingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.trailingAnchor],
                [stack.topAnchor constraintEqualToAnchor:c.contentView.topAnchor constant:8],
                [stack.bottomAnchor constraintEqualToAnchor:c.contentView.bottomAnchor constant:-8],
            ]];
            return c;
        }
        if (setting.control == MRGAddonControlColor) {
            c.textLabel.text = setting.title;
            NSInteger rgb = [value integerValue];
            c.detailTextLabel.text = [NSString stringWithFormat:@"#%06lX", (long)(rgb & 0xFFFFFF)];
            c.detailTextLabel.textColor = UIColor.grayColor;
            UIView *swatch = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 28, 28)];
            swatch.backgroundColor = MRGColorFromRGB(rgb);
            swatch.layer.cornerRadius = 14;
            swatch.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;
            swatch.layer.borderWidth = 1;
            c.accessoryView = swatch;
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
            return c;
        }
        NSArray *items = setting.options.count ? setting.options : @[@"—"];
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:items];
        seg.selectedSegmentIndex = pickerIndex(setting, value);
        seg.selectedSegmentTintColor = MRGAccent();
        [seg setTitleTextAttributes:@{NSForegroundColorAttributeName: MRGOnAccent()} forState:UIControlStateSelected];
        seg.tag = ip.section;
        seg.apportionsSegmentWidthsByContent = YES;
        [seg addTarget:self action:@selector(picked:) forControlEvents:UIControlEventValueChanged];
        seg.translatesAutoresizingMaskIntoConstraints = NO;
        [c.contentView addSubview:seg];
        [NSLayoutConstraint activateConstraints:@[
            [seg.leadingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.leadingAnchor],
            [seg.trailingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.trailingAnchor],
            [seg.topAnchor constraintEqualToAnchor:c.contentView.topAnchor constant:10],
            [seg.bottomAnchor constraintEqualToAnchor:c.contentView.bottomAnchor constant:-10],
        ]];
        return c;
    });
}
- (CGFloat)tableView:(UITableView *)t heightForRowAtIndexPath:(NSIndexPath *)ip {
    MRGAddonSetting *s = self.settings[ip.section];
    return s.control == MRGAddonControlSlider || s.control == MRGAddonControlPicker ? 64 : 48;
}
- (void)toggled:(UISwitch *)sw { MRGAddonSetValue(self.addonID, self.settings[sw.tag], @(sw.on)); }
- (void)slid:(UISlider *)slider { MRGAddonSetValue(self.addonID, self.settings[slider.tag], @(slider.value)); }
- (void)picked:(UISegmentedControl *)seg {
    MRGAddonSetting *s = self.settings[seg.tag];
    id value = seg.selectedSegmentIndex < (NSInteger)s.values.count ? s.values[seg.selectedSegmentIndex] : s.fallback;
    MRGAddonSetValue(self.addonID, s, value);
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    MRGAddonSetting *s = self.settings[ip.section];
    if (s.control != MRGAddonControlColor) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:s.title message:@"A color as #RRGGBB." preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = [NSString stringWithFormat:@"#%06lX", (long)([MRGAddonValue(self.addonID, s) integerValue] & 0xFFFFFF)];
        f.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *text = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([text hasPrefix:@"#"]) text = [text substringFromIndex:1];
        NSScanner *scanner = [NSScanner scannerWithString:text];
        unsigned int rgb = 0;
        if (text.length != 6 || ![scanner scanHexInt:&rgb] || !scanner.isAtEnd) return;
        MRGAddonSetValue(self.addonID, s, @(rgb));
        [self.tableView reloadData];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

NSAttributedString *MRGAddonBatteryLine(NSString *addonID, UIFont *font) {
    id<MRGAddon> addon = MRGAddonObject(addonID);
    if (![addon respondsToSelector:@selector(addonBatteryNote)]) return nil;
    NSString *note = nil;
    NSInteger level = 0;
    @try {
        note = [addon addonBatteryNote];
        if ([addon respondsToSelector:@selector(addonBatteryImpact)]) level = [addon addonBatteryImpact];
    } @catch (NSException *e) { return nil; }
    if (!note.length) return nil;
    UIColor *color = level >= 2 ? UIColor.systemOrangeColor : level == 1 ? UIColor.systemYellowColor : [UIColor colorWithWhite:0.6 alpha:1];
    NSString *symbol = level >= 2 ? @"battery.25percent" : level == 1 ? @"battery.50percent" : @"battery.100percent";
    UIImage *icon = [[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithFont:font]] imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    if (icon) {
        NSTextAttachment *att = [NSTextAttachment new];
        att.image = icon;
        [out appendAttributedString:[NSAttributedString attributedStringWithAttachment:att]];
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"  " attributes:@{NSFontAttributeName: font}]];
    }
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:[@"Battery · " stringByAppendingString:note]
                                                                attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color}]];
    return out;
}

UIView *MRGAddonBatteryHeader(NSString *addonID, CGFloat width) {
    NSAttributedString *line = MRGAddonBatteryLine(addonID, [UIFont systemFontOfSize:13 weight:UIFontWeightMedium]);
    if (!line) return nil;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, MAX(200, width), 44)];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectInset(box.bounds, 20, 8)];
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    l.attributedText = line;
    l.numberOfLines = 2;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.85;
    [box addSubview:l];
    return box;
}

UIViewController *MRGAddonSettingsPage(NSString *addonID) {
    MRGAddonSettingsController *page = [MRGAddonSettingsController new];
    page.addonID = addonID;
    return page;
}

// The add-ons start once Spotify has drawn its first frame (a moment after it finishes launching), not on the main
// queue's first turn: their enable hooks walk windows, read caches and start lookups, and none of that should stand
// between the launch and the first frame. Safe mode (MRGDiagnostics.m) skips them all.
static void startAddonsOnce(void) {
    static BOOL started;
    if (started) return;
    started = YES;
    @try {
        if (MRGSafeModeActive()) { MRGSafeModeTurnOffAddons(); return; }
        launchAddons();
    } @catch (NSException *e) { MRGCrumb(@"launch add-ons threw %@", e.reason); }
}

__attribute__((constructor)) static void mrgAddonConstructor(void) {
    __block id token = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        if (token) [NSNotificationCenter.defaultCenter removeObserver:token];
        token = nil;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ startAddonsOnce(); });
    }];
    // Loaded after launch had already finished (no notification coming): start shortly anyway.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ startAddonsOnce(); });
}
