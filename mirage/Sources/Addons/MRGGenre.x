#import "MRGAddons.h"
#import "MRGPlayer.h"
#import "MRGDJLog.h"
#import <objc/runtime.h>

extern NSString *MRGGenreText(void);
static char kLabelKey;

static void place(UIView *root) {
    if (!root) return;
    UILabel *label = objc_getAssociatedObject(root, &kLabelKey);
    NSString *text = MRGGenreText();
    NSString *title = MRGNowPlaying()[@"title"];
    if (!text.length || !title.length || !MRGAddonInstalled(@"genres")) { label.hidden = YES; return; }
    UILabel *titleLabel = nil;
    CGFloat bestSize = 0;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root.window ?: root];
    NSUInteger seen = 0;
    while (stack.count && seen < 2500) {
        UIView *view = stack.lastObject; [stack removeLastObject]; seen++;
        if ([view isKindOfClass:UILabel.class] && [((UILabel *)view).text isEqualToString:title] && view.bounds.size.width > 40) {
            CGFloat size = ((UILabel *)view).font.pointSize;
            if (size >= bestSize) { bestSize = size; titleLabel = (UILabel *)view; }
        }
        [stack addObjectsFromArray:view.subviews];
    }
    if (!titleLabel) { label.hidden = YES; return; }
    UIView *host = titleLabel.superview;
    if ([host isKindOfClass:UIStackView.class]) host = host.superview ?: host;
    if (!label) {
        label = [UILabel new];
        label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        label.textColor = [UIColor colorWithWhite:1 alpha:0.72];
        label.userInteractionEnabled = NO;
        objc_setAssociatedObject(root, &kLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (label.superview != host) [host addSubview:label];
    label.hidden = NO;
    label.text = text;
    CGRect titleFrame = [titleLabel convertRect:titleLabel.bounds toView:host];
    label.frame = CGRectMake(titleFrame.origin.x, CGRectGetMaxY(titleFrame) + 1, MAX(40, titleFrame.size.width), 18);
}

%group MRGGenreNowPlaying
%hook _TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController
- (void)viewDidLayoutSubviews {
    %orig;
    place(((UIViewController *)self).viewIfLoaded);
}
%end
%end

%ctor {
    if (NSClassFromString(@"_TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController")) %init(MRGGenreNowPlaying);
}
