// Which Mirage is running, and whether another copy of Mirage is loaded in the same app.
//
// Mirage is one dylib (Frameworks/Mirage.dylib in the IPA). If a second copy gets in (a signer that injects an
// old Mirage.dylib or .deb again, a tweak folder, a renamed copy), both copies register the same MRG classes and
// hook the same methods, and the older one can end up drawing the settings page, so the phone looks like the old
// version even with a new IPA. This finds every other image that carries Mirage's classes or is named like
// Mirage, reports it in the log, in Settings → Mirage → About and in a one-time alert, and lets the newest copy
// own the drawer row.
#import <UIKit/UIKit.h>

NSString *MRGImagePath(void);            // this copy's file, relative to the app bundle when inside it
NSString *MRGImageUUID(void);            // LC_UUID of this copy, e.g. "1A2B3C4D-…"
// Other Mirage copies loaded in this process: @{@"path": …, @"version": … (best guess, may be missing)}.
NSArray<NSDictionary *> *MRGOtherMirageImages(void);
// A one-line description of the other copies, nil when this is the only one.
NSString *MRGDuplicateSummary(void);
