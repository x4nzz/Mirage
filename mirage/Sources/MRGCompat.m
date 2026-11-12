#import "MRGCompat.h"
#import "MRGDJLog.h"

static NSMutableArray<NSString *> *sHeld;
static NSObject *lock(void) { static NSObject *o; static dispatch_once_t once; dispatch_once(&once, ^{ o = [NSObject new]; }); return o; }

NSArray<NSString *> *MRGVerifiedSpotifyVersions(void) { return @[@"9.1.90"]; }

NSString *MRGSpotifyVersion(void) {
    static NSString *v;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id s = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"];
        v = [s isKindOfClass:NSString.class] && [s length] ? [s copy] : @"?";
    });
    return v;
}

BOOL MRGSpotifyVerified(void) { return [MRGVerifiedSpotifyVersions() containsObject:MRGSpotifyVersion()]; }
BOOL MRGCompatOverride(void) { return [NSUserDefaults.standardUserDefaults boolForKey:@"mirage.compat.override"]; }
void MRGCompatSetOverride(BOOL on) { [NSUserDefaults.standardUserDefaults setBool:on forKey:@"mirage.compat.override"]; }

BOOL MRGFragileHooksAllowed(NSString *name) {
    if (MRGSpotifyVerified() || MRGCompatOverride()) return YES;
    @synchronized (lock()) {
        if (!sHeld) sHeld = [NSMutableArray array];
        if (name.length && ![sHeld containsObject:name]) {
            [sHeld addObject:name];
            MRGDJLog(@"compat: Spotify %@ isn't a verified build; %@ hooks not installed (About → Run on this Spotify anyway)", MRGSpotifyVersion(), name);
        }
    }
    return NO;
}

NSArray<NSString *> *MRGFragileHooksHeldBack(void) { @synchronized (lock()) { return [sHeld copy] ?: @[]; } }

NSString *MRGCompatSummary(void) {
    if (MRGSpotifyVerified()) return [MRGSpotifyVersion() stringByAppendingString:@" · verified"];
    if (MRGCompatOverride()) return [MRGSpotifyVersion() stringByAppendingString:@" · not verified, running anyway"];
    NSUInteger n = MRGFragileHooksHeldBack().count;
    return [NSString stringWithFormat:@"%@ · not verified, %lu hook%@ off", MRGSpotifyVersion(), (unsigned long)n, n == 1 ? @"" : @"s"];
}
