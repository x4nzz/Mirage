// Mirage's breadcrumbs, hang watch and launch-crash safe mode.
//
// Breadcrumbs: the last Mirage events (launch, add-ons starting, track changes, Shuffle+ queues, skips, exceptions,
// memory warnings, a stuck main thread) appended to Documents/Mirage/breadcrumbs.log as they happen, so after a
// crash or a freeze the file shows what Mirage was doing. Never keys, tokens or settings values.
//
// Safe mode: a launch that dies in its first seconds is counted in Documents/Mirage/launch.count. After two in a
// row the next launch starts with every add-on turned off, says so in an alert and in Settings → Mirage → About,
// and offers to turn them back on.
#import <UIKit/UIKit.h>

void MRGCrumb(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

BOOL MRGSafeModeActive(void);              // this launch started in safe mode
void MRGSafeModeTurnOffAddons(void);       // called once by the add-on launcher instead of starting them
NSString *MRGSafeModeNote(void);           // "Turned off on … after two launch crashes: …", nil when nothing to say
void MRGSafeModeRestore(void);             // turns the add-ons safe mode turned off back on, clears the note

// Shares a text report (version, UUID, device, add-ons on, safe mode, duplicates, breadcrumbs, DJ log).
void MRGShareDiagnostics(UIViewController *from, UIView *source);
