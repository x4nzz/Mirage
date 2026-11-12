#import "MRGIntegrity.h"
#import "MRGDJLog.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>
#import <os/log.h>

static const struct mach_header_64 *ownHeader(void) {
    Dl_info info;
    if (dladdr((const void *)&MRGImagePath, &info) && info.dli_fbase) return (const struct mach_header_64 *)info.dli_fbase;
    return NULL;
}

static NSString *ownFullPath(void) {
    Dl_info info;
    if (dladdr((const void *)&MRGImagePath, &info) && info.dli_fname) return @(info.dli_fname);
    return nil;
}

static NSString *shortPath(NSString *full) {
    if (!full.length) return @"unknown";
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    if (bundle.length && [full hasPrefix:bundle]) return [bundle.lastPathComponent stringByAppendingString:[full substringFromIndex:bundle.length]];
    NSString *home = NSHomeDirectory();
    if (home.length && [full hasPrefix:home]) return [@"~" stringByAppendingString:[full substringFromIndex:home.length]];
    return full;
}

NSString *MRGImagePath(void) { return shortPath(ownFullPath()); }

NSString *MRGImageUUID(void) {
    const struct mach_header_64 *h = ownHeader();
    if (!h || h->magic != MH_MAGIC_64) return nil;
    const uint8_t *p = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_UUID) return [[NSUUID alloc] initWithUUIDBytes:((const struct uuid_command *)lc)->uuid].UUIDString;
        p += lc->cmdsize;
    }
    return nil;
}

// The highest "x.y.z" in an image's C strings: Mirage's own version is the newest one it mentions (the others
// are add-on minimums), so this reads an old copy's version without any help from it.
static NSString *guessVersion(const struct mach_header_64 *h) {
    unsigned long size = 0;
    const char *s = (const char *)getsectiondata(h, "__TEXT", "__cstring", &size);
    if (!s || !size) return nil;
    NSInteger best[3] = {-1, -1, -1};
    const char *end = s + size;
    while (s < end) {
        size_t n = strnlen(s, end - s);
        int a, b, c; char tail;
        if (n >= 5 && n <= 8 && sscanf(s, "%d.%d.%d%c", &a, &b, &c, &tail) == 3 && a == 0) {
            if (a > best[0] || (a == best[0] && (b > best[1] || (b == best[1] && c > best[2])))) { best[0] = a; best[1] = b; best[2] = c; }
        }
        s += n + 1;
    }
    return best[0] < 0 ? nil : [NSString stringWithFormat:@"%ld.%ld.%ld", (long)best[0], (long)best[1], (long)best[2]];
}

static NSArray<NSDictionary *> *sOthers;

static NSArray<NSDictionary *> *scan(void) {
    NSMutableArray *out = [NSMutableArray array];
    const struct mach_header_64 *me = ownHeader();
    NSString *mine = ownFullPath();
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(i);
        const char *name = _dyld_get_image_name(i);
        if (!h || !name || h == me) continue;
        NSString *path = @(name);
        if ([path hasPrefix:@"/System/"] || [path hasPrefix:@"/usr/lib/"]) continue;
        if (mine && [path isEqualToString:mine]) continue;
        BOOL classes = NO;
        unsigned int n = 0;
        const char **names = objc_copyClassNamesForImage(name, &n);
        for (unsigned int k = 0; k < n && !classes; k++)
            if (!strcmp(names[k], "MRGSettingsController") || !strcmp(names[k], "MRGDrawerRow")) classes = YES;
        free(names);
        // Mirage's classes, whatever the file is called; a file only named like Mirage is not a second copy.
        if (!classes) continue;
        NSMutableDictionary *d = [@{@"path": shortPath(path)} mutableCopy];
        NSString *v = h->magic == MH_MAGIC_64 ? guessVersion(h) : nil;
        if (v) d[@"version"] = v;
        [out addObject:d];
    }
    return out;
}

NSArray<NSDictionary *> *MRGOtherMirageImages(void) {
    if (!sOthers) sOthers = scan();
    return sOthers;
}

NSString *MRGDuplicateSummary(void) {
    NSArray *others = MRGOtherMirageImages();
    if (!others.count) return nil;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *d in others) [parts addObject:d[@"version"] ? [NSString stringWithFormat:@"%@ (Mirage %@)", d[@"path"], d[@"version"]] : d[@"path"]];
    return [parts componentsJoinedByString:@", "];
}

static UIViewController *topController(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (!w.isKeyWindow) continue;
            UIViewController *top = w.rootViewController;
            while (top.presentedViewController) top = top.presentedViewController;
            return top;
        }
    }
    return nil;
}

// Once per launch at most, and only when there really is another copy: it explains why the app may look like an
// older Mirage, and which file to remove.
static void warnIfDuplicate(int attempt) {
    NSString *dup = MRGDuplicateSummary();
    if (!dup) return;
    UIViewController *top = topController();
    if (!top) {
        if (attempt < 10) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ warnIfDuplicate(attempt + 1); });
        return;
    }
    NSString *msg = [NSString stringWithFormat:@"This is Mirage %@, loaded from %@. Another copy of Mirage is loaded too: %@.\n\nBoth run at once and the older one can show its own settings. Remove the other copy (an injected Mirage.dylib or .deb in your signer's tweaks, or a tweak folder) and install the IPA alone.", MRGVersionLine(), MRGImagePath(), dup];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Two copies of Mirage" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:a animated:YES completion:nil];
}

__attribute__((constructor)) static void mrgIntegrityConstructor(void) {
    @autoreleasepool {
        os_log(OS_LOG_DEFAULT, "Mirage %{public}s image %{public}s uuid %{public}s", MRG_VERSION, ownFullPath().UTF8String ?: "?", MRGImageUUID().UTF8String ?: "?");
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try {
                    sOthers = scan();
                    MRGDJLog(@"Mirage %@ running from %@ (%@)", MRGVersionLine(), MRGImagePath(), MRGImageUUID() ?: @"no uuid");
                    NSString *dup = MRGDuplicateSummary();
                    if (dup) {
                        MRGDJLog(@"WARNING: another Mirage is loaded: %@", dup);
                        os_log(OS_LOG_DEFAULT, "Mirage: another copy is loaded: %{public}s", dup.UTF8String);
                    }
                    warnIfDuplicate(0);
                } @catch (NSException *e) {}
            });
        }];
    }
}
