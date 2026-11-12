// Now Playing kit: one set of hooks on Spotify's full screen player (9.1.90's NowPlaying_ModesImpl units, the
// background and scroll controllers, the lyrics preview and the cover's tilt view) that the Now Playing add-ons
// (Focus mode, Cover ring, Lyrics backdrop, Up Next) hang their work on, instead of each hooking the same classes.
// The hooks are one fragile group ("Now Playing kit"): held back on Spotify builds Mirage hasn't been checked on.
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, MRGNowPart) {
    MRGNowHeader,       // ⌄ title ⋯ (and the DJ and Trash buttons Mirage puts there)
    MRGNowInfo,         // title, artist, like
    MRGNowDuration,     // the scrubber and its times
    MRGNowControls,     // shuffle, previous, play, next, repeat
    MRGNowFooter,       // Connect, share, queue
    MRGNowFloating,     // Spotify's floating extras
    MRGNowLyrics,       // the lyrics preview under the cover (a view, not a controller)
    MRGNowBackground,   // NPVBackgroundViewController
    MRGNowScroll,       // NPVScrollViewController (the cards under the player)
};

// Called on the main thread after Spotify lays a part out. `owner` is the unit's view controller, or the lyrics view.
typedef void (^MRGNowPartClient)(MRGNowPart part, id owner);
// Called after the player's cover (its tilt view, 200pt or more, inside the player's cover cell) lays out.
typedef void (^MRGNowCoverClient)(UIView *tilt);

void MRGNowAddPartClient(MRGNowPartClient client);
void MRGNowAddCoverClient(MRGNowCoverClient client);
BOOL MRGNowKitRunning(void);          // the hooks are in (Spotify had the classes, and the build is allowed)
void MRGNowRelayout(void);            // every client again, now, for what's on screen (after a setting changed)

UIStackView *MRGNowRowIn(UIView *root);     // a unit's row: a stack wider than 200pt holding 2 items or more
UIView *MRGNowCoverIn(UIView *tilt);        // the cover inside a tilt view: its biggest visible subview
UIImage *MRGNowCoverImage(UIView *tilt);    // the biggest image showing in it
UIColor *MRGNowVividColor(UIImage *image);  // the image's average color, pushed to stay colorful and visible on black
BOOL MRGNowClassNamed(id obj, NSString *part);

// Hiding Spotify's own views, kept reversible: the view's alpha and touch handling are saved the first time.
BOOL MRGNowHide(UIView *view, NSString *owner);   // owner: who hid it ("focus"), so each add-on restores its own
void MRGNowRestoreAll(NSString *owner);
