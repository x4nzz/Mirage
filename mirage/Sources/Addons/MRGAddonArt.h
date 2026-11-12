// Preview art for the Add-on Shop, one designed set compiled into Mirage (nothing downloaded): one cover per add-on,
// and a matching icon tile. Unknown ids get the generic picture. Made by scripts/mirage-art.py.
#import <UIKit/UIKit.h>

UIImage *MRGAddonArt(NSString *addonID, CGSize size);
BOOL MRGAddonHasArt(NSString *addonID);

// The add-on's SF Symbol, and its icon tile (the same design as the cover) for rows and
// headers. `side` is the tile's width and height in points.
NSString *MRGAddonSymbol(NSString *addonID);
UIImage *MRGAddonIcon(NSString *addonID, CGFloat side);
