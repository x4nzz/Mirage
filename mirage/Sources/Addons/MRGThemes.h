// Themes are data only: colors, an accent, a glass tint, an optional background reference.
// Nothing in a theme is loaded as code. MRGLookLiveRGB is what Mirage's accent follows while a
// theme (or, later, dynamic colors) is in effect; -1 leaves Vitrine's own accent alone.
#import <UIKit/UIKit.h>

NSInteger MRGLookLiveRGB(void);
UIColor *MRGLookGlassTint(void);          // nil when nothing is tinting the glass
BOOL MRGThemeAllowsDynamicColors(void);   // YES when no theme is on, or the theme says dynamic colors may override it
NSDictionary *MRGAppliedTheme(void);      // the validated theme dictionary, or nil

// Dynamic colors registers these. A block returns an 0xRRGGBB, or -1 / nil to leave the theme alone.
void MRGLookSetDynamicRGB(NSInteger (^block)(void));
void MRGLookSetSwitchRGB(NSInteger (^block)(void));
void MRGLookSetGlassTint(UIColor *(^block)(void));
void MRGLookRefresh(void);
// After settings are restored (a reinstall, the keychain backup): the applied theme read again, its generated
// background picture made again if it is missing, and everything repainted. Main thread.
void MRGThemeRestoreFiles(void);
