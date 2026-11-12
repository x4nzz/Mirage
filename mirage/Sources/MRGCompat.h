// Which Spotify builds Mirage has been checked on, and the switch for its fragile hooks.
//
// A fragile hook is one that changes the layout of a Swift view or sheet Spotify renames or rebuilds between
// versions (Now Playing's units and cover, the listening modes sheet, the track menu). On a build that isn't in
// MRGVerifiedSpotifyVersions() they are not installed, so an unknown Spotify opens stock instead of half-styled or
// crashing; Settings → Mirage → About → "Run on this Spotify anyway" turns them back on (from the next launch).
// Everything else (settings, the DJ, backgrounds, history) keeps running. docs/mirage/COMPATIBILITY.md lists the
// builds and the hooks.
#import <Foundation/Foundation.h>

NSArray<NSString *> *MRGVerifiedSpotifyVersions(void);   // "9.1.90"
NSString *MRGSpotifyVersion(void);                        // CFBundleShortVersionString of the running Spotify
BOOL MRGSpotifyVerified(void);
BOOL MRGCompatOverride(void);                             // mirage.compat.override
void MRGCompatSetOverride(BOOL on);
// YES on a verified build or with the override on. `name` is logged once when a hook is held back.
BOOL MRGFragileHooksAllowed(NSString *name);
NSArray<NSString *> *MRGFragileHooksHeldBack(void);       // the names held back this launch
NSString *MRGCompatSummary(void);                         // "9.1.90 · verified" / "9.2.4 · not verified, 6 hooks off"
