// Trash actions: a button on Now Playing, and a row in Spotify's track menu when the menu is about a track.
#import "Addons/MRGTrash.h"
#import "MRGAddons.h"
#import "MRGPlayer.h"
#import "MRGDJLog.h"
#import "MRGPrefs.h"
#import <objc/runtime.h>

static NSString *const kAddon = @"trash";
static char kButtonKey;

static NSString *trackURIString(NSString *text) {
    NSRange r = [text rangeOfString:@"spotify:track:"];
    if (r.location == NSNotFound) return nil;
    NSString *rest = [text substringFromIndex:r.location];
    NSCharacterSet *stop = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:_"] invertedSet];
    NSRange end = [rest rangeOfCharacterFromSet:stop];
    NSString *uri = end.location == NSNotFound ? rest : [rest substringToIndex:end.location];
    return [uri hasPrefix:@"spotify:track:"] && uri.length > @"spotify:track:".length ? uri : nil;
}

static NSString *uriInObject(id obj, int depth) {
    if (!obj || depth > 2) return nil;
    if ([obj isKindOfClass:NSString.class]) return trackURIString(obj);
    if ([obj isKindOfClass:NSURL.class]) return trackURIString([(NSURL *)obj absoluteString]);
    if ([obj isKindOfClass:NSArray.class]) {
        for (id item in obj) { NSString *u = uriInObject(item, depth + 1); if (u) return u; }
        return nil;
    }
    if ([obj isKindOfClass:NSDictionary.class]) {
        for (id item in [obj allValues]) { NSString *u = uriInObject(item, depth + 1); if (u) return u; }
        return nil;
    }
    if ([obj isKindOfClass:UIView.class]) return nil;
    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList([obj class], &n);
    NSString *found = nil;
    for (unsigned int i = 0; i < n && !found; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        if (!type || type[0] != '@') continue;
        @try {
            id value = object_getIvar(obj, ivars[i]);
            found = uriInObject(value, depth + 1);
        } @catch (NSException *e) {}
    }
    free(ivars);
    return found;
}

static void trashTrack(NSDictionary *track) {
    if (![track[@"uri"] hasPrefix:@"spotify:track:"]) return;
    MRGTrashAdd(track);
    if ([MRGNowPlaying()[@"uri"] isEqualToString:track[@"uri"]]) MRGPlayerControl(@"next", nil);
}

static NSHashTable<UIView *> *sHosts;

// Spotify's header row on Now Playing: ⌄  title  ⋯ (a horizontal stack with at least three views).
static UIStackView *headerRow(UIView *host) {
    NSMutableArray *stack = [NSMutableArray arrayWithObject:host];
    NSUInteger seen = 0;
    while (stack.count && seen < 400) {
        UIView *v = stack.firstObject; [stack removeObjectAtIndex:0]; seen++;
        if ([v isKindOfClass:UIStackView.class] && ((UIStackView *)v).axis == UILayoutConstraintAxisHorizontal && ((UIStackView *)v).arrangedSubviews.count >= 3) return (UIStackView *)v;
        [stack addObjectsFromArray:v.subviews];
    }
    return nil;
}

// 0.6.0 put the button at a fixed spot (28, 26) in the header unit, right on top of Spotify's ⌄ minimize button
// (48×48 at x 12), so it hid the chevron and took its taps. It now sits beside the ⌄, outside the stack's arranged
// views (so Spotify's own spacing stays), the title capped so it never runs under it.
static void placeButton(UIView *root) {
    if (!root) return;
    if (!sHosts) sHosts = [NSHashTable weakObjectsHashTable];
    [sHosts addObject:root];
    UIButton *button = objc_getAssociatedObject(root, &kButtonKey);
    BOOL show = MRGAddonInstalled(kAddon) && MRGNowPlaying()[@"uri"] != nil;
    if (!show) { button.hidden = YES; return; }
    // The row is found once per header and remembered (the search walks up to 400 views and this runs on every
    // layout of the player's header).
    UIStackView *row = (UIStackView *)button.superview;
    if (![row isKindOfClass:UIStackView.class] || ![row isDescendantOfView:root]) row = headerRow(root);
    UIView *minimize = row.arrangedSubviews.firstObject;
    if (!row || !minimize) { button.hidden = YES; return; }
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        UIImageSymbolConfiguration *conf = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
        [button setImage:[UIImage systemImageNamed:@"trash" withConfiguration:conf] forState:UIControlStateNormal];
        button.tintColor = UIColor.whiteColor;
        button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
        button.accessibilityLabel = @"Move to trash";
        button.translatesAutoresizingMaskIntoConstraints = NO;
        [button addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            NSDictionary *now = MRGNowPlaying();
            if (!now) return;
            [[UIImpactFeedbackGenerator new] impactOccurred];
            trashTrack(now);
        }] forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(root, &kButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (button.superview != row) {
        [button removeFromSuperview];
        [row addSubview:button];
        CGFloat side = 36;
        button.layer.cornerRadius = side / 2;
        [NSLayoutConstraint activateConstraints:@[
            [button.leadingAnchor constraintEqualToAnchor:minimize.trailingAnchor constant:6],
            [button.centerYAnchor constraintEqualToAnchor:minimize.centerYAnchor],
            [button.widthAnchor constraintEqualToConstant:side],
            [button.heightAnchor constraintEqualToConstant:side],
        ]];
        if (row.arrangedSubviews.count >= 3) {
            UIView *title = row.arrangedSubviews[row.arrangedSubviews.count / 2];
            NSLayoutConstraint *cap = [title.widthAnchor constraintLessThanOrEqualToAnchor:row.widthAnchor constant:-2 * (48 + 6 + side + 8)];
            cap.priority = UILayoutPriorityRequired - 1;
            cap.active = YES;
        }
    }
    button.hidden = minimize.hidden || minimize.alpha < 0.01;
}

%group MRGTrashPlayer
%hook _TtC20NowPlaying_ModesImpl18HeaderElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *view = ((UIViewController *)self).viewIfLoaded;
    @try { if (view) placeButton(view); } @catch (NSException *e) { MRGDJLog(@"trash: button threw %@", e.reason); }
}
%end
%end

static void addMenuRow(UIViewController *menu) {
    if (!MRGAddonInstalled(kAddon)) return;
    if (objc_getAssociatedObject(menu, &kButtonKey)) return;
    NSString *uri = uriInObject(menu, 0);
    NSDictionary *now = MRGNowPlaying();
    if (!uri && [now[@"title"] isKindOfClass:NSString.class]) {
        // The player's own menu names the song that's on.
        NSMutableArray *stack = [NSMutableArray arrayWithObject:menu.view];
        NSUInteger seen = 0;
        while (stack.count && seen < 200 && !uri) {
            UIView *view = stack.lastObject; [stack removeLastObject]; seen++;
            if ([view isKindOfClass:UILabel.class] && [((UILabel *)view).text isEqualToString:now[@"title"]]) uri = now[@"uri"];
            [stack addObjectsFromArray:view.subviews];
        }
    }
    if (![uri hasPrefix:@"spotify:track:"]) return;
    UITableView *table = nil;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:menu.view];
    while (stack.count && !table) {
        UIView *view = stack.lastObject; [stack removeLastObject];
        if ([view isKindOfClass:UITableView.class]) table = (UITableView *)view;
        else [stack addObjectsFromArray:view.subviews];
    }
    if (!table || (table.tableFooterView && table.tableFooterView.bounds.size.height > 1 && table.tableHeaderView && table.tableHeaderView.bounds.size.height > 1)) return;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:(MRGTrashContains(uri) ? @"Restore from trash" : @"Move to trash") forState:UIControlStateNormal];
    [button setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
    button.frame = CGRectMake(0, 0, table.bounds.size.width, 52);
    NSString *kept = [uri copy];
    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        if (MRGTrashContains(kept)) MRGTrashRestore(kept);
        // The playing song's name only when the menu is about the playing song; any other track gets its name
        // looked up by the trash list (0.6.0 saved the playing song's name for whichever track was trashed).
        else if ([kept isEqualToString:now[@"uri"]]) trashTrack(@{@"uri": kept, @"title": now[@"title"] ?: @"", @"artist": now[@"artist"] ?: @""});
        else trashTrack(@{@"uri": kept});
        [menu dismissViewControllerAnimated:YES completion:nil];
    }] forControlEvents:UIControlEventTouchUpInside];
    if (!table.tableHeaderView || table.tableHeaderView.bounds.size.height < 1) table.tableHeaderView = button;
    else table.tableFooterView = button;
    objc_setAssociatedObject(menu, &kButtonKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%group MRGTrashMenu
%hook _TtC24ContextMenu_InternalImpl25ContextMenuViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    @try { addMenuRow((UIViewController *)self); } @catch (NSException *e) { MRGDJLog(@"trash: menu row threw %@", e.reason); }
}
%end
%end

%ctor {
    if (NSClassFromString(@"_TtC20NowPlaying_ModesImpl18HeaderElementsUnit")) {
        %init(MRGTrashPlayer);
        // Turning Trash on or off shows or hides the button now, not on the next layout.
        [NSNotificationCenter.defaultCenter addObserverForName:MRGSettingsChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            @try { for (UIView *v in sHosts.allObjects) placeButton(v); } @catch (NSException *e) {}
        }];
    }
    if (NSClassFromString(@"_TtC24ContextMenu_InternalImpl25ContextMenuViewController")) %init(MRGTrashMenu);
}
