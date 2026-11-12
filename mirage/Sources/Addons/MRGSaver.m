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
#import <Security/Security.h>
#import <ImageIO/ImageIO.h>
#import "Addons/MRGThemes.h"

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
    if ([key isEqualToString:@"mirage.saver.present"] || [key hasPrefix:@"mirage.safemode."]) return NO;
    if ([key hasPrefix:@"mirage.compat."]) return NO;   // per install: whether fragile hooks run on an unverified Spotify
    if ([key hasPrefix:@"mirage.saver.keychain"]) return NO;   // the backup's own bookkeeping
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

#pragma mark - autosave

// Every Mirage setting is in NSUserDefaults the moment it changes. On top of that, the same settings (never API keys,
// history or per-launch flags) are copied to Documents/Mirage/settings-autosave.plist after each change and when
// Spotify leaves the screen. If Spotify's defaults come back empty (a reinstall or a container that kept Documents but
// not Preferences), that copy is loaded at the next launch, before any add-on starts.
static NSURL *autosaveURL(void) {
    NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [docs URLByAppendingPathComponent:@"Mirage" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:@"settings-autosave.plist"];
}

static NSDictionary *currentPrefs(void) {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionary];
    [NSUserDefaults.standardUserDefaults.dictionaryRepresentation enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
        if (settingsKey(key) && plistValue(obj)) prefs[key] = obj;
    }];
    return prefs;
}

#pragma mark - keychain backup

// The same settings as the autosave (never API keys, history or per-launch flags), also kept as one generic-password
// item in the iOS keychain: service com.x4nzz.mirage.settings, account "settings", readable after first unlock, not
// synced to iCloud, default access group. The API keys are their own items (service com.x4nzz.mirage.dj) and are
// never touched here. The keychain can outlive a deleted app when the reinstall is signed by the same team, which a
// Documents file can't; with LiveContainer or a different signing team the item may not be visible.
static NSString *const kBackupService = @"com.x4nzz.mirage.settings";
static NSString *const kBackupAccount = @"settings";
static NSString *const kBackupAt = @"mirage.saver.keychainAt";       // last successful write (seconds since 1970)
static NSString *const kBackupError = @"mirage.saver.keychainError"; // last failure, if the keychain refused

static NSMutableDictionary *backupQuery(void) {
    return [@{(id)kSecClass: (id)kSecClassGenericPassword, (id)kSecAttrService: kBackupService,
              (id)kSecAttrAccount: kBackupAccount, (id)kSecAttrSynchronizable: @NO} mutableCopy];
}

// Off the main thread (the autosave queue). Returns YES when the item holds these settings.
static BOOL backupWrite(NSDictionary *prefs) {
    NSDictionary *doc = @{@"version": @1, @"saved": NSDate.date, @"prefs": prefs};
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:doc format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data.length) return NO;
    NSDictionary *attrs = @{(id)kSecValueData: data, (id)kSecAttrAccessible: (id)kSecAttrAccessibleAfterFirstUnlock};
    OSStatus st = SecItemUpdate((CFDictionaryRef)backupQuery(), (CFDictionaryRef)attrs);
    if (st == errSecItemNotFound) {
        NSMutableDictionary *add = backupQuery();
        [add addEntriesFromDictionary:attrs];
        st = SecItemAdd((CFDictionaryRef)add, NULL);
    }
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (st == errSecSuccess) {
        [d setDouble:NSDate.date.timeIntervalSince1970 forKey:kBackupAt];
        if ([d objectForKey:kBackupError]) [d removeObjectForKey:kBackupError];
        return YES;
    }
    NSString *why = st == errSecMissingEntitlement ? @"no keychain access in this signature" : [NSString stringWithFormat:@"error %d", (int)st];
    if (![[d stringForKey:kBackupError] isEqualToString:why]) {
        [d setObject:why forKey:kBackupError];
        MRGDJLog(@"settings: keychain backup failed (%@)", why);
    }
    return NO;
}

static NSDictionary *backupRead(NSDate **savedOut) {
    NSMutableDictionary *q = backupQuery();
    q[(id)kSecReturnData] = @YES;
    q[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;
    CFTypeRef out = NULL;
    if (SecItemCopyMatching((CFDictionaryRef)q, &out) != errSecSuccess || !out) return nil;
    NSData *data = (__bridge_transfer NSData *)out;
    if (![data isKindOfClass:NSData.class]) return nil;
    id doc = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil];
    if (![doc isKindOfClass:NSDictionary.class] || ![doc[@"prefs"] isKindOfClass:NSDictionary.class]) return nil;
    if (savedOut && [doc[@"saved"] isKindOfClass:NSDate.class]) *savedOut = doc[@"saved"];
    return doc[@"prefs"];
}

#pragma mark - background pictures in the keychain (0.6.7)

// 0.6.7 root cause of "restore selects the backgrounds but doesn't apply them": the pictures are files in
// Documents/Mirage/Backgrounds, which a reinstall deletes, and the backup only held the settings (the names). The
// restored selection pointed at files that weren't there, so every screen showed none. Now each picture background is
// also kept in the keychain (its own item, service com.x4nzz.mirage.settings, account "bg:<file>"), as a JPEG at most
// 1800px on its long side, up to 8 pictures; videos are too big for the keychain and are named as not restored.
static NSString *const kBackupFiles = @"mirage.saver.keychainFiles";   // the names kept (bookkeeping, not a setting)
static NSString *const kBackupNote = @"mirage.saver.keychainNote";     // what the last restore couldn't bring back

static NSMutableDictionary *fileQuery(NSString *file) {
    return [@{(id)kSecClass: (id)kSecClassGenericPassword, (id)kSecAttrService: kBackupService,
              (id)kSecAttrAccount: [@"bg:" stringByAppendingString:file], (id)kSecAttrSynchronizable: @NO} mutableCopy];
}

static NSData *keptJPEG(NSURL *url) {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return nil;
    NSDictionary *opts = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES, (id)kCGImageSourceThumbnailMaxPixelSize: @1800,
                           (id)kCGImageSourceCreateThumbnailWithTransform: @YES};
    CGImageRef img = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(src);
    if (!img) return nil;
    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out, CFSTR("public.jpeg"), 1, NULL);
    if (dst) {
        CGImageDestinationAddImage(dst, img, (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality: @0.82});
        if (!CGImageDestinationFinalize(dst)) out = nil;
        CFRelease(dst);
    } else out = nil;
    CGImageRelease(img);
    return out.length ? out : nil;
}

// On the autosave queue: new picture backgrounds are copied in, deleted ones taken out. A theme's generated picture
// is left out (the theme makes it again).
static void backupFilesOnQueue(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSArray *had = [d arrayForKey:kBackupFiles] ?: @[];
    NSMutableArray *want = [NSMutableArray array];
    for (NSDictionary *item in MRGBackgroundLibrary()) {
        NSString *file = item[@"file"];
        if (![file isKindOfClass:NSString.class] || [file hasPrefix:@"theme-"] || [item[@"kind"] integerValue] != MRGMediaImage) continue;
        if (want.count < 8) [want addObject:file];
    }
    NSMutableArray *kept = [NSMutableArray array];
    for (NSString *file in want) {
        if ([had containsObject:file]) { [kept addObject:file]; continue; }
        NSData *jpg = keptJPEG([MRGMediaDirectory() URLByAppendingPathComponent:file]);
        if (!jpg || jpg.length > 2 * 1024 * 1024) continue;
        NSDictionary *attrs = @{(id)kSecValueData: jpg, (id)kSecAttrAccessible: (id)kSecAttrAccessibleAfterFirstUnlock};
        OSStatus st = SecItemUpdate((CFDictionaryRef)fileQuery(file), (CFDictionaryRef)attrs);
        if (st == errSecItemNotFound) { NSMutableDictionary *add = fileQuery(file); [add addEntriesFromDictionary:attrs]; st = SecItemAdd((CFDictionaryRef)add, NULL); }
        if (st == errSecSuccess) [kept addObject:file];
        else MRGDJLog(@"settings: keychain refused background %@ (error %d)", file, (int)st);
    }
    for (NSString *file in had) if (![want containsObject:file]) SecItemDelete((CFDictionaryRef)fileQuery(file));
    if (![kept isEqualToArray:had]) [d setObject:kept forKey:kBackupFiles];
}

// Brings back every listed background file that's missing. Returns the names it couldn't (videos, or pictures the
// keychain doesn't have).
static NSArray<NSString *> *restoreFiles(void) {
    NSMutableArray *missing = [NSMutableArray array];
    NSUInteger restored = 0;
    for (NSDictionary *item in MRGBackgroundLibrary()) {
        NSString *file = item[@"file"];
        if (![file isKindOfClass:NSString.class] || [file containsString:@"/"] || [file containsString:@".."]) continue;
        NSURL *url = [MRGMediaDirectory() URLByAppendingPathComponent:file];
        if ([NSFileManager.defaultManager fileExistsAtPath:url.path] || [file hasPrefix:@"theme-"]) continue;
        NSMutableDictionary *q = fileQuery(file);
        q[(id)kSecReturnData] = @YES;
        q[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;
        CFTypeRef out = NULL;
        NSData *data = nil;
        if (SecItemCopyMatching((CFDictionaryRef)q, &out) == errSecSuccess && out) data = (__bridge_transfer NSData *)out;
        if ([data isKindOfClass:NSData.class] && data.length && [data writeToURL:url atomically:YES]) { restored++; continue; }
        NSString *name = [item[@"name"] isKindOfClass:NSString.class] ? item[@"name"] : file;
        [missing addObject:[item[@"kind"] integerValue] == MRGMediaVideo ? [name stringByAppendingString:@" (video)"] : name];
    }
    if (restored) MRGDJLog(@"settings: restored %lu background picture(s) from the keychain", (unsigned long)restored);
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (missing.count) {
        NSString *note = [NSString stringWithFormat:@"Not in the backup, add again: %@.", [missing componentsJoinedByString:@", "]];
        [d setObject:note forKey:kBackupNote];
        MRGDJLog(@"settings: %@", note);
    } else [d removeObjectForKey:kBackupNote];
    return missing;
}

// Writes the settings that pass the same filter as an import; returns how many.
static NSUInteger applySaved(NSDictionary *saved) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    __block NSUInteger n = 0;
    [saved enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if ([key isKindOfClass:NSString.class] && settingsKey(key) && plistValue(obj)) { [d setObject:obj forKey:key]; n++; }
    }];
    return n;
}

static NSDictionary *sLastSaved;   // touched on sSaveQueue only
static BOOL sSaveQueued;           // main thread only
static NSString *const kPresent = @"mirage.saver.present";

// The autosave runs on its own serial queue: reading every default (dictionaryRepresentation is all of Spotify's
// preferences, not only Mirage's) and writing the file never happen on the main thread.
static dispatch_queue_t saveQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("mirage.autosave", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0)); });
    return q;
}

static void autosaveOnQueue(void) {
    @try {
        NSDictionary *prefs = currentPrefs();
        if (!prefs.count || [prefs isEqualToDictionary:sLastSaved ?: @{}]) return;
        BOOL file = [prefs writeToURL:autosaveURL() atomically:YES];
        BOOL keychain = backupWrite(prefs);
        @try { backupFilesOnQueue(); } @catch (NSException *e) { MRGDJLog(@"settings: background backup threw %@", e.reason); }
        if (file) sLastSaved = prefs;   // a refused keychain write is retried with the next change, not in a loop
        (void)keychain;
        if (![NSUserDefaults.standardUserDefaults boolForKey:kPresent]) [NSUserDefaults.standardUserDefaults setBool:YES forKey:kPresent];
    } @catch (NSException *e) {
        MRGDJLog(@"settings: autosave threw %@", e.reason);
    }
}

// Leaving the screen: saved now (on the queue), with a little background time so the write finishes.
static void autosaveNow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    __block UIBackgroundTaskIdentifier task = [app beginBackgroundTaskWithName:@"mirage.autosave" expirationHandler:^{
        [app endBackgroundTask:task];
        task = UIBackgroundTaskInvalid;
    }];
    dispatch_async(saveQueue(), ^{
        autosaveOnQueue();
        dispatch_async(dispatch_get_main_queue(), ^{ if (task != UIBackgroundTaskInvalid) { [app endBackgroundTask:task]; task = UIBackgroundTaskInvalid; } });
    });
}

// After a change: once things have been quiet for two seconds.
static void autosaveSoon(void) {
    if (sSaveQueued) return;
    sSaveQueued = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        sSaveQueued = NO;
        dispatch_async(saveQueue(), ^{ autosaveOnQueue(); });
    });
}

// Runs at load, before the add-ons start, so it has to be cheap: once an autosave has been made (kPresent is set)
// the settings are known to be there and nothing else is read. With no marker and no Mirage settings in the defaults
// (a reinstall), the autosave file is loaded, or if there is none, the keychain backup. The log says which.
static void autosaveRestore(void) {
    @try {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        if ([d boolForKey:kPresent]) return;
        if (currentPrefs().count) { [d setBool:YES forKey:kPresent]; return; }   // settings are there: nothing to bring back
        NSURL *url = autosaveURL();
        NSDictionary *saved = [NSFileManager.defaultManager fileExistsAtPath:url.path] ? [NSDictionary dictionaryWithContentsOfURL:url] : nil;
        NSString *from = @"the autosave";
        if (![saved isKindOfClass:NSDictionary.class] || !saved.count) {
            NSDate *when = nil;
            saved = backupRead(&when);
            from = when ? [NSString stringWithFormat:@"the keychain backup of %@", when] : @"the keychain backup";
        }
        if (![saved isKindOfClass:NSDictionary.class] || !saved.count) {
            MRGDJLog(@"settings: no Mirage settings, no autosave and no keychain backup; starting fresh");
            return;
        }
        NSUInteger n = applySaved(saved);
        [d setBool:YES forKey:kPresent];
        MRGDJLog(@"settings: restored %lu settings from %@", (unsigned long)n, from);
        // The pictures the settings point at, then (on the first main turn, before Home shows) the theme and a repaint.
        @try { restoreFiles(); } @catch (NSException *e) { MRGDJLog(@"settings: background restore threw %@", e.reason); }
        dispatch_async(dispatch_get_main_queue(), ^{ MRGThemeRestoreFiles(); MRGPostChange(); });
    } @catch (NSException *e) {
        MRGDJLog(@"settings: autosave restore threw %@", e.reason);
    }
}

NSString *MRGSettingsBackupSummary(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *err = [d stringForKey:kBackupError];
    if (err.length) return [@"Keychain · not saved: " stringByAppendingString:err];
    NSString *note = [d stringForKey:kBackupNote];
    double at = [d doubleForKey:kBackupAt];
    if (at <= 0) return @"Keychain · not saved yet";
    static NSDateFormatter *f;
    if (!f) { f = [NSDateFormatter new]; f.dateStyle = NSDateFormatterShortStyle; f.timeStyle = NSDateFormatterShortStyle; f.doesRelativeDateFormatting = YES; }
    NSString *line = [@"Keychain · last saved " stringByAppendingString:[f stringFromDate:[NSDate dateWithTimeIntervalSince1970:at]]];
    return note.length ? [NSString stringWithFormat:@"%@\n%@", line, note] : line;
}

void MRGSettingsRestoreBackup(void (^done)(NSUInteger restored, NSString *error)) {
    dispatch_async(saveQueue(), ^{
        NSDictionary *saved = nil;
        @try { saved = backupRead(NULL); } @catch (NSException *e) { saved = nil; }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!saved.count) { if (done) done(0, @"There's no settings backup in the keychain for this install."); return; }
            NSUInteger n = 0;
            NSMutableDictionary *was = [NSMutableDictionary dictionary];
            for (id<MRGAddon> addon in MRGRegisteredAddons()) was[addon.addonID] = @(MRGAddonInstalled(addon.addonID));
            @try { n = applySaved(saved); } @catch (NSException *e) { if (done) done(0, e.reason ?: @"The backup couldn't be applied."); return; }
            dispatch_async(saveQueue(), ^{ sLastSaved = nil; });
            MRGDJLog(@"settings: restored %lu settings from the keychain backup (by hand)", (unsigned long)n);
            // 0.6.7: applied, not only written: the background pictures, add-ons started or stopped as the backup has
            // them, the theme read again and repainted, then every screen told.
            @try { restoreFiles(); } @catch (NSException *e) {}
            for (id<MRGAddon> addon in MRGRegisteredAddons()) {
                BOOL now = MRGAddonInstalled(addon.addonID);
                if (now == [was[addon.addonID] boolValue]) continue;
                if (now) MRGAddonRunEnable(addon.addonID); else MRGAddonRunDisable(addon.addonID);
            }
            MRGThemeRestoreFiles();
            MRGPostChange();
            if (done) done(n, nil);
        });
    });
}

__attribute__((constructor)) static void mrgAutosaveConstructor(void) {
    // Before the add-ons start (they start on the main queue's first turn).
    autosaveRestore();
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:MRGSettingsChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { autosaveSoon(); }];
    // Setters that don't announce themselves (the DJ's voice sliders, its persona) are saved when Spotify leaves the
    // screen. (0.6.1-0.6.3 also listened to NSUserDefaultsDidChangeNotification, which Spotify posts all the time.)
    for (NSString *name in @[UIApplicationWillResignActiveNotification, UIApplicationDidEnterBackgroundNotification])
        [nc addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { autosaveNow(); }];
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
    if (s == 0) return self.note ?: @"Saved automatically. API keys are never exported.";
    if (s == 2) return nil;
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
- (void)include:(UISwitch *)sw { [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:kInclude]; MRGPostChange(); }
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
