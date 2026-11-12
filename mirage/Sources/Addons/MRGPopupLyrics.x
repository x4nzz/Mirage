#import "Addons/MRGPopupLyrics.h"
#import "MRGAddons.h"

%group MRGPopupHome
%hook _TtC19Home_FunkisPageImpl20FunkisViewController
- (void)viewDidLayoutSubviews {
    %orig;
    if (!MRGAddonInstalled(@"popup-lyrics")) return;
    MRGPopupPlace(((UIViewController *)self).viewIfLoaded);
}
%end
%end

%ctor {
    if (NSClassFromString(@"_TtC19Home_FunkisPageImpl20FunkisViewController")) %init(MRGPopupHome);
}
