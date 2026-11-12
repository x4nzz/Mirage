// Preview art for the Add-on Shop, drawn on the phone (nothing downloaded): one picture per built-in add-on,
// in the accent color, so every card shows what that add-on does. Unknown ids get a generic add-on picture.
#import <UIKit/UIKit.h>

UIImage *MRGAddonArt(NSString *addonID, CGSize size);
BOOL MRGAddonHasArt(NSString *addonID);

// The add-on's SF Symbol, and a small app-style icon tile of it (accent gradient, white symbol) for rows and
// headers. `side` is the tile's width and height in points.
NSString *MRGAddonSymbol(NSString *addonID);
UIImage *MRGAddonIcon(NSString *addonID, CGFloat side);
