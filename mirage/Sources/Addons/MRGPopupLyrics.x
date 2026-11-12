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
%end

%ctor {
    if (NSClassFromString(@"_TtC19Home_FunkisPageImpl20FunkisViewController")) %init(MRGPopupHome);
}
