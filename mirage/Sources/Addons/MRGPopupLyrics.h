#import <UIKit/UIKit.h>
// Puts (or takes away) the lyrics shelf in a Home page's feed. Called from the Home page's layout.
void MRGPopupPlace(UIView *page);
void MRGShelfLayout(UICollectionView *feed, BOOL animated);
// The lyrics room on Home's feed, in points (0 for every other scroll view).
CGFloat MRGShelfRoom(UIScrollView *list);
