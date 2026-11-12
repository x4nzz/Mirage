#import "MRGAddons.h"
#import "MRGCompat.h"
#import "MRGPlayer.h"
#import "MRGDJLog.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

extern NSString *MRGGenreText(void);
static char kLabelKey;

static void place(UIView *root) {
    if (!root) return;
    UILabel *label = objc_getAssociatedObject(root, &kLabelKey);
    NSString *text = MRGGenreText();
    NSString *title = MRGNowPlaying()[@"title"];
    if (!text.length || !title.length || !MRGAddonInstalled(@"genres")) { label.hidden = YES; return; }
    // The title label is found once and kept (weakly) while it still shows the song; the walk of the window (up to
    // 2500 views) used to run on every layout pass of Now Playing, which lays out many times a second while it animates.
    static __weak UILabel *sTitle;
    static CFTimeInterval sLastWalk;
    UILabel *titleLabel = sTitle;
    if (!titleLabel.window || ![titleLabel.text isEqualToString:title]) {
        titleLabel = nil;
        CFTimeInterval now = CACurrentMediaTime();
        if (now - sLastWalk < 0.5) {
            // Looked very recently: try again once the half second is up, in case no other layout pass comes.
            static BOOL retry;
            if (!retry) {
                retry = YES;
                __weak UIView *weakRoot = root;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ retry = NO; [weakRoot setNeedsLayout]; });
            }
            return;
        }
        sLastWalk = now;
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
        sTitle = titleLabel;
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
    if (label.hidden) label.hidden = NO;
    if (![label.text isEqualToString:text]) label.text = text;
    CGRect titleFrame = [titleLabel convertRect:titleLabel.bounds toView:host];
    CGRect frame = CGRectMake(titleFrame.origin.x, CGRectGetMaxY(titleFrame) + 1, MAX(40, titleFrame.size.width), 18);
    if (!CGRectEqualToRect(label.frame, frame)) label.frame = frame;
}

%group MRGGenreNowPlaying
%hook _TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController
- (void)viewDidLayoutSubviews {
    %orig;
    if (!MRGAddonInstalled(@"genres")) return;
    @try { place(((UIViewController *)self).viewIfLoaded); } @catch (NSException *e) {}
}
%end
%end

%ctor {
    if (NSClassFromString(@"_TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController") && MRGFragileHooksAllowed(@"Genres")) %init(MRGGenreNowPlaying);
}
