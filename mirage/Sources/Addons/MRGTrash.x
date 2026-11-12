// Trash actions: a button on Now Playing, and a row in Spotify's track menu when the menu is about a track.
#import "Addons/MRGTrash.h"
#import "MRGAddons.h"
#import "MRGPlayer.h"
#import "MRGDJLog.h"
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

static void placeButton(UIView *root) {
    if (!root) return;
    UIButton *button = objc_getAssociatedObject(root, &kButtonKey);
    BOOL show = MRGAddonInstalled(kAddon) && MRGNowPlaying()[@"uri"] != nil;
    if (!show) { button.hidden = YES; return; }
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setImage:[UIImage systemImageNamed:@"trash"] forState:UIControlStateNormal];
        button.tintColor = UIColor.whiteColor;
        button.accessibilityLabel = @"Move to trash";
        button.frame = CGRectMake(0, 0, 36, 36);
        [button addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            NSDictionary *now = MRGNowPlaying();
            if (now) trashTrack(now);
        }] forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(root, &kButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (button.superview != root) [root addSubview:button];
    button.hidden = NO;
    CGFloat top = root.safeAreaInsets.top + 8;
    button.center = CGPointMake(28, top + 18);
}

%group MRGTrashPlayer
%hook _TtC20NowPlaying_ModesImpl18HeaderElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *view = ((UIViewController *)self).viewIfLoaded;
    if (view) placeButton(view);
}
%end
%end

%group MRGTrashMenu
%hook _TtC24ContextMenu_InternalImpl25ContextMenuViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!MRGAddonInstalled(kAddon)) return;
    UIViewController *menu = (UIViewController *)self;
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
        else trashTrack(@{@"uri": kept, @"title": now[@"title"] ?: @"", @"artist": now[@"artist"] ?: @""});
        [menu dismissViewControllerAnimated:YES completion:nil];
    }] forControlEvents:UIControlEventTouchUpInside];
    if (!table.tableHeaderView || table.tableHeaderView.bounds.size.height < 1) table.tableHeaderView = button;
    else table.tableFooterView = button;
    objc_setAssociatedObject(menu, &kButtonKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
%end
%end

%ctor {
    if (NSClassFromString(@"_TtC20NowPlaying_ModesImpl18HeaderElementsUnit")) %init(MRGTrashPlayer);
    if (NSClassFromString(@"_TtC24ContextMenu_InternalImpl25ContextMenuViewController")) %init(MRGTrashMenu);
}
