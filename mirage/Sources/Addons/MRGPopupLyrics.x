#import "Addons/MRGPopupLyrics.h"
#import "MRGAddons.h"
#import "MRGDJLog.h"

%group MRGPopupHome
%hook _TtC19Home_FunkisPageImpl20FunkisViewController
- (void)viewDidLayoutSubviews {
    %orig;
    // Called while off too, so a shelf that was up closes its room; with no shelf and the add-on off it returns at once.
    @try { MRGPopupPlace(((UIViewController *)self).viewIfLoaded); } @catch (NSException *e) { MRGDJLog(@"pop-up lyrics: place threw %@", e.reason); }
}
%end

// The room the lyrics shelf takes, added in the setter and taken back off in the getter (see MRGShelfLayout).
// MRGShelfRoom is a class comparison for every other collection view.
%hook UICollectionView
- (void)setContentInset:(UIEdgeInsets)inset {
    CGFloat room = MRGShelfRoom(self);
    if (room > 0) inset.top += room;
    %orig(inset);
}
- (UIEdgeInsets)contentInset {
    UIEdgeInsets inset = %orig;
    CGFloat room = MRGShelfRoom(self);
    if (room > 0) inset.top -= room;
    return inset;
}
%end
%end

%ctor {
    if (NSClassFromString(@"_TtC19Home_FunkisPageImpl20FunkisViewController")) %init(MRGPopupHome);
}
