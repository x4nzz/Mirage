#import "MRGDiagnostics.h"
#import "MRGAddons.h"
#import "Addons/MRGAddon.h"
#import "MRGPrefs.h"
#import "MRGIntegrity.h"
#import "DJ/MRGDJLog.h"
#import "DJ/MRGPlayer.h"
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <sys/utsname.h>
#import <stdatomic.h>

static NSString *const kDisabledKey = @"mirage.safemode.disabled";   // add-on IDs safe mode turned off
static NSString *const kAtKey = @"mirage.safemode.at";               // when

static dispatch_queue_t sQueue;          // every file write
static int sFD = -1;                     // breadcrumbs.log, O_APPEND; also written from the exception handler
static NSMutableArray<NSString *> *sRing; // the last 80 lines (on sQueue)
static BOOL sSafe;
static NSString *sDir;
static NSUncaughtExceptionHandler *sPrevHandler;

static NSString *dir(void) {
    if (!sDir) {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
        sDir = [docs stringByAppendingPathComponent:@"Mirage"];
        [NSFileManager.defaultManager createDirectoryAtPath:sDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return sDir;
}
static NSString *logPath(void) { return [dir() stringByAppendingPathComponent:@"breadcrumbs.log"]; }
static NSString *countPath(void) { return [dir() stringByAppendingPathComponent:@"launch.count"]; }

#pragma mark - breadcrumbs

static void writeLine(NSString *line) {
    if (sFD < 0) return;
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (d.length) (void)write(sFD, d.bytes, d.length);
}

// Keeps the file small: past 96 KB it is rewritten with the last 80 lines.
static void trimIfLarge(void) {
    struct stat st;
    if (sFD < 0 || fstat(sFD, &st) != 0 || st.st_size < 96 * 1024) return;
    if (ftruncate(sFD, 0) != 0) return;
    writeLine(@"— trimmed —\n");
    for (NSString *l in sRing) writeLine(l);
}

void MRGCrumb(NSString *format, ...) {
    if (!format || !sQueue) return;
    va_list ap;
    va_start(ap, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    NSDate *now = [NSDate date];
    BOOL main = NSThread.isMainThread;
    dispatch_async(sQueue, ^{
        static NSDateFormatter *f;
        if (!f) { f = [NSDateFormatter new]; f.dateFormat = @"MM-dd HH:mm:ss.SSS"; f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; }
        NSString *one = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        if (one.length > 300) one = [[one substringToIndex:300] stringByAppendingString:@"…"];
        NSString *line = [NSString stringWithFormat:@"%@ %@%@\n", [f stringFromDate:now], main ? @"" : @"(bg) ", one];
        [sRing addObject:line];
        if (sRing.count > 80) [sRing removeObjectsInRange:NSMakeRange(0, sRing.count - 80)];
        writeLine(line);
        trimIfLarge();
    });
}

// Straight to the file, on the crashing thread: the queue may never run again.
static void onException(NSException *e) {
    @try {
        NSString *line = [NSString stringWithFormat:@"!! uncaught %@: %@\n   %@\n", e.name, e.reason,
                          [[e.callStackSymbols subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)12, e.callStackSymbols.count))] componentsJoinedByString:@"\n   "]];
        writeLine(line);
    } @catch (NSException *x) {}
    if (sPrevHandler) sPrevHandler(e);
}

#pragma mark - hang watch

// Pings the main queue once a second while Spotify is in front. When a ping goes unanswered for 2 s a line is
// written then (not when it recovers), so a freeze that ends in a watchdog kill still leaves its mark.
static dispatch_source_t sWatch;
static atomic_int sPending;      // seconds the current ping has gone unanswered
static atomic_int sReported;

static void startWatch(void) {
    if (sWatch) return;
    sWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(sWatch, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(sWatch, ^{
        int waited = atomic_load(&sPending);
        if (waited > 0) {
            atomic_store(&sPending, waited + 1);
            if (waited + 1 >= 2 && !atomic_load(&sReported)) {
                atomic_store(&sReported, 1);
                MRGCrumb(@"!! main thread stuck for %ds", waited + 1);
            }
            return;
        }
        atomic_store(&sPending, 1);
        dispatch_async(dispatch_get_main_queue(), ^{
            int was = atomic_exchange(&sPending, 0);
            if (atomic_exchange(&sReported, 0)) MRGCrumb(@"main thread back after ~%ds", was);
        });
    });
    dispatch_resume(sWatch);
}
static void stopWatch(void) {
    if (!sWatch) return;
    dispatch_source_cancel(sWatch);
    sWatch = nil;
    atomic_store(&sPending, 0);
    atomic_store(&sReported, 0);
}

#pragma mark - launch counter and safe mode

static int readCount(void) {
    NSString *s = [NSString stringWithContentsOfFile:countPath() encoding:NSUTF8StringEncoding error:nil];
    return MAX(0, s.intValue);
}
static void writeCount(int n) {
    [[NSString stringWithFormat:@"%d", n] writeToFile:countPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void survived(void) {
    static BOOL done;
    if (done) return;
    done = YES;
    dispatch_async(sQueue, ^{ writeCount(0); });
    MRGCrumb(@"launch survived");
}

BOOL MRGSafeModeActive(void) { return sSafe; }

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

static NSString *namesOf(NSArray<NSString *> *ids) {
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *i in ids) {
        id<MRGAddon> a = MRGAddonObject(i);
        [names addObject:a.addonName ?: i];
    }
    return [names componentsJoinedByString:@", "];
}

static void tellSafeMode(int attempt) {
    UIViewController *top = topController();
    if (!top) {
        if (attempt < 10) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ tellSafeMode(attempt + 1); });
        return;
    }
    NSArray *ids = [NSUserDefaults.standardUserDefaults stringArrayForKey:kDisabledKey];
    NSString *list = ids.count ? namesOf(ids) : @"none were on";
    NSString *msg = [NSString stringWithFormat:@"Spotify closed while starting twice in a row, so Mirage started with its add-ons off (%@).\n\nTurn them back on one at a time in Settings → Mirage to find the one at fault, or all at once here. Settings → Mirage → About → Share diagnostics has the details.", list];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Mirage safe mode" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Keep them off" style:UIAlertActionStyleCancel handler:nil]];
    if (ids.count) [a addAction:[UIAlertAction actionWithTitle:@"Turn them back on" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { MRGSafeModeRestore(); }]];
    [top presentViewController:a animated:YES completion:nil];
}

void MRGSafeModeTurnOffAddons(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSMutableArray *off = [NSMutableArray array];
    for (id<MRGAddon> addon in MRGRegisteredAddons()) {
        if (!MRGAddonInstalled(addon.addonID)) continue;
        [off addObject:addon.addonID];
        [d setBool:NO forKey:[@"mirage.addon." stringByAppendingString:addon.addonID]];
    }
    // A second safe mode in a row keeps the first list (those are the ones the user had on).
    NSArray *had = [d stringArrayForKey:kDisabledKey];
    if (!off.count && had.count) off = [had mutableCopy];
    [d setObject:off forKey:kDisabledKey];
    [d setObject:[NSDate date] forKey:kAtKey];
    MRGCrumb(@"SAFE MODE: add-ons off: %@", [off componentsJoinedByString:@","]);
    MRGDJLog(@"safe mode: two launches in a row died early; add-ons turned off: %@", [off componentsJoinedByString:@", "]);
    MRGPostChange();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ tellSafeMode(0); });
}

NSString *MRGSafeModeNote(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSDate *at = [d objectForKey:kAtKey];
    if (![at isKindOfClass:NSDate.class]) return nil;
    NSArray *ids = [d stringArrayForKey:kDisabledKey];
    NSString *when = [NSDateFormatter localizedStringFromDate:at dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];
    return [NSString stringWithFormat:@"Safe mode on %@ after two launch crashes%@%@", when, ids.count ? @" turned off: " : @"", ids.count ? namesOf(ids) : @""];
}

void MRGSafeModeRestore(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSArray *ids = [d stringArrayForKey:kDisabledKey];
    [d removeObjectForKey:kDisabledKey];
    [d removeObjectForKey:kAtKey];
    for (NSString *i in ids) {
        if (!MRGAddonObject(i)) continue;
        [d setBool:YES forKey:[@"mirage.addon." stringByAppendingString:i]];
        MRGAddonRunEnable(i);
    }
    MRGCrumb(@"safe mode: add-ons back on: %@", [ids componentsJoinedByString:@","]);
    MRGPostChange();
}

#pragma mark - share

static NSString *deviceLine(void) {
    struct utsname u;
    uname(&u);
    NSString *spotify = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    return [NSString stringWithFormat:@"%s, iOS %@, Spotify %@, Low Power Mode %@", u.machine, UIDevice.currentDevice.systemVersion, spotify,
            NSProcessInfo.processInfo.isLowPowerModeEnabled ? @"on" : @"off"];
}

// Belt and braces: the DJ log is written without keys, but anything shaped like one is masked before it leaves.
static NSString *redact(NSString *s) {
    if (!s.length) return @"";
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(sk-[A-Za-z0-9_\\-]{8,}|xai-[A-Za-z0-9_\\-]{8,}|AIza[0-9A-Za-z_\\-]{20,}|Bearer\\s+[A-Za-z0-9._\\-]+|(?i:(api[_-]?key|token|secret|authorization)\\s*[=:]\\s*)\\S+)" options:0 error:nil];
    return [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"[hidden]"] ?: s;
}

static NSString *tail(NSString *s, NSUInteger lines) {
    NSArray *all = [s componentsSeparatedByString:@"\n"];
    if (all.count <= lines) return s;
    return [[all subarrayWithRange:NSMakeRange(all.count - lines, lines)] componentsJoinedByString:@"\n"];
}

void MRGShareDiagnostics(UIViewController *from, UIView *source) {
    if (!from) return;
    NSMutableArray *on = [NSMutableArray array];
    for (id<MRGAddon> a in MRGRegisteredAddons()) if (MRGAddonInstalled(a.addonID)) [on addObject:a.addonName ?: a.addonID];
    NSMutableString *t = [NSMutableString string];
    [t appendFormat:@"Mirage %@\nImage %@ (%@)\n%@\n", MRGVersionLine(), MRGImageUUID() ?: @"?", MRGImagePath() ?: @"?", deviceLine()];
    [t appendFormat:@"Add-ons on: %@\n", on.count ? [on componentsJoinedByString:@", "] : @"none"];
    [t appendFormat:@"Safe mode: %@\n", sSafe ? @"this launch" : (MRGSafeModeNote() ?: @"no")];
    [t appendFormat:@"Other Mirage copies: %@\n", MRGDuplicateSummary() ?: @"none"];
    NSString *dj = MRGDJLogText() ?: @"";
    __weak UIViewController *weakFrom = from;
    __weak UIView *weakSource = source;
    // The file reads and the write happen on the breadcrumbs queue, after every crumb already queued.
    dispatch_async(sQueue, ^{
        NSString *crumbs = [NSString stringWithContentsOfFile:logPath() encoding:NSUTF8StringEncoding error:nil] ?: @"";
        [t appendFormat:@"\n— breadcrumbs —\n%@\n", tail(crumbs, 250)];
        [t appendFormat:@"\n— DJ log —\n%@\n", redact(tail(dj, 150))];
        NSString *path = [dir() stringByAppendingPathComponent:@"Mirage-diagnostics.txt"];
        NSArray *items = [t writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil] ? @[[NSURL fileURLWithPath:path]] : @[[t copy]];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *f = weakFrom;
            if (!f || !f.view.window || f.presentedViewController) return;
            UIView *src = weakSource ?: f.view;
            UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
            share.popoverPresentationController.sourceView = src;
            share.popoverPresentationController.sourceRect = src.bounds;
            [f presentViewController:share animated:YES completion:nil];
        });
    });
}

#pragma mark - start

__attribute__((constructor)) static void mrgDiagnosticsConstructor(void) {
    @autoreleasepool {
        sQueue = dispatch_queue_create("mirage.crumbs", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        sRing = [NSMutableArray array];
        // Two tiny files, read and written once: the only disk work Mirage does before Spotify's main().
        int unfinished = readCount();
        sSafe = unfinished >= 2;
        writeCount(unfinished + 1);
        sFD = open(logPath().fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
        MRGCrumb(@"=== launch, Mirage %s, %d unfinished launch(es) before%@", MRG_VERSION, unfinished, sSafe ? @", SAFE MODE" : @"");
        sPrevHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(&onException);

        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        NSOperationQueue *mq = NSOperationQueue.mainQueue;
        [nc addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:mq usingBlock:^(NSNotification *n) {
            MRGCrumb(@"finished launching");
            // Up in front for 10 s counts as a launch that made it.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (UIApplication.sharedApplication.applicationState != UIApplicationStateBackground) survived();
            });
        }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:mq usingBlock:^(NSNotification *n) {
            MRGCrumb(@"active");
            startWatch();
        }];
        [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:mq usingBlock:^(NSNotification *n) { stopWatch(); }];
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:mq usingBlock:^(NSNotification *n) {
            MRGCrumb(@"background");
            survived();   // leaving Spotify early is not a crash
        }];
        [nc addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:mq usingBlock:^(NSNotification *n) { MRGCrumb(@"!! memory warning"); }];
        [nc addObserverForName:NSProcessInfoPowerStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            MRGCrumb(@"low power mode %@", NSProcessInfo.processInfo.isLowPowerModeEnabled ? @"on" : @"off");
        }];
        [nc addObserverForName:MRGPlayerTrackChangedNotification object:nil queue:mq usingBlock:^(NSNotification *n) {
            NSString *uri = n.userInfo[@"uri"];
            MRGCrumb(@"track %@%@", [uri isKindOfClass:NSString.class] ? uri : @"?", [n.userInfo[@"ad"] boolValue] ? @" (ad)" : @"");
        }];
    }
}
