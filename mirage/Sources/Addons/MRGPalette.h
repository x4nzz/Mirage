// Cover palettes (0.6.7): a cover's dominant and vibrant colors, and text that stays readable on them.
// Shared by Dynamic colors and Pop-up lyrics. Core Graphics only, so extraction runs off the main thread.
#import <UIKit/UIKit.h>

typedef struct {
    NSInteger dominant;   // the color covering the most of the cover (0xRRGGBB), -1 when none
    NSInteger vibrant;    // the most colorful color with real coverage, -1 when the cover is gray
} MRGPalette;

MRGPalette MRGPaletteFromImage(UIImage *image);
// The vibrant color, else the dominant one, lifted until it reads on Spotify's near-black (contrast at least 3:1).
NSInteger MRGPaletteAccent(MRGPalette palette);
// WCAG relative luminance and contrast.
double MRGLuminance(NSInteger rgb);
double MRGContrast(NSInteger a, NSInteger b);
// The playing song's palette: cached per track (memory), from the song's cover URL or the artwork Vitrine shows.
// `done` runs on the main queue; a palette with both -1 when no cover could be read.
void MRGPaletteForNowPlaying(void (^done)(NSString *uri, MRGPalette palette));
// The last palette MRGPaletteForNowPlaying finished, for `uri`, or NO.
BOOL MRGPaletteCached(NSString *uri, MRGPalette *out);
