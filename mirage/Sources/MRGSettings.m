#import "MRGSafe.h"
#import "MRGSettings.h"
#import "MRGPrefs.h"
#import "MRGImporter.h"
#import "MRGBackgroundView.h"
#import "MRGAI.h"
#import "MRGDJ.h"
#import "MRGDJView.h"
#import "MRGDJLog.h"
#import "MRGDJPages.h"
#import "MRGVoice.h"
#import "MRGKeychain.h"
#import "MRGChatView.h"
#import "MRGAddons.h"
#import "Addons/MRGSaver.h"
#import "Addons/MRGAddonArt.h"
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

// Spotify's navigation controller asserts that every controller pushed on it conforms to
// SPTPageController (Vitrine, tweak/Sources/Settings/SGPage.m); the page answers its two questions
// and is registered as conforming at launch, or presented when the protocol is missing.
static BOOL sg_pageConforms;

typedef NS_ENUM(NSInteger, MRGSection) { MRGSecAddons, MRGSecBackgrounds, MRGSecDJ, MRGSecShop, MRGSecSaver, MRGSecAbout, MRGSecCount };

// The built-in add-ons in the shop's order: the rows of the main page's Add-ons section.
static NSArray<NSDictionary *> *mainAddons(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *a in MRGAddonIndex()) if ([a[@"id"] isKindOfClass:NSString.class] && MRGAddonBuiltIn(a[@"id"])) [out addObject:a];
    return out;
}

// One add-on on the main page: its icon, name and state, a switch, and a chevron into its settings.
@interface MRGAddonRowCell : UITableViewCell
@property (nonatomic, copy) NSString *addonID;
@property (nonatomic, copy) void (^onToggle)(BOOL on);
@property (nonatomic, readonly) UISwitch *toggle;
- (void)fill:(NSDictionary *)addon;
@end

@implementation MRGAddonRowCell {
    UIImageView *_icon, *_chevron;
    UILabel *_name, *_detail;
    UISwitch *_toggle;
}
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    if (!(self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid])) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.78];
    UIView *sel = [UIView new];
    sel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    self.selectedBackgroundView = sel;
    _icon = [UIImageView new];
    _icon.layer.shadowColor = UIColor.blackColor.CGColor;
    _icon.layer.shadowOpacity = 0.3;
    _icon.layer.shadowRadius = 4;
    _icon.layer.shadowOffset = CGSizeMake(0, 2);
    _name = [UILabel new];
    _name.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _name.textColor = UIColor.whiteColor;
    _detail = [UILabel new];
    _detail.font = [UIFont systemFontOfSize:13];
    _detail.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    _toggle = [UISwitch new];
    [_toggle addTarget:self action:@selector(flipped) forControlEvents:UIControlEventValueChanged];
    _chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]]];
    _chevron.tintColor = [UIColor colorWithWhite:1 alpha:0.35];
    _chevron.contentMode = UIViewContentModeCenter;
    for (UIView *v in @[_icon, _name, _detail, _toggle, _chevron]) [self.contentView addSubview:v];
    return self;
}
- (UISwitch *)toggle { return _toggle; }
- (void)fill:(NSDictionary *)a {
    self.addonID = a[@"id"];
    BOOL on = MRGAddonInstalled(self.addonID);
    _icon.image = MRGAddonIcon(self.addonID, 36);
    _icon.alpha = on ? 1 : 0.55;
    _name.text = a[@"name"];
    NSString *summary = on ? MRGAddonRowSummary(self.addonID) : nil;
    NSString *category = [a[@"type"] isKindOfClass:NSString.class] ? a[@"type"] : nil;
    _detail.text = on ? (summary.length ? summary : (category.length ? [category stringByAppendingString:@" · On"] : @"On")) : (category.length ? [category stringByAppendingString:@" · Off"] : @"Off");
    _detail.textColor = on ? [MRGAccent() colorWithAlphaComponent:0.95] : [UIColor colorWithWhite:1 alpha:0.45];
    _toggle.on = on;
    _toggle.onTintColor = MRGAccent();
    BOOL settings = MRGAddonHasSettings(self.addonID);
    _chevron.hidden = !settings;
    self.selectionStyle = settings ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    self.accessibilityLabel = _name.text;
    self.accessibilityValue = _detail.text;
    self.accessibilityHint = settings ? @"Opens its settings" : nil;
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat side = 36, x = 16;
    _icon.frame = CGRectMake(x, (b.size.height - side) / 2, side, side);
    CGFloat right = b.size.width - 12;
    _chevron.frame = CGRectMake(right - 14, (b.size.height - 20) / 2, 14, 20);
    if (!_chevron.hidden) right -= 14 + 10;
    CGSize sw = _toggle.intrinsicContentSize;
    _toggle.frame = CGRectMake(right - sw.width, (b.size.height - sw.height) / 2, sw.width, sw.height);
    CGFloat tx = CGRectGetMaxX(_icon.frame) + 14, tw = MAX(0, CGRectGetMinX(_toggle.frame) - 10 - tx);
    _name.frame = CGRectMake(tx, b.size.height / 2 - 20, tw, 21);
    _detail.frame = CGRectMake(tx, b.size.height / 2 + 2, tw, 18);
}
- (void)flipped {
    [[UISelectionFeedbackGenerator new] selectionChanged];
    if (self.onToggle) self.onToggle(_toggle.on);
}
@end
typedef NS_ENUM(NSInteger, MRGBgSection) { MRGBgPreview, MRGBgMedia, MRGBgLibrary, MRGBgLook, MRGBgScreens, MRGBgAssign, MRGBgCount };

@interface MRGSettingsController : UITableViewController <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic) BOOL djOnly;   // the AI DJ page: every DJ setting, in its own groups (like Vitrine's tabs)
@property (nonatomic) BOOL bgOnly;   // the Backgrounds page, the same way
@end

// The AI DJ page's groups, as rows of the old DJ section (djCell: row numbers; 12 is Talk like me).
static NSArray<NSArray<NSNumber *> *> *djGroups(void) {
    return @[@[@0, @1, @2, @13], @[@3, @4, @12], @[@6], @[@7, @8, @9], @[@10, @5, @11]];
}
static NSArray<NSString *> *djGroupTitles(void) { return @[@"AI provider", @"Voice & personality", @"Your listening", @"On screen", @"Mirage DJ"]; }

@implementation MRGSettingsController {
    UIActivityIndicatorView *_spinner;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (NSString *)spt_pageIdentifier { return self.djOnly ? @"mirage-dj" : self.bgOnly ? @"mirage-backgrounds" : @"mirage"; }
- (NSURL *)spt_pageURI { return [NSURL URLWithString:self.djOnly ? @"spotify:internal:mirage-dj" : self.bgOnly ? @"spotify:internal:mirage-backgrounds" : @"spotify:internal:mirage"]; }

// The DJ row for an index path of the AI DJ page, or -1.
- (NSInteger)djRowAt:(NSIndexPath *)ip {
    NSArray *g = djGroups();
    if (ip.section < 0 || ip.section >= (NSInteger)g.count || ip.row < 0 || ip.row >= (NSInteger)[g[ip.section] count]) return -1;
    return [g[ip.section][ip.row] integerValue];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.djOnly ? @"AI DJ" : self.bgOnly ? @"Backgrounds" : @"Mirage";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.tableView.backgroundColor = UIColor.blackColor;
    // The page draws its own background, laid out for the whole window (not the table's frame, which
    // stops short of the tab bar), so it lines up with the screens around it; Mirage's page hooks
    // leave this table alone.
    self.tableView.accessibilityIdentifier = @"mirage.settings";
    self.tableView.backgroundView = [[MRGBackgroundView alloc] initWithFrame:self.tableView.bounds];
    self.tableView.separatorColor = [UIColor colorWithWhite:1 alpha:0.1];
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.hidesWhenStopped = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:_spinner];
    if (self.navigationController.viewControllers.firstObject == self && self.presentingViewController)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
}

// Pushed on Spotify's stack the page runs under the tab bar and the mini player, which Spotify does not
// report as safe area to a page of ours; the last rows are kept clear of both.
static const CGFloat kBottomChrome = 150;

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.djOnly && !self.bgOnly && fabs(self.tableView.tableHeaderView.bounds.size.width - self.tableView.bounds.size.width) > 0.5) [self updateHero];
    BOOL modal = self.navigationController.viewControllers.firstObject == self && self.presentingViewController;
    CGFloat bottom = modal ? 0 : MAX(0, kBottomChrome - self.view.safeAreaInsets.bottom);
    UITableView *t = self.tableView;
    if (t.contentInset.bottom != bottom) {
        UIEdgeInsets inset = t.contentInset; inset.bottom = bottom; t.contentInset = inset;
        UIEdgeInsets bar = t.verticalScrollIndicatorInsets; bar.bottom = bottom; t.verticalScrollIndicatorInsets = bar;
    }
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t {
    if (self.djOnly) return djGroups().count;
    if (self.bgOnly) return MRGBgCount;
    return MRGSecCount;
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    return MRGSafeCount(^NSInteger { return [self mrg_rowsIn:t section:s]; });
}

- (NSInteger)mrg_rowsIn:(UITableView *)t section:(NSInteger)s {
    if (self.djOnly) return s < (NSInteger)djGroups().count ? [djGroups()[s] count] : 0;
    if (self.bgOnly) {
        switch (s) {
            case MRGBgPreview: return 2;
            case MRGBgMedia: return 3;
            case MRGBgLibrary: return MAX((NSInteger)MRGBackgroundLibrary().count, 1);
            case MRGBgLook: return 6;
            case MRGBgScreens: return 5;
            case MRGBgAssign: return 4;
        }
        return 0;
    }
    switch (s) {
        case MRGSecAddons: return (NSInteger)mainAddons().count;
        case MRGSecBackgrounds: return 1;
        case MRGSecShop: return 1;
        case MRGSecDJ: return 1;
        case MRGSecSaver: return 1;
        case MRGSecAbout: return 2;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    if (self.djOnly) return s < (NSInteger)djGroupTitles().count ? djGroupTitles()[s] : nil;
    if (self.bgOnly) return @[@"Backgrounds", @"Media", @"Saved", @"Look", @"Show on", @"Per page"][s];
    return @[@"Add-ons", @"Backgrounds", @"AI DJ", @"Add-on Shop", @"Settings", @"About"][s];
}

- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    return MRGSafeString(^NSString *{ return [self mrg_footerIn:t section:s]; });
}

- (NSString *)mrg_footerIn:(UITableView *)t section:(NSInteger)s {
    if (self.djOnly) {
        switch (s) {
            case 0: return @"Bring your own key: OpenAI, Gemini (Google AI Studio keys, AQ.… or AIza…), Anthropic, OpenRouter, Groq, xAI, Perplexity, Cerebras, Fireworks, Together, DeepSeek or Mistral. Keys stay in this phone's keychain.\nFree tiers run out: on Groq pick llama-3.1-8b-instant or llama-3.3-70b-versatile (more tokens a day than gpt-oss-120b), on Gemini gemini-2.5-flash-lite; Cerebras and OpenRouter's :free models are free too. A backup key (another provider or account) takes over for 30 minutes when the main one answers 429.";
            case 1: return @"Talk like me: the DJ mirrors how you write to it in the chat (your last messages, kept on this phone, go to your provider with each request). Turn it off to keep only the persona.";
            case 2: return @"The DJ picks and talks from what you actually play: on repeat lately, your top artists and throwbacks, from Mirage's own recording and any Spotify data you import.";
            case 4: return @"Privacy: only track and artist names (what's playing, your history summary, the queue), what you type, and answers a chat question needs are sent to your provider. On Spotify Free, Spotify may shuffle the set and its skip limit still applies.";
        }
        return nil;
    }
    if (self.bgOnly) {
        switch (s) {
            case MRGBgMedia: return @"Images (PNG, JPG, HEIC), GIFs (converted to a looping MP4 when you pick them) and videos (MP4, MOV). Each one you pick is kept. Videos play muted, never touch Spotify's audio, and pause when Spotify is in the background or Low Power Mode is on.";
            case MRGBgLibrary: return @"Tap one to use it. Swipe to rename or delete. The one marked On is used wherever a page doesn't have its own.";
            case MRGBgLook: return @"Top fade is the dark shade Spotify lays behind the status bar and the header: Soft keeps a third of it, Off removes it. Clear page backgrounds makes Spotify's own page fill transparent so the background shows through; cards and Vitrine's glass stay as they are. Profile picture glow replaces the profile page's color gradient with a soft glow of that color around your picture.";
            case MRGBgScreens: return @"Everywhere puts one background behind every page, Home and Library included. The side drawer has its own switch, a little dimmer so its text stays readable.";
            case MRGBgAssign: return @"Give Home, Now Playing, Library or Everywhere its own saved background. Active uses whichever one is marked On.";
        }
        return nil;
    }
    switch (s) {
        case MRGSecAddons: return @"Turn any add-on on or off right here; the arrow opens its settings. Previews and descriptions are in the Add-on Shop.";
        case MRGSecBackgrounds: return @"Pictures, video and where they show live on the Backgrounds page. What you already set is kept.";
        case MRGSecSaver: return @"Every change saves itself right away. Here you can export or import all Mirage settings, or keep named presets on this iPhone. API keys are never included.";
        case MRGSecDJ:
            return @"Voice, personality, provider, chat and the DJ's other settings are on the AI DJ page. Bring your own key: OpenAI, Gemini (Google AI Studio keys, AQ.… or AIza…), Anthropic, OpenRouter, Groq, xAI, Perplexity, Cerebras, Fireworks, Together, DeepSeek or Mistral. The key stays in this phone's keychain. Privacy: only track and artist names (what's playing, what you played, the queue around it), what you type, and answers from your on-phone listening history that a chat question needs are sent to your provider. Voice: iPhone voices, your provider's voices, or ElevenLabs with its own key. On Spotify Free, Spotify may shuffle the set and its skip limit still applies.";
        case MRGSecAbout: return @"Mirage is free software under the GPL-3.0, built on Vitrine (github.com/meownyaaa/vitrine), itself a fork of Chroma by skopevoj (spoti.pw, up to v0.21.1).";
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)t heightForRowAtIndexPath:(NSIndexPath *)ip {
    if (self.djOnly) return 48;
    if (!self.bgOnly && ip.section == MRGSecAddons) return 64;
    if (self.bgOnly && ip.section == MRGBgPreview && ip.row == 1) return MRGCurrentKind() == MRGMediaNone ? 52 : 200;
    if (self.bgOnly && ip.section == MRGBgLook && ip.row < 2) return 64;
    return 48;
}

// iOS Settings-style icon tiles: the row's symbol in white on a small rounded square of the accent (red for a
// destructive row, gray when the row is off), so every page of Mirage has the same look.
static UIImage *tileFor(NSString *symbol, UIColor *color) {
    if (!symbol.length) return nil;
    static NSCache *cache;
    if (!cache) cache = [NSCache new];
    NSString *key = [NSString stringWithFormat:@"%@|%06lX", symbol, (long)MRGRGBFromColor(color)];
    UIImage *hit = [cache objectForKey:key];
    if (hit) return hit;
    UIImage *glyph = [[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold]]
                      imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    if (!glyph) return nil;
    CGFloat side = 29;
    UIImage *img = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect r = CGRectMake(0, 0, side, side);
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:7.5];
        [p addClip];
        CGFloat h = 0, s = 0, b = 0, a = 1;
        [color getHue:&h saturation:&s brightness:&b alpha:&a];
        UIColor *lo = [UIColor colorWithHue:h saturation:s brightness:b * 0.72 alpha:1];
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGGradientRef g = CGGradientCreateWithColors(space, (__bridge CFArrayRef)@[(id)color.CGColor, (id)lo.CGColor], NULL);
        CGContextDrawLinearGradient(ctx.CGContext, g, CGPointZero, CGPointMake(0, side), 0);
        CGGradientRelease(g);
        CGColorSpaceRelease(space);
        CGSize z = glyph.size;
        CGFloat k = MIN(17 / MAX(z.width, 1), 17 / MAX(z.height, 1));
        z = CGSizeMake(z.width * k, z.height * k);
        [glyph drawInRect:CGRectMake((side - z.width) / 2, (side - z.height) / 2, z.width, z.height)];
    }];
    if (img) [cache setObject:img forKey:key];
    return img;
}

static UITableViewCell *baseCell(void) {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.78];
    c.textLabel.textColor = UIColor.whiteColor;
    c.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    c.detailTextLabel.font = [UIFont systemFontOfSize:15];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    UIView *sel = [UIView new];
    sel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    c.selectedBackgroundView = sel;
    return c;
}

- (UITableViewCell *)switchCell:(NSString *)title on:(BOOL)on tag:(NSInteger)tag symbol:(NSString *)symbol {
    UITableViewCell *c = baseCell();
    c.textLabel.text = title;
    if (symbol) c.imageView.image = tileFor(symbol, MRGAccent());
    UISwitch *sw = [UISwitch new];
    sw.on = on;
    sw.tag = tag;
    sw.onTintColor = MRGAccent();
    [sw addTarget:self action:@selector(switched:) forControlEvents:UIControlEventValueChanged];
    c.accessoryView = sw;
    return c;
}

- (UITableViewCell *)sliderCell:(NSString *)title value:(double)v max:(double)max tag:(NSInteger)tag {
    UITableViewCell *c = baseCell();
    UILabel *label = [UILabel new];
    label.text = title;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:15];
    UISlider *slider = [UISlider new];
    slider.minimumValue = 0;
    slider.maximumValue = max;
    slider.value = v;
    slider.tag = tag;
    slider.continuous = NO;
    slider.minimumTrackTintColor = UIColor.whiteColor;
    [slider addTarget:self action:@selector(slid:) forControlEvents:UIControlEventValueChanged];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, slider]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 4;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [c.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.trailingAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:c.contentView.centerYAnchor],
    ]];
    return c;
}

- (UITableViewCell *)actionCell:(NSString *)title symbol:(NSString *)symbol destructive:(BOOL)destructive enabled:(BOOL)enabled {
    UITableViewCell *c = baseCell();
    c.textLabel.text = title;
    c.textLabel.textColor = !enabled ? UIColor.grayColor : destructive ? UIColor.systemRedColor : UIColor.whiteColor;
    c.imageView.image = tileFor(symbol, !enabled ? [UIColor colorWithWhite:0.35 alpha:1] : destructive ? UIColor.systemRedColor : MRGAccent());
    c.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    c.userInteractionEnabled = enabled;
    return c;
}

- (UITableViewCell *)comingSoon:(NSString *)title symbol:(NSString *)symbol {
    UITableViewCell *c = baseCell();
    c.textLabel.text = title;
    c.textLabel.textColor = UIColor.grayColor;
    c.imageView.image = tileFor(symbol, [UIColor colorWithWhite:0.35 alpha:1]);
    c.detailTextLabel.text = @"Coming soon";
    c.detailTextLabel.textColor = UIColor.grayColor;
    return c;
}

- (UITableViewCell *)djCell:(NSInteger)row {
    MRGProvider provider = MRGAIProvider();
    BOOL hasKey = provider != MRGProviderNone;
    switch (row) {
        case 0: {
            UITableViewCell *c = [self actionCell:@"API key" symbol:@"key.fill" destructive:NO enabled:YES];
            c.detailTextLabel.text = hasKey ? MRGProviderName(provider) : @"Add";
            c.detailTextLabel.textColor = UIColor.grayColor;
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        case 1: {
            UITableViewCell *c = [self actionCell:@"Provider" symbol:@"server.rack" destructive:NO enabled:YES];
            c.detailTextLabel.text = hasKey ? MRGProviderName(provider) : @"From the key";
            c.detailTextLabel.textColor = UIColor.grayColor;
            return c;
        }
        case 2: {
            UITableViewCell *c = [self actionCell:@"Model" symbol:@"cpu" destructive:NO enabled:hasKey];
            NSString *model = MRGAIModel();
            c.detailTextLabel.text = hasKey ? [NSString stringWithFormat:@"%@%@", model ?: @"-", MRGAIHasOverride() ? @"" : @" ✦"] : @"-";
            c.detailTextLabel.textColor = UIColor.grayColor;
            c.detailTextLabel.adjustsFontSizeToFitWidth = YES;
            c.detailTextLabel.minimumScaleFactor = 0.6;
            return c;
        }
        case 3: case 4: case 6: {
            NSString *title = ip3(row);
            UITableViewCell *c = [self actionCell:title symbol:row == 3 ? @"speaker.wave.2.fill" : row == 4 ? @"theatermasks.fill" : @"clock.arrow.circlepath" destructive:NO enabled:YES];
            c.detailTextLabel.text = row == 3 ? MRGVoiceSummary() : row == 4 ? MRGDJPersonaNames()[MRGDJPersona()] : nil;
            c.detailTextLabel.textColor = UIColor.grayColor;
            c.detailTextLabel.adjustsFontSizeToFitWidth = YES;
            c.detailTextLabel.minimumScaleFactor = 0.6;
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        case 13: {
            UITableViewCell *c = [self actionCell:@"Backup key" symbol:@"arrow.triangle.2.circlepath" destructive:NO enabled:YES];
            MRGProvider b = MRGAIBackupProvider();
            c.detailTextLabel.text = b == MRGProviderNone ? @"Optional" : [NSString stringWithFormat:@"%@%@", MRGProviderName(b), MRGAIUsingBackup() ? @" · in use" : @""];
            c.detailTextLabel.textColor = UIColor.grayColor;
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        case 5: return [self actionCell:@"Chat with your DJ" symbol:@"bubble.left.and.text.bubble.right.fill" destructive:NO enabled:hasKey];
        case 7: return [self switchCell:@"Lower music while talking" on:MRGDJDucks() tag:20 symbol:@"speaker.badge.exclamationmark.fill"];
        case 8: return [self switchCell:@"DJ chip on Home" on:MRGDJShowsPill() tag:21 symbol:@"capsule.fill"];
        case 9: return [self switchCell:@"DJ button on Now Playing" on:MRGDJShowsPlayerButton() tag:22 symbol:@"play.circle.fill"];
        case 10: return [self actionCell:@"Open Mirage DJ" symbol:@"waveform.and.mic" destructive:NO enabled:YES];
        case 12: return [self switchCell:@"Talk like me" on:MRGDJMirrorsUser() tag:23 symbol:@"person.wave.2.fill"];
        default: {
            UITableViewCell *c = [self actionCell:@"DJ debug log" symbol:@"ladybug.fill" destructive:NO enabled:YES];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
    }
}

static NSString *ip3(NSInteger row) { return row == 3 ? @"Voice" : row == 4 ? @"Vibe" : @"Listening history"; }

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; [self updateHero]; }

// The main page's header: the name, the version, and how many add-ons are on.
- (void)updateHero {
    if (self.djOnly || self.bgOnly || !self.isViewLoaded) return;
    UIView *hero = self.tableView.tableHeaderView;
    if (hero.tag != 0x4D52) {
        hero = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 116)];
        hero.tag = 0x4D52;
        UILabel *kicker = [UILabel new]; kicker.tag = 1;
        kicker.font = [UIFont systemFontOfSize:12 weight:UIFontWeightHeavy];
        kicker.text = @"SPOTIFY, YOUR WAY";
        UILabel *title = [UILabel new]; title.tag = 2;
        title.text = @"Mirage";
        title.font = [UIFont systemFontOfSize:38 weight:UIFontWeightHeavy];
        title.textColor = UIColor.whiteColor;
        UILabel *chip = [UILabel new]; chip.tag = 3;
        chip.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
        chip.textAlignment = NSTextAlignmentCenter;
        chip.layer.cornerRadius = 11;
        chip.layer.cornerCurve = kCACornerCurveContinuous;
        chip.clipsToBounds = YES;
        UILabel *sub = [UILabel new]; sub.tag = 4;
        sub.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        sub.textColor = [UIColor colorWithWhite:1 alpha:0.6];
        for (UIView *v in @[kicker, title, chip, sub]) [hero addSubview:v];
    }
    UILabel *kicker = [hero viewWithTag:1], *title = [hero viewWithTag:2], *chip = [hero viewWithTag:3], *sub = [hero viewWithTag:4];
    kicker.textColor = MRGAccent();
    chip.text = [NSString stringWithFormat:@"  v%@  ", @(MRG_VERSION)];
    chip.backgroundColor = [MRGAccent() colorWithAlphaComponent:0.22];
    chip.textColor = MRGAccent();
    NSUInteger on = 0, all = 0;
    for (NSDictionary *a in MRGAddonIndex()) { if (!MRGAddonBuiltIn(a[@"id"])) continue; all++; if (MRGAddonInstalled(a[@"id"])) on++; }
    sub.text = [NSString stringWithFormat:@"%lu of %lu add-ons on  ·  Vitrine %@", (unsigned long)on, (unsigned long)all, NSClassFromString(@"SGModSettingsRow") ? @"loaded" : @"not loaded"];
    CGFloat x = 20 + self.tableView.safeAreaInsets.left, w = self.tableView.bounds.size.width;
    kicker.frame = CGRectMake(x, 14, w - 2 * x, 16);
    [title sizeToFit];
    title.frame = CGRectMake(x, 30, title.bounds.size.width, 46);
    [chip sizeToFit];
    chip.frame = CGRectMake(CGRectGetMaxX(title.frame) + 10, 30 + (46 - 22) / 2 + 3, chip.bounds.size.width, 22);
    sub.frame = CGRectMake(x, 78, w - 2 * x, 20);
    hero.frame = CGRectMake(0, 0, w, 108);
    self.tableView.tableHeaderView = hero;
}

- (void)tableView:(UITableView *)t willDisplayHeaderView:(UIView *)view forSection:(NSInteger)s {
    if (![view isKindOfClass:UITableViewHeaderFooterView.class]) return;
    UITableViewHeaderFooterView *h = (UITableViewHeaderFooterView *)view;
    h.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    h.textLabel.textColor = [UIColor colorWithWhite:1 alpha:0.55];
}

- (void)pickProvider:(UIView *)source {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Provider"
        message:@"Mirage tells the provider from the key. If it guesses wrong, choose it here."
        preferredStyle:UIAlertControllerStyleActionSheet];
    BOOL hasKey = MRGAIProvider() != MRGProviderNone;
    for (NSNumber *n in MRGAllProviders()) {
        MRGProvider p = n.integerValue;
        NSString *title = MRGProviderName(p);
        if (hasKey && p == MRGAIProvider()) title = [@"✓ " stringByAppendingString:title];
        [a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            NSString *saved = MRGKeychainAPIKey();
            if (saved.length) [self setupKey:saved as:p];
            else [self editKeyAs:p];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = source;
    a.popoverPresentationController.sourceRect = source.bounds;
    [self presentViewController:a animated:YES completion:nil];
}

- (void)setupKey:(NSString *)key as:(MRGProvider)p {
    [self->_spinner startAnimating];
    MRGAISetupKeyAs(key, p, ^(BOOL ok, NSString *message) {
        [self->_spinner stopAnimating];
        [self reloadDJ];
        UIAlertController *r = [UIAlertController alertControllerWithTitle:ok ? @"Ready" : @"Couldn't use that key" message:message preferredStyle:UIAlertControllerStyleAlert];
        [r addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:r animated:YES completion:nil];
    });
}

- (void)editKey { [self editKeyAs:MRGProviderNone]; }

- (void)editBackupKey {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Backup key" message:@"A second key (another provider, or another free account). When the main key answers 429 (rate limit or daily tokens used up), the DJ uses this one for 30 minutes." preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = @"gsk_… / AIza… / sk-or-… / csk-…";
        f.secureTextEntry = YES;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (MRGAIBackupProvider() != MRGProviderNone) [a addAction:[UIAlertAction actionWithTitle:@"Remove backup" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { MRGAIForgetBackup(); [self reloadDJ]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *key = a.textFields.firstObject.text;
        if (!key.length) return;
        [self->_spinner startAnimating];
        MRGAISetupBackupKey(key, ^(BOOL ok, NSString *message) {
            [self->_spinner stopAnimating];
            [self reloadDJ];
            UIAlertController *r = [UIAlertController alertControllerWithTitle:ok ? @"Ready" : @"Couldn't use that key" message:message preferredStyle:UIAlertControllerStyleAlert];
            [r addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:r animated:YES completion:nil];
        });
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)reloadDJ { [self.tableView reloadData]; }

- (void)editKeyAs:(MRGProvider)forced {
    BOOL hasKey = MRGAIProvider() != MRGProviderNone;
    NSString *title = forced == MRGProviderNone ? @"AI provider key" : [NSString stringWithFormat:@"%@ key", MRGProviderName(forced)];
    NSString *msg = forced == MRGProviderNone
        ? @"Paste an API key from OpenAI, Gemini (Google AI Studio), Anthropic, OpenRouter, Groq, xAI, Perplexity, Cerebras, Fireworks, Together, DeepSeek or Mistral. Mirage tells the provider from the key; choose it under Provider if it can't."
        : [NSString stringWithFormat:@"Paste your %@ API key.", MRGProviderName(forced)];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = @"sk-… / AQ.… / AIza… / gsk_… / xai-…";
        f.secureTextEntry = YES;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (hasKey) {
        [a addAction:[UIAlertAction actionWithTitle:@"Remove key" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [MRGDJ.shared stop];
            MRGAIForgetKey();
            [self reloadDJ];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *key = a.textFields.firstObject.text;
        if (!key.length) return;
        [self setupKey:key as:forced];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)pickModel:(UIView *)source {
    NSString *recommended = MRGAIRecommendedModel();
    NSMutableArray *models = [MRGAIModels() mutableCopy];
    if (recommended) { [models removeObject:recommended]; [models insertObject:recommended atIndex:0]; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Model"
        message:[NSString stringWithFormat:@"✦ is the recommended one for %@: fast and cheap. Any chat model works.", MRGProviderName(MRGAIProvider())]
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSUInteger shown = 0;
    for (NSString *m in models) {
        NSString *title = [m isEqualToString:recommended] ? [m stringByAppendingString:@" ✦"] : m;
        if ([m isEqualToString:MRGAIModel()]) title = [@"✓ " stringByAppendingString:title];
        [a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            MRGAISetModelOverride(m);
            [self reloadDJ];
        }]];
        if (++shown >= 40) break;
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = source;
    a.popoverPresentationController.sourceRect = source.bounds;
    [self presentViewController:a animated:YES completion:nil];
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    return MRGSafeCell(ip, ^UITableViewCell *{ return [self mrg_cellIn:t at:ip]; });
}

- (UITableViewCell *)libraryCell:(NSInteger)row {
    NSArray *items = MRGBackgroundLibrary();
    UITableViewCell *c = baseCell();
    if (!items.count) {
        c.textLabel.text = @"No saved backgrounds yet";
        c.textLabel.textColor = UIColor.grayColor;
        return c;
    }
    NSDictionary *item = items[row];
    c.textLabel.text = item[@"name"] ?: item[@"file"];
    BOOL on = [item[@"id"] isEqualToString:MRGBackgroundActiveID()];
    c.detailTextLabel.text = on ? @"On" : nil;
    c.detailTextLabel.textColor = UIColor.grayColor;
    c.accessoryType = on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    c.selectionStyle = UITableViewCellSelectionStyleDefault;
    return c;
}

- (UITableViewCell *)assignCell:(NSInteger)row {
    NSArray *titles = @[@"Home", @"Now Playing", @"Library", @"Everywhere"];
    NSArray *bits = @[@(MRGScreenHome), @(MRGScreenNowPlaying), @(MRGScreenLibrary), @(MRGScreenEverywhere)];
    UITableViewCell *c = [self actionCell:titles[row] symbol:nil destructive:NO enabled:YES];
    NSString *itemID = MRGBackgroundAssignment([bits[row] unsignedIntegerValue]);
    NSString *name = nil;
    for (NSDictionary *item in MRGBackgroundLibrary()) if ([item[@"id"] isEqualToString:itemID]) name = item[@"name"];
    c.detailTextLabel.text = name ?: @"Active";
    c.detailTextLabel.textColor = UIColor.grayColor;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (UITableViewCell *)mrg_cellIn:(UITableView *)t at:(NSIndexPath *)ip {
    if (self.djOnly) { NSInteger row = [self djRowAt:ip]; return row >= 0 ? [self djCell:row] : baseCell(); }
    if (self.bgOnly) {
    MRGScreen screens = MRGScreens();
    BOOL hasMedia = MRGCurrentKind() != MRGMediaNone;
        switch (ip.section) {
            case MRGBgPreview:
                if (ip.row == 0) return [self switchCell:@"Custom background" on:MRGBackgroundEnabled() tag:1 symbol:@"sparkles"];
                if (!hasMedia) {
                    UITableViewCell *c = baseCell();
                    c.textLabel.text = @"No background picked yet";
                    c.textLabel.textColor = UIColor.grayColor;
                    return c;
                } else {
                    UITableViewCell *c = baseCell();
                    MRGBackgroundView *preview = [[MRGBackgroundView alloc] initWithFrame:c.contentView.bounds];
                    preview.fitsBounds = YES;
                    preview.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                    [c.contentView addSubview:preview];
                    return c;
                }
            case MRGBgMedia:
                if (ip.row == 0) return [self actionCell:@"Choose from Photos" symbol:@"photo.on.rectangle" destructive:NO enabled:YES];
                if (ip.row == 1) return [self actionCell:@"Choose from Files" symbol:@"folder" destructive:NO enabled:YES];
                return [self actionCell:@"Remove background" symbol:@"trash" destructive:YES enabled:hasMedia];
            case MRGBgLibrary: return [self libraryCell:ip.row];
            case MRGBgLook:
                if (ip.row == 0) return [self sliderCell:@"Blur" value:MRGBlur() max:1 tag:10];
                if (ip.row == 1) return [self sliderCell:@"Dim" value:MRGDim() max:0.9 tag:11];
                if (ip.row == 2) {
                    UITableViewCell *c = baseCell();
                    c.textLabel.text = @"Scale";
                    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"Fill", @"Fit", @"Stretch"]];
                    seg.selectedSegmentIndex = MRGScale();
                    [seg addTarget:self action:@selector(scaled:) forControlEvents:UIControlEventValueChanged];
                    c.accessoryView = seg;
                    [seg sizeToFit];
                    return c;
                }
                if (ip.row == 3) {
                    UITableViewCell *c = baseCell();
                    c.textLabel.text = @"Top fade";
                    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"Off", @"Soft", @"Full"]];
                    seg.selectedSegmentIndex = MRGTopFade();
                    [seg addTarget:self action:@selector(faded:) forControlEvents:UIControlEventValueChanged];
                    c.accessoryView = seg;
                    [seg sizeToFit];
                    return c;
                }
                if (ip.row == 4) return [self switchCell:@"Clear page backgrounds" on:MRGClearPages() tag:2 symbol:nil];
                return [self switchCell:@"Profile picture glow" on:MRGProfileGlow() tag:3 symbol:nil];
            case MRGBgScreens: {
                NSArray *titles = @[@"Home", @"Now Playing", @"Library", @"Everywhere", @"Show in side drawer"];
                NSArray *symbols = @[@"house.fill", @"play.circle.fill", @"books.vertical.fill", @"square.stack.3d.up.fill", @"sidebar.left"];
                return [self switchCell:titles[ip.row] on:(screens & (1 << ip.row)) != 0 tag:100 + ip.row symbol:symbols[ip.row]];
            }
            case MRGBgAssign: return [self assignCell:ip.row];
        }
        return baseCell();
    }
    switch (ip.section) {
        case MRGSecAddons: {
            NSArray *list = mainAddons();
            MRGAddonRowCell *c = [t dequeueReusableCellWithIdentifier:@"mirage.addonrow"] ?: [[MRGAddonRowCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"mirage.addonrow"];
            if (ip.row >= (NSInteger)list.count) return baseCell();
            [c fill:list[ip.row]];
            __weak MRGSettingsController *weak = self;
            NSString *addonID = list[ip.row][@"id"];
            c.onToggle = ^(BOOL on) { [weak setAddon:addonID on:on]; };
            return c;
        }
        case MRGSecBackgrounds: {
            UITableViewCell *c = [self actionCell:@"Backgrounds" symbol:@"photo.on.rectangle.angled" destructive:NO enabled:YES];
            NSUInteger n = MRGBackgroundLibrary().count;
            c.detailTextLabel.text = n ? [NSString stringWithFormat:@"%lu saved", (unsigned long)n] : @"Set up";
            c.detailTextLabel.textColor = UIColor.grayColor;
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        default: break;
    }
    switch (ip.section) {
        case MRGSecShop: {
            UITableViewCell *c = [self actionCell:@"Add-on Shop" symbol:@"bag.fill" destructive:NO enabled:YES];
            NSUInteger n = MRGAddonsInstalledCount();
            c.detailTextLabel.text = n ? [NSString stringWithFormat:@"%lu on", (unsigned long)n] : @"Browse";
            c.detailTextLabel.textColor = UIColor.grayColor;
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        case MRGSecSaver: {
            UITableViewCell *c = [self actionCell:@"Save & load settings" symbol:@"square.and.arrow.up" destructive:NO enabled:YES];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        case MRGSecDJ: {
            UITableViewCell *c = [self actionCell:@"AI DJ" symbol:@"waveform.and.mic" destructive:NO enabled:YES];
            MRGProvider provider = MRGAIProvider();
            c.detailTextLabel.text = provider != MRGProviderNone ? [NSString stringWithFormat:@"%@ · %@", MRGProviderName(provider), MRGDJPersonaNames()[MRGDJPersona()]] : @"Set up";
            c.detailTextLabel.textColor = UIColor.grayColor;
            c.detailTextLabel.adjustsFontSizeToFitWidth = YES;
            c.detailTextLabel.minimumScaleFactor = 0.7;
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        case MRGSecAbout: {
            UITableViewCell *c = baseCell();
            c.textLabel.text = ip.row == 0 ? @"Version" : @"Vitrine";
            c.detailTextLabel.adjustsFontSizeToFitWidth = YES;
            c.detailTextLabel.minimumScaleFactor = 0.75;
            c.detailTextLabel.text = ip.row == 0 ? MRGVersionLine() : (NSClassFromString(@"SGModSettingsRow") ? @"Loaded" : @"Not loaded");
            c.detailTextLabel.textColor = UIColor.grayColor;
            return c;
        }
    }
    return baseCell();
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (self.djOnly) {
        NSInteger row = [self djRowAt:ip];
        if (row == 0) [self editKey];
        else if (row == 1) [self pickProvider:[t cellForRowAtIndexPath:ip]];
        else if (row == 2 && MRGAIProvider() != MRGProviderNone) [self pickModel:[t cellForRowAtIndexPath:ip]];
        else if (row == 3) MRGPushPage(self, MRGVoicePage());
        else if (row == 4) MRGPushPage(self, MRGVibePage());
        else if (row == 5 && MRGAIProvider() != MRGProviderNone) MRGShowDJChat(self);
        else if (row == 6) MRGPushPage(self, MRGHistoryPage());
        else if (row == 10) MRGShowDJ(self);
        else if (row == 11) MRGPushPage(self, MRGDJLogPage());
        else if (row == 13) [self editBackupKey];
        return;
    }
    if (self.bgOnly) {
        if (ip.section == MRGBgMedia) {
            if (ip.row == 0) [self pickFromPhotos];
            else if (ip.row == 1) [self pickFromFiles];
            else [self confirmRemoveBackground];
        } else if (ip.section == MRGBgLibrary && MRGBackgroundLibrary().count) {
            NSDictionary *item = MRGBackgroundLibrary()[ip.row];
            MRGBackgroundSetActive(item[@"id"]);
            [self.tableView reloadData];
        } else if (ip.section == MRGBgAssign) {
            [self pickAssignment:ip.row];
        }
        return;
    }
    if (ip.section == MRGSecAddons) {
        NSArray *list = mainAddons();
        if (ip.row < (NSInteger)list.count && MRGAddonHasSettings(list[ip.row][@"id"])) MRGPushPage(self, MRGAddonSettingsFor(list[ip.row][@"id"]));
        return;
    }
    if (ip.section == MRGSecBackgrounds) { MRGShowBackgroundSettings(self); return; }
    if (ip.section == MRGSecSaver) { MRGPushPage(self, MRGSaverPage()); return; }
    if (ip.section == MRGSecDJ) { MRGShowDJSettings(self); return; }
    if (ip.section == MRGSecShop) { MRGPushPage(self, MRGAddonShopPage()); return; }
}

// A switch on the main page: the same as the shop's, hooks included. The row updates after the switch has slid.
- (void)setAddon:(NSString *)addonID on:(BOOL)on {
    @try { MRGAddonSetInstalled(addonID, on); } @catch (NSException *e) { MRGDJLog(@"settings: switching %@ threw %@", addonID, e.reason); }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.djOnly || self.bgOnly || !self.isViewLoaded) return;
        [UIView performWithoutAnimation:^{
            @try { [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:MRGSecAddons] withRowAnimation:UITableViewRowAnimationNone];
                   [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:MRGSecShop] withRowAnimation:UITableViewRowAnimationNone]; }
            @catch (NSException *e) { [self.tableView reloadData]; }
        }];
    });
}

- (void)confirmRemoveBackground {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Remove background?" message:@"This deletes the one marked On. The others stay." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        MRGRemoveCurrentMedia();
        [self.tableView reloadData];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)pickAssignment:(NSInteger)row {
    NSArray *bits = @[@(MRGScreenHome), @(MRGScreenNowPlaying), @(MRGScreenLibrary), @(MRGScreenEverywhere)];
    MRGScreen screen = [bits[row] unsignedIntegerValue];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Background" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"Active" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        MRGBackgroundSetAssignment(screen, nil);
        [self.tableView reloadData];
    }]];
    for (NSDictionary *item in MRGBackgroundLibrary()) {
        [a addAction:[UIAlertAction actionWithTitle:item[@"name"] ?: item[@"file"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            MRGBackgroundSetAssignment(screen, item[@"id"]);
            [self.tableView reloadData];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIView *source = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:MRGBgAssign]];
    a.popoverPresentationController.sourceView = source;
    a.popoverPresentationController.sourceRect = source.bounds;
    [self presentViewController:a animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)t trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (!self.bgOnly || ip.section != MRGBgLibrary || !MRGBackgroundLibrary().count) return nil;
    NSDictionary *item = MRGBackgroundLibrary()[ip.row];
    UIContextualAction *rename = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Rename" handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Rename" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = item[@"name"]; }];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { done(NO); }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            MRGBackgroundRename(item[@"id"], a.textFields.firstObject.text);
            [self.tableView reloadData];
            done(YES);
        }]];
        [self presentViewController:a animated:YES completion:nil];
    }];
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
        MRGBackgroundDelete(item[@"id"]);
        [self.tableView reloadData];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete, rename]];
}

#pragma mark - controls

- (void)switched:(UISwitch *)sw {
    if (sw.tag == 1) MRGSetBackgroundEnabled(sw.on);
    else if (sw.tag == 2) MRGSetClearPages(sw.on);
    else if (sw.tag == 3) MRGSetProfileGlow(sw.on);
    else if (sw.tag == 20) MRGDJSetDucks(sw.on);
    else if (sw.tag == 21) MRGDJSetShowsPill(sw.on);
    else if (sw.tag == 22) MRGDJSetShowsPlayerButton(sw.on);
    else if (sw.tag == 23) MRGDJSetMirrorsUser(sw.on);
    else if (sw.tag >= 100) {
        MRGScreen bit = 1 << (sw.tag - 100);
        MRGSetScreens(sw.on ? (MRGScreens() | bit) : (MRGScreens() & ~bit));
    }
}

- (void)slid:(UISlider *)s {
    if (s.tag == 10) MRGSetBlur(s.value);
    else MRGSetDim(s.value);
    if (self.bgOnly) [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:MRGBgPreview] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)faded:(UISegmentedControl *)seg { MRGSetTopFade(seg.selectedSegmentIndex); }

- (void)scaled:(UISegmentedControl *)seg {
    MRGSetScale(seg.selectedSegmentIndex);
    if (self.bgOnly) [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:MRGBgPreview] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - picking

- (void)pickFromPhotos {
    PHPickerConfiguration *config = [PHPickerConfiguration new];
    config.selectionLimit = 1;
    config.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[PHPickerFilter.imagesFilter, PHPickerFilter.videosFilter]];
    config.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    picker.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSItemProvider *p = results.firstObject.itemProvider;
    if (!p) return;
    // GIF first (it also conforms to image), then movies, then any image.
    NSString *type = nil;
    for (UTType *t in @[UTTypeGIF, UTTypeMovie, UTTypeImage]) {
        if ([p hasItemConformingToTypeIdentifier:t.identifier]) { type = t.identifier; break; }
    }
    if (!type) return;
    [_spinner startAnimating];
    [p loadFileRepresentationForTypeIdentifier:type completionHandler:^(NSURL *url, NSError *error) {
        // The provider deletes its file when this block returns: copy it out first.
        NSURL *copy = nil;
        if (url) {
            copy = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:
                    [NSString stringWithFormat:@"mirage-pick-%@.%@", NSUUID.UUID.UUIDString, url.pathExtension ?: @"dat"]];
            if (![NSFileManager.defaultManager copyItemAtURL:url toURL:copy error:&error]) copy = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!copy) { [self finishedImport:error]; return; }
            MRGImportFile(copy, ^(NSError *e) {
                [NSFileManager.defaultManager removeItemAtURL:copy error:nil];
                [self finishedImport:e];
            });
        });
    }];
}

- (void)pickFromFiles {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeImage, UTTypeGIF, UTTypeMovie, UTTypeMPEG4Movie, UTTypeQuickTimeMovie] asCopy:YES];
    picker.delegate = self;
    picker.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    [_spinner startAnimating];
    MRGImportFile(url, ^(NSError *e) { [self finishedImport:e]; });
}

- (void)finishedImport:(NSError *)error {
    [_spinner stopAnimating];
    [self.tableView reloadData];
    if (!error) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Couldn't use that file" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

void MRGRegisterSettingsPage(void) {
    Protocol *page = objc_getProtocol("_TtP19Tome_PageAttributes17SPTPageController_") ?: objc_getProtocol("SPTPageController");
    sg_pageConforms = page && (class_conformsToProtocol(MRGSettingsController.class, page) || class_addProtocol(MRGSettingsController.class, page));
}

void MRGShowSettings(UIViewController *owner) {
    MRGSettingsController *page = [MRGSettingsController new];
    if (owner.navigationController && sg_pageConforms) {
        [owner.navigationController pushViewController:page animated:YES];
        return;
    }
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [owner presentViewController:nav animated:YES completion:nil];
}

// The AI DJ page on its own (from the Mirage settings row, the DJ sheet's and the chat's settings buttons).
void MRGShowBackgroundSettings(UIViewController *owner) {
    MRGSettingsController *page = [MRGSettingsController new];
    page.bgOnly = YES;
    if (owner.navigationController && sg_pageConforms) {
        [owner.navigationController pushViewController:page animated:YES];
        return;
    }
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [owner presentViewController:nav animated:YES completion:nil];
}

void MRGShowDJSettings(UIViewController *owner) {
    MRGSettingsController *page = [MRGSettingsController new];
    page.djOnly = YES;
    if (owner.navigationController && sg_pageConforms) {
        [owner.navigationController pushViewController:page animated:YES];
        return;
    }
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [owner presentViewController:nav animated:YES completion:nil];
}
