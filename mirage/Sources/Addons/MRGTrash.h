#import <UIKit/UIKit.h>
// Songs the listener trashed, kept on this phone. An installed Trash add-on skips them.
BOOL MRGTrashContains(NSString *uri);
void MRGTrashAdd(NSDictionary *track);          // uri, title, artist
void MRGTrashRestore(NSString *uri);
NSArray<NSDictionary *> *MRGTrashAll(void);
UIViewController *MRGTrashPage(void);
// Spotify's track context menu: the track it's about (nil when it isn't about one) and its list.
NSString *MRGContextMenuTrackURI(UIViewController *menu);
UITableView *MRGContextMenuTable(UIViewController *menu);
