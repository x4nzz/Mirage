#import "MRGPrefs.h"

NSString *const MRGSettingsChangedNotification = @"MirageSettingsChanged";

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }
// Typed: a stored value of another type (a string, an array) is ignored and the default used.
static id V(NSString *k, id def) { id v = [D() objectForKey:k]; return [v isKindOfClass:NSNumber.class] ? v : def; }

void MRGPostChange(void) {
    void (^post)(void) = ^{ [NSNotificationCenter.defaultCenter postNotificationName:MRGSettingsChangedNotification object:nil]; };
    if (NSThread.isMainThread) post(); else dispatch_async(dispatch_get_main_queue(), post);
}

BOOL MRGBackgroundEnabled(void) { return [V(@"mirage.bg.enabled", @YES) boolValue]; }
void MRGSetBackgroundEnabled(BOOL on) { [D() setBool:on forKey:@"mirage.bg.enabled"]; MRGPostChange(); }
double MRGBlur(void) { return MAX(0, MIN(1, [V(@"mirage.bg.blur", @0) doubleValue])); }
void MRGSetBlur(double v) { [D() setDouble:v forKey:@"mirage.bg.blur"]; MRGPostChange(); }
double MRGDim(void) { return MAX(0, MIN(0.9, [V(@"mirage.bg.dim", @0.35) doubleValue])); }
void MRGSetDim(double v) { [D() setDouble:v forKey:@"mirage.bg.dim"]; MRGPostChange(); }
MRGScaleMode MRGScale(void) { NSInteger m = [V(@"mirage.bg.scale", @0) integerValue]; return (m >= 0 && m <= 2) ? m : MRGScaleFill; }
void MRGSetScale(MRGScaleMode m) { [D() setInteger:m forKey:@"mirage.bg.scale"]; MRGPostChange(); }
MRGScreen MRGScreens(void) { return [V(@"mirage.bg.screens", @(MRGScreenHome | MRGScreenLibrary)) unsignedIntegerValue]; }
void MRGSetScreens(MRGScreen s) { [D() setObject:@(s) forKey:@"mirage.bg.screens"]; MRGPostChange(); }
BOOL MRGClearPages(void) { return [V(@"mirage.bg.clearPages", @YES) boolValue]; }
void MRGSetClearPages(BOOL on) { [D() setBool:on forKey:@"mirage.bg.clearPages"]; MRGPostChange(); }
BOOL MRGProfileGlow(void) { return [V(@"mirage.profile.glow", @YES) boolValue]; }
void MRGSetProfileGlow(BOOL on) { [D() setBool:on forKey:@"mirage.profile.glow"]; MRGPostChange(); }

MRGTopFadeMode MRGTopFade(void) { NSInteger m = [V(@"mirage.bg.topFade", @1) integerValue]; return (m >= 0 && m <= 2) ? m : MRGTopFadeSoft; }
void MRGSetTopFade(MRGTopFadeMode m) { [D() setInteger:m forKey:@"mirage.bg.topFade"]; MRGPostChange(); }

BOOL MRGWantsScreen(MRGScreen s) {
    if (!MRGBackgroundEnabled() || MRGKindForScreen(s) == MRGMediaNone) return NO;
    MRGScreen on = MRGScreens();
    if (s == MRGScreenEverywhere) return (on & MRGScreenEverywhere) != 0;
    if (s == MRGScreenDrawer) return (on & MRGScreenDrawer) != 0;
    // "Everywhere" already puts one background behind every page, Home and Library included,
    // so their own hooks stand down rather than stack a second one. Now playing is not a page.
    if ((s == MRGScreenHome || s == MRGScreenLibrary) && (on & MRGScreenEverywhere)) return NO;
    return (on & s) != 0;
}

NSURL *MRGMediaDirectory(void) {
    NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [docs URLByAppendingPathComponent:@"Mirage/Backgrounds" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

MRGMediaKind MRGCurrentKind(void) {
    NSString *name = [D() stringForKey:@"mirage.bg.file"];
    if (!name.length) return MRGMediaNone;
    if (![NSFileManager.defaultManager fileExistsAtPath:[MRGMediaDirectory() URLByAppendingPathComponent:name].path]) return MRGMediaNone;
    return [D() integerForKey:@"mirage.bg.kind"];
}

NSURL *MRGCurrentMediaURL(void) {
    if (MRGCurrentKind() == MRGMediaNone) return nil;
    return [MRGMediaDirectory() URLByAppendingPathComponent:[D() stringForKey:@"mirage.bg.file"]];
}

static NSString *assignKey(MRGScreen screen) { return [NSString stringWithFormat:@"mirage.bg.assign.%lu", (unsigned long)screen]; }

static NSMutableArray<NSDictionary *> *libraryItems(void) {
    static BOOL ready;
    NSMutableArray *items = [NSMutableArray array];
    for (id item in [D() arrayForKey:@"mirage.bg.library"]) if ([item isKindOfClass:NSDictionary.class]) [items addObject:[item mutableCopy]];
    if (!ready && ![D() objectForKey:@"mirage.bg.library"]) {
        NSString *file = [D() stringForKey:@"mirage.bg.file"];
        NSURL *url = file.length ? [MRGMediaDirectory() URLByAppendingPathComponent:file] : nil;
        if (url && [NSFileManager.defaultManager fileExistsAtPath:url.path]) {
            NSString *itemID = NSUUID.UUID.UUIDString;
            [items addObject:[@{@"id": itemID, @"name": file.stringByDeletingPathExtension, @"file": file, @"kind": @([D() integerForKey:@"mirage.bg.kind"])} mutableCopy]];
            [D() setObject:itemID forKey:@"mirage.bg.active"];
        }
        [D() setObject:items forKey:@"mirage.bg.library"];
    }
    ready = YES;
    return items;
}

static void saveLibrary(NSArray *items) { [D() setObject:items forKey:@"mirage.bg.library"]; }

static NSDictionary *itemForID(NSString *itemID) {
    if (!itemID.length) return nil;
    for (NSDictionary *item in libraryItems()) if ([item[@"id"] isEqualToString:itemID]) return item;
    return nil;
}

static void pointActiveAt(NSDictionary *item) {
    if (!item) {
        [D() removeObjectForKey:@"mirage.bg.file"];
        [D() setInteger:MRGMediaNone forKey:@"mirage.bg.kind"];
        [D() removeObjectForKey:@"mirage.bg.active"];
        return;
    }
    [D() setObject:item[@"id"] forKey:@"mirage.bg.active"];
    [D() setObject:item[@"file"] forKey:@"mirage.bg.file"];
    [D() setInteger:[item[@"kind"] integerValue] forKey:@"mirage.bg.kind"];
}

NSArray<NSDictionary *> *MRGBackgroundLibrary(void) { return libraryItems(); }
NSString *MRGBackgroundActiveID(void) { libraryItems(); return [D() stringForKey:@"mirage.bg.active"]; }

void MRGBackgroundSetActive(NSString *itemID) {
    NSDictionary *item = itemForID(itemID);
    if (!item) return;
    pointActiveAt(item);
    MRGPostChange();
}

void MRGBackgroundDelete(NSString *itemID) {
    NSMutableArray *items = libraryItems();
    NSDictionary *found = nil;
    for (NSDictionary *item in items) if ([item[@"id"] isEqualToString:itemID]) found = item;
    if (!found) return;
    [items removeObject:found];
    saveLibrary(items);
    if (found[@"file"]) [NSFileManager.defaultManager removeItemAtURL:[MRGMediaDirectory() URLByAppendingPathComponent:found[@"file"]] error:nil];
    for (MRGScreen screen = MRGScreenHome; screen <= MRGScreenDrawer; screen <<= 1)
        if ([[D() stringForKey:assignKey(screen)] isEqualToString:itemID]) [D() removeObjectForKey:assignKey(screen)];
    if ([[D() stringForKey:@"mirage.bg.active"] isEqualToString:itemID]) pointActiveAt(items.firstObject);
    MRGPostChange();
}

void MRGBackgroundRename(NSString *itemID, NSString *name) {
    if (!name.length) return;
    NSMutableArray *items = libraryItems();
    for (NSMutableDictionary *item in items) if ([item[@"id"] isEqualToString:itemID]) item[@"name"] = name;
    saveLibrary(items);
    MRGPostChange();
}

NSString *MRGBackgroundAssignment(MRGScreen screen) { return [D() stringForKey:assignKey(screen)]; }

void MRGBackgroundSetAssignment(MRGScreen screen, NSString *itemID) {
    if (itemID.length && itemForID(itemID)) [D() setObject:itemID forKey:assignKey(screen)];
    else [D() removeObjectForKey:assignKey(screen)];
    MRGPostChange();
}

static NSDictionary *itemForScreen(MRGScreen screen) {
    NSDictionary *assigned = itemForID(MRGBackgroundAssignment(screen));
    if (assigned) {
        NSURL *url = [MRGMediaDirectory() URLByAppendingPathComponent:assigned[@"file"] ?: @""];
        if ([NSFileManager.defaultManager fileExistsAtPath:url.path]) return assigned;
    }
    return itemForID(MRGBackgroundActiveID());
}

NSURL *MRGMediaURLForScreen(MRGScreen screen) {
    if (screen == 0) return MRGCurrentMediaURL();
    NSDictionary *item = itemForScreen(screen);
    if (!item[@"file"]) return nil;
    NSURL *url = [MRGMediaDirectory() URLByAppendingPathComponent:item[@"file"]];
    return [NSFileManager.defaultManager fileExistsAtPath:url.path] ? url : nil;
}

MRGMediaKind MRGKindForScreen(MRGScreen screen) {
    if (screen == 0) return MRGCurrentKind();
    NSDictionary *item = itemForScreen(screen);
    if (!item) return MRGMediaNone;
    NSURL *url = [MRGMediaDirectory() URLByAppendingPathComponent:item[@"file"] ?: @""];
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) return MRGMediaNone;
    return [item[@"kind"] integerValue];
}

void MRGSetCurrentMedia(NSURL *file, MRGMediaKind kind) {
    if (!file.lastPathComponent.length) return;
    NSMutableArray *items = libraryItems();
    NSDictionary *existing = nil;
    for (NSDictionary *item in items) if ([item[@"file"] isEqualToString:file.lastPathComponent]) existing = item;
    NSString *itemID = existing[@"id"];
    if (!itemID) {
        itemID = NSUUID.UUID.UUIDString;
        [items addObject:@{@"id": itemID, @"name": file.lastPathComponent.stringByDeletingPathExtension, @"file": file.lastPathComponent, @"kind": @(kind)}];
        saveLibrary(items);
    }
    pointActiveAt(itemForID(itemID));
    MRGPostChange();
}

void MRGRemoveCurrentMedia(void) {
    NSString *active = MRGBackgroundActiveID();
    if (active) MRGBackgroundDelete(active);
    else {
        [D() removeObjectForKey:@"mirage.bg.file"];
        [D() setInteger:MRGMediaNone forKey:@"mirage.bg.kind"];
        MRGPostChange();
    }
}
