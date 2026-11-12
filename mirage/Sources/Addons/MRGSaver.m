// Save and load Mirage settings. One versioned JSON file, shared through the iOS share sheet.
// Background pictures are names only unless Include background files is on. API keys never leave the keychain,
// and listening history is not part of a settings file.
#import "Addons/MRGSaver.h"
#import "MRGPrefs.h"
#import "MRGSafe.h"
#import "MRGDJLog.h"
#import "Addons/MRGAddon.h"
#import "MRGAddons.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kInclude = @"mirage.saver.includeFiles";

static BOOL secretKey(NSString *key) {
    NSString *l = key.lowercaseString;
    for (NSString *word in @[@"key", @"token", @"secret", @"password", @"authorization", @"cookie"])
        if ([l containsString:word]) return YES;
    return NO;
}

static BOOL settingsKey(NSString *key) {
    if (![key hasPrefix:@"mirage."]) return NO;
    if (secretKey(key)) return NO;
    if ([key isEqualToString:@"mirage.addons.index"] || [key isEqualToString:@"mirage.themes.remoteCache"]) return NO;
    if ([key containsString:@"history"] || [key containsString:@"userVoice"] || [key containsString:@".log"]) return NO;
    // Per-launch bookkeeping, not settings: a restored "launching" flag would turn that add-on off as if it crashed.
    if ([key hasSuffix:@".launching"] || [key hasSuffix:@".notice"] || [key hasSuffix:@".recent"]) return NO;
    return YES;
}

static BOOL plistValue(id value) {
    if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class]) return YES;
    if ([value isKindOfClass:NSArray.class]) {
        for (id item in value) if (!plistValue(item)) return NO;
        return YES;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        for (id item in [value allValues]) if (!plistValue(item)) return NO;
        return YES;
    }
    if ([value isKindOfClass:NSData.class]) return YES;
    return NO;
}

static NSDictionary *snapshotWithFiles(BOOL files, NSString **error) {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionary];
    [NSUserDefaults.standardUserDefaults.dictionaryRepresentation enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
        if (settingsKey(key) && plistValue(obj)) prefs[key] = obj;
    }];
    NSMutableArray *backgrounds = [NSMutableArray array];
    NSMutableDictionary *blobs = [NSMutableDictionary dictionary];
    NSMutableArray *skipped = [NSMutableArray array];
    for (NSDictionary *item in MRGBackgroundLibrary()) {
        if (![item[@"file"] isKindOfClass:NSString.class]) continue;
        [backgrounds addObject:@{@"name": item[@"name"] ?: item[@"file"], @"file": item[@"file"], @"kind": item[@"kind"] ?: @0}];
        if (!files) continue;
        NSURL *url = [MRGMediaDirectory() URLByAppendingPathComponent:item[@"file"]];
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (!data) continue;
        if (data.length > 12 * 1024 * 1024) { [skipped addObject:item[@"file"]]; continue; }
        blobs[item[@"file"]] = [data base64EncodedStringWithOptions:0];
    }
    NSISO8601DateFormatter *fmt = [NSISO8601DateFormatter new];
    NSMutableDictionary *doc = [@{@"format": @1, @"mirage": @MRG_VERSION, @"exported": [fmt stringFromDate:NSDate.date],
                                  @"preferences": prefs, @"backgrounds": backgrounds} mutableCopy];
    if (files) doc[@"files"] = blobs;
    if (error && skipped.count) *error = [NSString stringWithFormat:@"Left out (over 12 MB): %@.", [skipped componentsJoinedByString:@", "]];
    return doc;
}

static NSString *validate(NSDictionary *doc, NSDictionary **prefsOut, NSArray **backgroundsOut, NSDictionary **filesOut) {
    if (![doc isKindOfClass:NSDictionary.class]) return @"That file isn't a Mirage settings file.";
    if (![doc[@"format"] isKindOfClass:NSNumber.class] || [doc[@"format"] integerValue] != 1)
        return @"This file is a different version than Mirage can read.";
    if (![doc[@"preferences"] isKindOfClass:NSDictionary.class]) return @"The settings in that file are missing.";
    NSMutableDictionary *prefs = [NSMutableDictionary dictionary];
    for (NSString *key in doc[@"preferences"]) {
        if (![key isKindOfClass:NSString.class] || !settingsKey(key)) return [NSString stringWithFormat:@"Refused a setting named %@.", key];
        id value = doc[@"preferences"][key];
        if (!plistValue(value)) return [NSString stringWithFormat:@"Couldn't read the setting %@.", key];
        prefs[key] = value;
    }
    if (doc[@"backgrounds"] && ![doc[@"backgrounds"] isKindOfClass:NSArray.class]) return @"The background list in that file is unreadable.";
    if (doc[@"files"] && ![doc[@"files"] isKindOfClass:NSDictionary.class]) return @"The background files in that file are unreadable.";
    if (prefsOut) *prefsOut = prefs;
    if (backgroundsOut) *backgroundsOut = [doc[@"backgrounds"] isKindOfClass:NSArray.class] ? doc[@"backgrounds"] : @[];
    if (filesOut) *filesOut = [doc[@"files"] isKindOfClass:NSDictionary.class] ? doc[@"files"] : nil;
    return nil;
}

// Loading a file or a preset also starts or stops the add-ons it turns on or off, the same as the shop's switch,
// so they work right away instead of after a relaunch. An add-on the file doesn't mention is turned off.
static void applyPrefs(NSDictionary *prefs) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *was = [NSMutableDictionary dictionary];
    for (id<MRGAddon> addon in MRGRegisteredAddons()) was[addon.addonID] = @(MRGAddonInstalled(addon.addonID));
    [prefs enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
        if (settingsKey(key)) [d setObject:obj forKey:key];
    }];
    for (id<MRGAddon> addon in MRGRegisteredAddons()) {
        NSString *flag = [@"mirage.addon." stringByAppendingString:addon.addonID];
        if (!prefs[flag]) [d setBool:NO forKey:flag];
        BOOL now = MRGAddonInstalled(addon.addonID);
        if (now == [was[addon.addonID] boolValue]) continue;
        if (now) MRGAddonRunEnable(addon.addonID);
        else MRGAddonRunDisable(addon.addonID);
    }
    [d synchronize];
    MRGPostChange();
}

static NSString *safeName(NSString *name) {
    NSString *base = name.lastPathComponent;
    if (!base.length || [base containsString:@"/"] || [base containsString:@".."]) return nil;
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"] invertedSet];
    if ([base rangeOfCharacterFromSet:bad].location != NSNotFound) return nil;
    return base;
}

static void writeFiles(NSDictionary *files) {
    [files enumerateKeysAndObjectsUsingBlock:^(NSString *name, id obj, BOOL *stop) {
        NSString *safe = safeName(name);
        if (!safe || ![obj isKindOfClass:NSString.class]) return;
        NSData *data = [[NSData alloc] initWithBase64EncodedString:obj options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (!data.length) return;
        NSURL *url = [MRGMediaDirectory() URLByAppendingPathComponent:safe];
        [data writeToURL:url atomically:YES];
        MRGMediaKind kind = [safe.pathExtension.lowercaseString isEqualToString:@"mp4"] || [safe.pathExtension.lowercaseString isEqualToString:@"mov"] ? MRGMediaVideo : MRGMediaImage;
        MRGSetCurrentMedia(url, kind);
    }];
}

static NSArray *presets(void) {
    id v = [NSUserDefaults.standardUserDefaults arrayForKey:@"mirage.presets"];
    return [v isKindOfClass:NSArray.class] ? v : @[];
}
static void savePresets(NSArray *list) {
    [NSUserDefaults.standardUserDefaults setObject:list forKey:@"mirage.presets"];
    MRGPostChange();
}

@interface MRGSaverController : UITableViewController <UIDocumentPickerDelegate>
@property (nonatomic, copy) NSString *note;
@end

@implementation MRGSaverController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Save & load settings";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.tableView.backgroundColor = UIColor.blackColor;
    UIEdgeInsets inset = self.tableView.contentInset; inset.bottom = 150; self.tableView.contentInset = inset;
}
- (BOOL)includeFiles {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:kInclude];
    return [v isKindOfClass:NSNumber.class] ? [v boolValue] : NO;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 3; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 3;
    if (s == 1) return 1;
    return MAX((NSInteger)presets().count, 1);
}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    return @[@"File", @"On this iPhone", @"Presets"][s];
}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    if (s == 0) return self.note ?: @"Background pictures are saved by name. Turn on Include background files to put the pictures in the file too. API keys stay in the keychain and are never exported. Listening history isn't part of this file.";
    if (s == 2) return @"A preset is a named look on this iPhone, such as Gym. Applying one restores those settings. It doesn't touch your API keys.";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    return MRGSafeCell(ip, ^UITableViewCell *{
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        c.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.9];
        c.textLabel.textColor = UIColor.whiteColor;
        if (ip.section == 0 && ip.row == 0) { c.textLabel.text = @"Export settings"; c.textLabel.textColor = MRGAccent(); return c; }
        if (ip.section == 0 && ip.row == 1) { c.textLabel.text = @"Import settings"; c.textLabel.textColor = MRGAccent(); return c; }
        if (ip.section == 0 && ip.row == 2) {
            c.textLabel.text = @"Include background files";
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            UISwitch *sw = [UISwitch new];
            sw.on = [self includeFiles];
            sw.onTintColor = MRGAccent();
            [sw addTarget:self action:@selector(include:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
            return c;
        }
        if (ip.section == 1) { c.textLabel.text = @"Save as a preset"; c.textLabel.textColor = MRGAccent(); return c; }
        NSArray *list = presets();
        if (!list.count) { c.textLabel.text = @"No presets yet"; c.textLabel.textColor = UIColor.grayColor; c.selectionStyle = UITableViewCellSelectionStyleNone; return c; }
        c.textLabel.text = list[ip.row][@"name"] ?: @"Preset";
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    });
}
- (void)include:(UISwitch *)sw { [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:kInclude]; }
- (void)alert:(NSString *)title message:(NSString *)message { 
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0 && ip.row == 0) [self exportFile];
    else if (ip.section == 0 && ip.row == 1) [self importFile];
    else if (ip.section == 1) [self savePreset];
    else if (presets().count) [self applyPreset:presets()[ip.row]];
}
- (void)exportFile {
    NSString *skipped = nil;
    NSDictionary *doc = snapshotWithFiles([self includeFiles], &skipped);
    NSData *data = [NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingPrettyPrinted error:nil];
    if (!data) { [self alert:@"Couldn't export" message:@"The settings couldn't be written."]; return; }
    NSURL *url = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:@"Mirage-settings.json"];
    [data writeToURL:url atomically:YES];
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    sheet.popoverPresentationController.sourceView = self.view;
    [self presentViewController:sheet animated:YES completion:nil];
    if (skipped) self.note = skipped;
    [self.tableView reloadData];
}
- (void)importFile {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES];
    picker.delegate = self;
    picker.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSData *data = [NSData dataWithContentsOfURL:urls.firstObject];
    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *prefs = nil, *files = nil;
    NSArray *backgrounds = nil;
    NSString *problem = validate(json, &prefs, &backgrounds, &files);
    if (problem) { [self alert:@"Couldn't use that file" message:problem]; return; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Load these settings?" message:@"This replaces the Mirage settings in the file. API keys are not changed." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Load" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        applyPrefs(prefs);
        if (files.count) writeFiles(files);
        (void)backgrounds;
        self.note = @"Loaded.";
        [self.tableView reloadData];
        MRGDJLog(@"settings: imported %lu settings", (unsigned long)prefs.count);
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (NSDictionary *)currentSnapshot {
    return snapshotWithFiles(NO, NULL);
}
- (void)savePreset {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Preset name" message:@"For example, Gym look." preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"Gym look"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *name = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length || name.length > 40) return;
        NSMutableDictionary *snap = [[self currentSnapshot] mutableCopy];
        NSMutableDictionary *prefs = [snap[@"preferences"] mutableCopy];
        [prefs removeObjectForKey:@"mirage.presets"];
        snap[@"preferences"] = prefs;
        NSMutableArray *list = [presets() mutableCopy];
        [list addObject:@{@"name": name, @"snapshot": snap}];
        savePresets(list);
        [self.tableView reloadData];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)applyPreset:(NSDictionary *)preset {
    NSDictionary *prefs = nil;
    NSString *problem = validate(preset[@"snapshot"], &prefs, NULL, NULL);
    if (problem) { [self alert:@"Couldn't apply it" message:problem]; return; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:preset[@"name"] message:@"Apply this preset? API keys stay as they are." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Apply" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        applyPrefs(prefs);
        self.note = [NSString stringWithFormat:@"Applied %@.", preset[@"name"]];
        [self.tableView reloadData];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)t trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section != 2 || !presets().count) return nil;
    NSDictionary *preset = presets()[ip.row];
    UIContextualAction *rename = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Rename" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = preset[@"name"]; }];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { done(NO); }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            NSMutableArray *list = [presets() mutableCopy];
            NSMutableDictionary *row = [preset mutableCopy];
            NSString *name = alert.textFields.firstObject.text;
            if (name.length) row[@"name"] = name;
            list[ip.row] = row;
            savePresets(list);
            done(YES);
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }];
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        NSMutableArray *list = [presets() mutableCopy];
        if (ip.row < (NSInteger)list.count) [list removeObjectAtIndex:ip.row];
        savePresets(list);
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete, rename]];
}
@end

UIViewController *MRGSaverPage(void) { return [MRGSaverController new]; }
