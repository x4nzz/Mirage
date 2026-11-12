#import "Addons/MRGThemes.h"
#import "Addons/MRGAddon.h"
#import "MRGAddons.h"
#import "MRGPrefs.h"
#import "MRGSafe.h"
#import "MRGDJLog.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kRemoteURL = @"https://raw.githubusercontent.com/x4nzz/Mirage/main/addons/themes/catalog.json";
static NSString *const kBundled = @"ewogICJmb3JtYXQiOiAxLAogICJ0aGVtZXMiOiBbCiAgICB7CiAgICAgICJpZCI6ICJtaWRuaWdodCIsCiAgICAgICJuYW1lIjogIk1pZG5pZ2h0IiwKICAgICAgImRlc2NyaXB0aW9uIjogIkluZGlnbyBvbiBibGFjaywgdGhlIGxhdGUtbmlnaHQgZGVmYXVsdC4iLAogICAgICAiYWNjZW50IjogIiM2RTdDRkYiLAogICAgICAiZ2xhc3NUaW50IjogIiMxNjE4MkEiLAogICAgICAiY29sb3JzIjogeyAiYmFja2dyb3VuZCI6ICIjMDAwMDAwIiwgInRleHQiOiAiI0Y0RjVGRiIsICJzZWNvbmRhcnkiOiAiIzlBQTBDMyIgfSwKICAgICAgImR5bmFtaWNDb2xvcnMiOiB0cnVlCiAgICB9LAogICAgewogICAgICAiaWQiOiAidmlueWwiLAogICAgICAibmFtZSI6ICJWaW55bCIsCiAgICAgICJkZXNjcmlwdGlvbiI6ICJXYXJtIGFtYmVyLCBsaWtlIGEgbGFtcCBvbiBhIHJlY29yZCBzbGVldmUuIFRoZSBhY2NlbnQgc3RheXMgcHV0IHdoZW4gZHluYW1pYyBjb2xvcnMgYXJlIG9uLiIsCiAgICAgICJhY2NlbnQiOiAiI0U4QTU0QiIsCiAgICAgICJnbGFzc1RpbnQiOiAiIzI0MTgwQyIsCiAgICAgICJjb2xvcnMiOiB7ICJiYWNrZ3JvdW5kIjogIiMxMjBDMDYiLCAidGV4dCI6ICIjRkZGNkU4IiwgInNlY29uZGFyeSI6ICIjQzRBMjdBIiB9LAogICAgICAiYmFja2dyb3VuZCI6ICIjMUExMDA4IiwKICAgICAgImR5bmFtaWNDb2xvcnMiOiBmYWxzZQogICAgfSwKICAgIHsKICAgICAgImlkIjogImZvcmVzdCIsCiAgICAgICJuYW1lIjogIkZvcmVzdCIsCiAgICAgICJkZXNjcmlwdGlvbiI6ICJBIGRlZXAgZ3JlZW4gdGhhdCBjYW4gZm9sbG93IHRoZSBjb3Zlci4iLAogICAgICAiYWNjZW50IjogIiMzRERDODQiLAogICAgICAiZ2xhc3NUaW50IjogIiMwRTFDMTQiLAogICAgICAiY29sb3JzIjogeyAiYmFja2dyb3VuZCI6ICIjMDYxMTBDIiwgInRleHQiOiAiI0U5RkZGMyIsICJzZWNvbmRhcnkiOiAiIzhGQjlBMCIgfSwKICAgICAgImR5bmFtaWNDb2xvcnMiOiB0cnVlCiAgICB9LAogICAgewogICAgICAiaWQiOiAib2NlYW4iLAogICAgICAibmFtZSI6ICJPY2VhbiIsCiAgICAgICJkZXNjcmlwdGlvbiI6ICJDb29sIGJsdWUgb3ZlciBhIGRhcmsgc2VhLiIsCiAgICAgICJhY2NlbnQiOiAiIzRDQzNGRiIsCiAgICAgICJnbGFzc1RpbnQiOiAiIzBBMUMyOCIsCiAgICAgICJjb2xvcnMiOiB7ICJiYWNrZ3JvdW5kIjogIiMwNjEwMTgiLCAidGV4dCI6ICIjRTdGN0ZGIiwgInNlY29uZGFyeSI6ICIjOEZCNEM5IiB9LAogICAgICAiYmFja2dyb3VuZCI6ICIjMDcxODIwIiwKICAgICAgImR5bmFtaWNDb2xvcnMiOiB0cnVlCiAgICB9LAogICAgewogICAgICAiaWQiOiAicm9zZSIsCiAgICAgICJuYW1lIjogIlJvc2UiLAogICAgICAiZGVzY3JpcHRpb24iOiAiUGluayB0aGF0IHN0YXlzIHBpbmsuIER5bmFtaWMgY29sb3JzIHdpbGwgbm90IG92ZXJyaWRlIGl0LiIsCiAgICAgICJhY2NlbnQiOiAiI0ZGNkI5QSIsCiAgICAgICJnbGFzc1RpbnQiOiAiIzJBMTIxQyIsCiAgICAgICJjb2xvcnMiOiB7ICJiYWNrZ3JvdW5kIjogIiMxNDA4MEUiLCAidGV4dCI6ICIjRkZFOEYwIiwgInNlY29uZGFyeSI6ICIjRDRBM0I0IiB9LAogICAgICAiZHluYW1pY0NvbG9ycyI6IGZhbHNlCiAgICB9LAogICAgewogICAgICAiaWQiOiAiYW1vbGVkIiwKICAgICAgIm5hbWUiOiAiQU1PTEVEIiwKICAgICAgImRlc2NyaXB0aW9uIjogIlB1cmUgYmxhY2sgYW5kIFNwb3RpZnkgZ3JlZW4uIiwKICAgICAgImFjY2VudCI6ICIjMUVENzYwIiwKICAgICAgImdsYXNzVGludCI6ICIjMDAwMDAwIiwKICAgICAgImNvbG9ycyI6IHsgImJhY2tncm91bmQiOiAiIzAwMDAwMCIsICJ0ZXh0IjogIiNGRkZGRkYiLCAic2Vjb25kYXJ5IjogIiM4RThFOTMiIH0sCiAgICAgICJkeW5hbWljQ29sb3JzIjogdHJ1ZQogICAgfSwKICAgIHsKICAgICAgImlkIjogImR1c2siLAogICAgICAibmFtZSI6ICJEdXNrIiwKICAgICAgImRlc2NyaXB0aW9uIjogIlB1cnBsZSBnbGFzcyBhdCB0aGUgZW5kIG9mIHRoZSBkYXkuIiwKICAgICAgImFjY2VudCI6ICIjQzA4NEZDIiwKICAgICAgImdsYXNzVGludCI6ICIjMUExMDI0IiwKICAgICAgImNvbG9ycyI6IHsgImJhY2tncm91bmQiOiAiIzEwMDgxOCIsICJ0ZXh0IjogIiNGNkVFRkYiLCAic2Vjb25kYXJ5IjogIiNCOUEzQ0MiIH0sCiAgICAgICJkeW5hbWljQ29sb3JzIjogdHJ1ZQogICAgfSwKICAgIHsKICAgICAgImlkIjogInBhcGVyIiwKICAgICAgIm5hbWUiOiAiUGFwZXIiLAogICAgICAiZGVzY3JpcHRpb24iOiAiV2FybSBwYXBlciBpbiBhIGRhcmsgcm9vbS4gVGhlIGNyZWFtIGFjY2VudCBpcyBmaXhlZC4iLAogICAgICAiYWNjZW50IjogIiNGMkUyQzQiLAogICAgICAiZ2xhc3NUaW50IjogIiMyQTIyMTgiLAogICAgICAiY29sb3JzIjogeyAiYmFja2dyb3VuZCI6ICIjMUMxNjEyIiwgInRleHQiOiAiI0ZGRjhFRSIsICJzZWNvbmRhcnkiOiAiI0NEQkJBNiIgfSwKICAgICAgImJhY2tncm91bmQiOiAiIzIyMUMxNiIsCiAgICAgICJkeW5hbWljQ29sb3JzIjogZmFsc2UKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJjaGVycnkiLAogICAgICAibmFtZSI6ICJDaGVycnkiLAogICAgICAiZGVzY3JpcHRpb24iOiAiQSByZWQgYWNjZW50IHRoYXQgZHluYW1pYyBjb2xvcnMgbGVhdmUgYWxvbmUuIiwKICAgICAgImFjY2VudCI6ICIjRkY0NTNBIiwKICAgICAgImdsYXNzVGludCI6ICIjMkExMDEyIiwKICAgICAgImNvbG9ycyI6IHsgImJhY2tncm91bmQiOiAiIzE2MDgwQSIsICJ0ZXh0IjogIiNGRkVDRUEiLCAic2Vjb25kYXJ5IjogIiNENEEwOUMiIH0sCiAgICAgICJkeW5hbWljQ29sb3JzIjogZmFsc2UKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJpY2UiLAogICAgICAibmFtZSI6ICJJY2UiLAogICAgICAiZGVzY3JpcHRpb24iOiAiUGFsZSBjeWFuIHRoYXQgY2FuIHN0aWxsIGZvbGxvdyB0aGUgY292ZXIuIiwKICAgICAgImFjY2VudCI6ICIjOUJFN0ZGIiwKICAgICAgImdsYXNzVGludCI6ICIjMTAxODIwIiwKICAgICAgImNvbG9ycyI6IHsgImJhY2tncm91bmQiOiAiIzBDMTIxNiIsICJ0ZXh0IjogIiNGMkZCRkYiLCAic2Vjb25kYXJ5IjogIiNBOUM0Q0UiIH0sCiAgICAgICJkeW5hbWljQ29sb3JzIjogdHJ1ZQogICAgfQogIF0KfQo=";

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }
static NSInteger (^sDynamicRGB)(void);
static NSInteger (^sSwitchRGB)(void);
static UIColor *(^sGlassBlock)(void);
static NSArray<NSDictionary *> *sShown;
static NSString *sCatalogNote;
static BOOL sSwizzled;
static void publish(void);
static void refreshRemote(void (^done)(void));

#pragma mark - validation (data only)

static BOOL hexColor(NSString *text, NSInteger *out) {
    if (![text isKindOfClass:NSString.class]) return NO;
    if ([text hasPrefix:@"#"]) text = [text substringFromIndex:1];
    if (text.length != 6) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:text];
    unsigned int rgb = 0;
    if (![scanner scanHexInt:&rgb] || !scanner.isAtEnd) return NO;
    if (out) *out = rgb;
    return YES;
}

static BOOL plainToken(NSString *text, NSUInteger max) {
    if (![text isKindOfClass:NSString.class] || text.length < 1 || text.length > max) return NO;
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"] invertedSet];
    return [text rangeOfCharacterFromSet:bad].location == NSNotFound;
}

static NSDictionary *validTheme(NSDictionary *raw) {
    if (![raw isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in raw) {
        if (![@[@"id", @"name", @"description", @"accent", @"glassTint", @"colors", @"dynamicColors", @"background"] containsObject:key]) return nil;
    }
    if (!plainToken(raw[@"id"], 40)) return nil;
    NSCharacterSet *idOk = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-"];
    if ([raw[@"id"] rangeOfCharacterFromSet:[idOk invertedSet]].location != NSNotFound) return nil;
    if (![raw[@"name"] isKindOfClass:NSString.class] || [raw[@"name"] length] < 1 || [raw[@"name"] length] > 40) return nil;
    if (raw[@"description"] && (![raw[@"description"] isKindOfClass:NSString.class] || [raw[@"description"] length] > 180)) return nil;
    NSInteger accent = 0, glass = 0;
    if (!hexColor(raw[@"accent"], &accent) || !hexColor(raw[@"glassTint"], &glass)) return nil;
    if (raw[@"dynamicColors"] && ![raw[@"dynamicColors"] isKindOfClass:NSNumber.class]) return nil;
    if (raw[@"colors"]) {
        if (![raw[@"colors"] isKindOfClass:NSDictionary.class]) return nil;
        for (NSString *key in raw[@"colors"]) {
            if (![@[@"background", @"text", @"secondary"] containsObject:key]) return nil;
            if (!hexColor(raw[@"colors"][key], NULL)) return nil;
        }
    }
    if (raw[@"background"]) {
        NSString *bg = raw[@"background"];
        if (hexColor(bg, NULL)) {}
        else if (!plainToken(bg, 80) || [bg containsString:@"/"]) return nil;
    }
    NSMutableDictionary *theme = [NSMutableDictionary dictionary];
    theme[@"id"] = raw[@"id"];
    theme[@"name"] = raw[@"name"];
    theme[@"accent"] = raw[@"accent"];
    theme[@"glassTint"] = raw[@"glassTint"];
    theme[@"dynamicColors"] = raw[@"dynamicColors"] ?: @YES;
    if (raw[@"description"]) theme[@"description"] = raw[@"description"];
    if (raw[@"colors"]) theme[@"colors"] = raw[@"colors"];
    if (raw[@"background"]) theme[@"background"] = raw[@"background"];
    return theme;
}

static NSArray<NSDictionary *> *validCatalog(NSData *data) {
    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in json) if (![@[@"format", @"themes"] containsObject:key]) return nil;
    if (![json[@"format"] isKindOfClass:NSNumber.class] || [json[@"format"] integerValue] != 1) return nil;
    if (![json[@"themes"] isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *ids = [NSMutableSet set];
    for (id item in json[@"themes"]) {
        NSDictionary *theme = validTheme(item);
        if (!theme || [ids containsObject:theme[@"id"]]) continue;
        [ids addObject:theme[@"id"]];
        [out addObject:theme];
    }
    return out.count ? out : nil;
}

static NSArray<NSDictionary *> *bundledThemes(void) {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:kBundled options:NSDataBase64DecodingIgnoreUnknownCharacters];
    return validCatalog(data) ?: @[];
}

static BOOL remoteEnabled(void) {
    id v = [D() objectForKey:@"mirage.themes.remote"];
    return v ? [v boolValue] : YES;
}

static NSArray<NSDictionary *> *shownThemes(void) {
    NSArray *bundled = bundledThemes();
    if (!remoteEnabled()) return bundled;
    NSArray *remote = validCatalog([D() dataForKey:@"mirage.themes.remoteCache"]);
    if (!remote.count) return bundled;
    NSMutableArray *out = [NSMutableArray arrayWithArray:bundled];
    NSMutableDictionary *index = [NSMutableDictionary dictionary];
    [out enumerateObjectsUsingBlock:^(NSDictionary *t, NSUInteger i, BOOL *stop) { index[t[@"id"]] = @(i); }];
    for (NSDictionary *theme in remote) {
        NSNumber *at = index[theme[@"id"]];
        if (at) out[at.unsignedIntegerValue] = theme;
        else [out addObject:theme];
    }
    return out;
}

#pragma mark - applied theme

static NSInteger rgbOf(NSDictionary *theme, NSString *key) {
    NSInteger rgb = 0;
    return hexColor(theme[key], &rgb) ? rgb : -1;
}

NSDictionary *MRGAppliedTheme(void) {
    NSData *data = [D() dataForKey:@"mirage.theme.applied"];
    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return validTheme(json);
}

BOOL MRGThemeAllowsDynamicColors(void) {
    NSDictionary *theme = MRGAppliedTheme();
    if (!theme) return YES;
    return [theme[@"dynamicColors"] boolValue];
}

NSInteger MRGLookLiveRGB(void) {
    if (sDynamicRGB) {
        NSInteger dyn = sDynamicRGB();
        if (dyn >= 0 && dyn <= 0xFFFFFF) return dyn;
    }
    return rgbOf(MRGAppliedTheme(), @"accent");
}

UIColor *MRGLookGlassTint(void) {
    if (sGlassBlock) {
        UIColor *override = sGlassBlock();
        if (override) return override;
    }
    NSInteger rgb = rgbOf(MRGAppliedTheme(), @"glassTint");
    return rgb >= 0 ? MRGColorFromRGB(rgb) : nil;
}

void MRGLookSetDynamicRGB(NSInteger (^block)(void)) { sDynamicRGB = [block copy]; }
void MRGLookSetSwitchRGB(NSInteger (^block)(void)) { sSwitchRGB = [block copy]; }
void MRGLookSetGlassTint(UIColor *(^block)(void)) { sGlassBlock = [block copy]; }

#pragma mark - paint Spotify's green and Vitrine's glass with the theme

static NSInteger storedAccent(void) {
    BOOL redesign = [D() boolForKey:@"spotifyglass.redesign"];
    if (@available(iOS 26.0, *)) {}
    else redesign = redesign && [D() boolForKey:@"spotifyglass.redesign.untested"];
    id v = [D() objectForKey:redesign ? @"spotifyglass.redesign.accent" : @"spotifyglass.accent"];
    NSInteger rgb = [v isKindOfClass:NSNumber.class] ? [v integerValue] : (redesign ? 0x37F200 : -1);
    if (rgb < 0 || rgb > 0xFFFFFF) rgb = 0x1ED760;
    return rgb;
}

static BOOL near(CGFloat r, CGFloat g, CGFloat b, NSInteger rgb) {
    return fabs(r - ((rgb >> 16) & 255) / 255.0) < 0.025 && fabs(g - ((rgb >> 8) & 255) / 255.0) < 0.025 && fabs(b - (rgb & 255) / 255.0) < 0.025;
}

static BOOL retint(CGFloat *r, CGFloat *g, CGFloat *b) {
    NSInteger live = MRGLookLiveRGB();
    if (live < 0 || near(*r, *g, *b, live)) return NO;
    NSInteger stored = storedAccent();
    if (!near(*r, *g, *b, 0x1ED760) && !near(*r, *g, *b, 0x1DB954) && !near(*r, *g, *b, 0x37F200) && !near(*r, *g, *b, stored)) return NO;
    *r = ((live >> 16) & 255) / 255.0;
    *g = ((live >> 8) & 255) / 255.0;
    *b = (live & 255) / 255.0;
    return YES;
}

static UIColor *(*sOrigColor)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat);
static id (*sOrigInit)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat);
static UIColor *liveColor(id self, SEL _cmd, CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    retint(&r, &g, &b);
    return sOrigColor(self, _cmd, r, g, b, a);
}
static id liveInit(id self, SEL _cmd, CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    retint(&r, &g, &b);
    return sOrigInit(self, _cmd, r, g, b, a);
}

static char kRecolored;
static void recolorTree(UIView *view, NSInteger switches, UIColor *glass, NSInteger depth, NSUInteger *seen) {
    if (!view || depth > 25 || *seen > 5000) return;
    (*seen)++;
    if ([view isKindOfClass:UISwitch.class]) {
        UISwitch *sw = (UISwitch *)view;
        BOOL ours = objc_getAssociatedObject(sw, &kRecolored) != nil;
        if (switches >= 0) {
            CGFloat r = 0, g = 0, b = 0, a = 0;
            BOOL close = ours;
            if (!close && [sw.onTintColor getRed:&r green:&g blue:&b alpha:&a]) {
                NSInteger live = MRGLookLiveRGB();
                close = near(r, g, b, 0x1ED760) || near(r, g, b, 0x34C759) || near(r, g, b, storedAccent())
                    || (live >= 0 && near(r, g, b, live)) || near(r, g, b, switches);
            }
            if (close) {
                sw.onTintColor = MRGColorFromRGB(switches);
                objc_setAssociatedObject(sw, &kRecolored, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        } else if (ours) {
            NSInteger back = MRGLookLiveRGB();
            sw.onTintColor = MRGColorFromRGB(back >= 0 ? back : storedAccent());
            objc_setAssociatedObject(sw, &kRecolored, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    if ([view isKindOfClass:UIVisualEffectView.class]) {
        UIVisualEffect *effect = ((UIVisualEffectView *)view).effect;
        if ([NSStringFromClass(effect.class) containsString:@"Glass"] && [effect respondsToSelector:@selector(setTintColor:)]) {
            if (glass) ((void (*)(id, SEL, UIColor *))objc_msgSend)(effect, @selector(setTintColor:), [glass colorWithAlphaComponent:0.42]);
            else if (objc_getAssociatedObject(view, &kRecolored)) ((void (*)(id, SEL, UIColor *))objc_msgSend)(effect, @selector(setTintColor:), nil);
            if (glass) objc_setAssociatedObject(view, &kRecolored, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            else objc_setAssociatedObject(view, &kRecolored, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    for (UIView *sub in view.subviews) recolorTree(sub, switches, glass, depth + 1, seen);
}

static void installSwizzle(void) {
    if (sSwizzled) return;
    sSwizzled = YES;
    Method color = class_getClassMethod(UIColor.class, @selector(colorWithRed:green:blue:alpha:));
    Method init = class_getInstanceMethod(UIColor.class, @selector(initWithRed:green:blue:alpha:));
    if (color) { sOrigColor = (void *)method_getImplementation(color); method_setImplementation(color, (IMP)liveColor); }
    if (init) { sOrigInit = (void *)method_getImplementation(init); method_setImplementation(init, (IMP)liveInit); }
}

void MRGLookRefresh(void) {
    installSwizzle();
    NSInteger switches = sSwitchRGB ? sSwitchRGB() : MRGLookLiveRGB();
    UIColor *glass = MRGLookGlassTint();
    NSUInteger seen = 0;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) recolorTree(window, switches, glass, 0, &seen);
    }
}

#pragma mark - apply / remove

static void storeApplied(NSDictionary *theme) {
    if (!theme) { [D() removeObjectForKey:@"mirage.theme.applied"]; return; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:theme options:0 error:nil];
    if (data) [D() setObject:data forKey:@"mirage.theme.applied"];
}

static NSURL *backgroundFile(NSDictionary *theme) {
    NSInteger rgb = 0;
    if (!hexColor(theme[@"background"], &rgb)) {
        NSString *name = theme[@"background"];
        if (![name isKindOfClass:NSString.class]) return nil;
        NSURL *file = [MRGMediaDirectory() URLByAppendingPathComponent:name];
        return [NSFileManager.defaultManager fileExistsAtPath:file.path] ? file : nil;
    }
    CGSize size = CGSizeMake(32, 96);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIColor *top = MRGColorFromRGB(rgb);
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGFloat r = 0, g = 0, b = 0, a = 0;
        [top getRed:&r green:&g blue:&b alpha:&a];
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGFloat comps[] = {r, g, b, 1, 0, 0, 0, 1};
        CGGradientRef grad = CGGradientCreateWithColorComponents(space, comps, NULL, 2);
        CGContextDrawLinearGradient(ctx.CGContext, grad, CGPointZero, CGPointMake(0, size.height), 0);
        CGGradientRelease(grad);
        CGColorSpaceRelease(space);
    }];
    NSData *jpg = UIImageJPEGRepresentation(image, 0.92);
    NSURL *dst = [MRGMediaDirectory() URLByAppendingPathComponent:[NSString stringWithFormat:@"theme-%@.jpg", theme[@"id"]]];
    if (![jpg writeToURL:dst atomically:YES]) return nil;
    return dst;
}

static void applyTheme(NSDictionary *theme, BOOL useBackground) {
    storeApplied(theme);
    if (useBackground) {
        NSURL *file = backgroundFile(theme);
        if (file) MRGSetCurrentMedia(file, MRGMediaImage);
    }
    MRGLookRefresh();
    MRGPostChange();
    MRGDJLog(@"themes: applied %@", theme[@"id"]);
}

static void removeTheme(void) {
    NSString *name = MRGAppliedTheme()[@"name"];
    storeApplied(nil);
    MRGLookRefresh();
    MRGPostChange();
    MRGDJLog(@"themes: removed %@", name ?: @"theme");
}

#pragma mark - preview

@interface MRGThemePreview : UITableViewController
@property (nonatomic, copy) NSDictionary *theme;
@end

@implementation MRGThemePreview
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.theme[@"name"] ?: @"Theme";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.tableView.backgroundColor = UIColor.blackColor;
    UIEdgeInsets inset = self.tableView.contentInset; inset.bottom = 150; self.tableView.contentInset = inset;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 3; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return s == 0 ? 3 : 1; }
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    if (s == 0) return self.theme[@"description"];
    if (s == 1) return [self.theme[@"dynamicColors"] boolValue]
        ? @"Dynamic colors may replace this accent with the cover."
        : @"Dynamic colors will not change this theme's accent.";
    if (s == 2 && self.theme[@"background"]) return @"Using the background replaces the one you have now. Removing the theme puts the accent back and leaves that picture in place.";
    return nil;
}
- (UITableViewCell *)swatch:(NSString *)title hex:(NSString *)hex {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.9];
    c.textLabel.text = title;
    c.textLabel.textColor = UIColor.whiteColor;
    c.detailTextLabel.text = hex;
    c.detailTextLabel.textColor = UIColor.grayColor;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    NSInteger rgb = 0;
    if (hexColor(hex, &rgb)) {
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 22, 22)];
        dot.backgroundColor = MRGColorFromRGB(rgb);
        dot.layer.cornerRadius = 11;
        c.accessoryView = dot;
    }
    return c;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    return MRGSafeCell(ip, ^UITableViewCell *{
        if (ip.section == 0) {
            if (ip.row == 0) return [self swatch:@"Accent" hex:self.theme[@"accent"]];
            if (ip.row == 1) return [self swatch:@"Glass" hex:self.theme[@"glassTint"]];
            return [self swatch:@"Background" hex:self.theme[@"colors"][@"background"] ?: @"#000000"];
        }
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.9];
        BOOL on = [MRGAppliedTheme()[@"id"] isEqual:self.theme[@"id"]];
        if (ip.section == 1) {
            c.textLabel.text = on ? @"Applied" : @"Apply";
            c.textLabel.textColor = on ? UIColor.grayColor : MRGAccent();
            c.selectionStyle = on ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
            c.userInteractionEnabled = !on;
            return c;
        }
        c.textLabel.text = on ? @"Remove theme" : @"Not applied";
        c.textLabel.textColor = on ? UIColor.systemRedColor : UIColor.grayColor;
        c.selectionStyle = on ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        c.userInteractionEnabled = on;
        return c;
    });
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 2 && [MRGAppliedTheme()[@"id"] isEqual:self.theme[@"id"]]) {
        removeTheme();
        [self.tableView reloadData];
        return;
    }
    if (ip.section != 1) return;
    void (^finish)(BOOL) = ^(BOOL background) {
        applyTheme(self.theme, background);
        [self.tableView reloadData];
    };
    if (!self.theme[@"background"]) { finish(NO); return; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Use this theme's background?"
        message:@"This replaces the background you have now. The colors are applied either way."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Colors only" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { finish(NO); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Use background" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { finish(YES); }]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

#pragma mark - shop section

@interface MRGThemeRemoteTarget : NSObject
@end
@implementation MRGThemeRemoteTarget
- (void)flipped:(UISwitch *)sw {
    [D() setBool:sw.on forKey:@"mirage.themes.remote"];
    if (!sw.on) sCatalogNote = @"Using the themes that ship with Mirage.";
    MRGPostChange();
    if (sw.on) refreshRemote(nil);
}
@end
static MRGThemeRemoteTarget *sRemoteTarget;

static void publish(void) {
    sShown = shownThemes();
    if (!sRemoteTarget) sRemoteTarget = [MRGThemeRemoteTarget new];
    NSInteger rows = (NSInteger)sShown.count + 1;
    MRGSetShopHeader(@"Themes", rows, ^UITableViewCell *(UITableView *table, NSInteger row) {
        if (row >= (NSInteger)sShown.count) {
            UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
            c.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.92];
            c.textLabel.text = @"Download theme list";
            c.textLabel.textColor = UIColor.whiteColor;
            c.detailTextLabel.text = @"Off keeps the themes that ship with Mirage.";
            c.detailTextLabel.textColor = UIColor.grayColor;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            UISwitch *sw = [UISwitch new];
            sw.on = remoteEnabled();
            sw.onTintColor = MRGAccent();
            [sw addTarget:sRemoteTarget action:@selector(flipped:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
            return c;
        }
        NSDictionary *theme = sShown[row];
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        c.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.92];
        c.textLabel.text = theme[@"name"];
        c.textLabel.textColor = UIColor.whiteColor;
        BOOL on = [MRGAppliedTheme()[@"id"] isEqual:theme[@"id"]];
        c.detailTextLabel.text = on ? @"On" : nil;
        c.detailTextLabel.textColor = UIColor.grayColor;
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        NSInteger rgb = 0;
        if (hexColor(theme[@"accent"], &rgb)) {
            c.imageView.image = [UIImage systemImageNamed:@"circle.fill"];
            c.imageView.tintColor = MRGColorFromRGB(rgb);
        }
        return c;
    }, ^(UIViewController *shop, NSInteger row) {
        if (row < 0 || row >= (NSInteger)sShown.count) return;
        MRGThemePreview *page = [MRGThemePreview new];
        page.theme = sShown[row];
        MRGPushPage(shop, page);
    }, ^NSString *{
        return sCatalogNote ?: @"Themes are colors only. Nothing here is code.";
    });
}

static void refreshRemote(void (^done)(void)) {
    if (!remoteEnabled()) { publish(); if (done) done(); return; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kRemoteURL]];
    request.timeoutInterval = 12;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        NSArray *list = status == 200 ? validCatalog(data) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (list) {
                [D() setObject:data forKey:@"mirage.themes.remoteCache"];
                sCatalogNote = nil;
            } else {
                sCatalogNote = @"Couldn't reach the theme list. Showing the themes that ship with Mirage.";
                MRGDJLog(@"themes: remote catalog unavailable (%@)", error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)status]);
            }
            publish();
            MRGPostChange();
            if (done) done();
        });
    }] resume];
}

__attribute__((constructor)) static void mrgThemesConstructor(void) {
    publish();
    dispatch_async(dispatch_get_main_queue(), ^{
        installSwizzle();
        if (MRGAppliedTheme()) MRGLookRefresh();
        refreshRemote(nil);
    });
}
