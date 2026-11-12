// Themes are data only: colors, an accent, a glass tint, an optional background reference.
// Nothing in a theme is loaded as code. MRGLookLiveRGB is what Mirage's accent follows while a
// theme (or, later, dynamic colors) is in effect; -1 leaves Vitrine's own accent alone.
#import <UIKit/UIKit.h>

NSInteger MRGLookLiveRGB(void);
UIColor *MRGLookGlassTint(void);          // nil when nothing is tinting the glass
BOOL MRGThemeAllowsDynamicColors(void);   // YES when no theme is on, or the theme says dynamic colors may override it
NSDictionary *MRGAppliedTheme(void);      // the validated theme dictionary, or nil

// Dynamic colors registers this. The block returns an 0xRRGGBB to use instead of the theme, or -1 to leave the theme.
void MRGLookSetDynamicRGB(NSInteger (^block)(void));
void MRGLookRefresh(void);
