#import "Addons/MRGAddonArt.h"
#import "Addons/MRGAddon.h"
#import "MRGDJLog.h"

NSString *MRGAddonSymbol(NSString *addonID);

static NSArray<NSString *> *knownIDs(void) {
    return @[@"vinyl", @"dynamic-colors", @"playlist-tools", @"genres", @"popup-lyrics", @"trash", @"shuffle-plus"];
}
BOOL MRGAddonHasArt(NSString *addonID) { return addonID.length && [knownIDs() containsObject:addonID]; }

#pragma mark - helpers

static UIColor *mix(UIColor *a, UIColor *b, CGFloat t) {
    CGFloat r1 = 0, g1 = 0, b1 = 0, a1 = 1, r2 = 0, g2 = 0, b2 = 0, a2 = 1;
    if (![a getRed:&r1 green:&g1 blue:&b1 alpha:&a1]) { CGFloat w; [a getWhite:&w alpha:&a1]; r1 = g1 = b1 = w; }
    if (![b getRed:&r2 green:&g2 blue:&b2 alpha:&a2]) { CGFloat w; [b getWhite:&w alpha:&a2]; r2 = g2 = b2 = w; }
    return [UIColor colorWithRed:r1 + (r2 - r1) * t green:g1 + (g2 - g1) * t blue:b1 + (b2 - b1) * t alpha:a1 + (a2 - a1) * t];
}

static void linear(CGContextRef c, CGRect r, UIColor *top, UIColor *bottom, BOOL horizontal) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = @[(id)top.CGColor, (id)bottom.CGColor];
    CGGradientRef g = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
    CGContextSaveGState(c);
    CGContextClipToRect(c, r);
    CGPoint end = horizontal ? CGPointMake(CGRectGetMaxX(r), CGRectGetMinY(r)) : CGPointMake(CGRectGetMinX(r), CGRectGetMaxY(r));
    CGContextDrawLinearGradient(c, g, r.origin, end, 0);
    CGContextRestoreGState(c);
    CGGradientRelease(g);
    CGColorSpaceRelease(space);
}

static void glow(CGContextRef c, CGPoint p, CGFloat radius, UIColor *color, CGFloat alpha) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = @[(id)[color colorWithAlphaComponent:alpha].CGColor, (id)[color colorWithAlphaComponent:0].CGColor];
    CGGradientRef g = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
    CGContextDrawRadialGradient(c, g, p, 0, p, radius, 0);
    CGGradientRelease(g);
    CGColorSpaceRelease(space);
}

static void fillRound(CGRect r, CGFloat radius, UIColor *color) {
    [color setFill];
    [[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:radius] fill];
}

static void symbol(NSString *name, CGRect r, UIColor *color, UIFontWeight weight) {
    UIImageSymbolConfiguration *conf = [UIImageSymbolConfiguration configurationWithPointSize:MIN(r.size.width, r.size.height) weight:UIImageSymbolWeightForFontWeight(weight)];
    UIImage *img = [[UIImage systemImageNamed:name withConfiguration:conf] imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
    if (!img) return;
    CGSize s = img.size;
    CGFloat k = MIN(r.size.width / MAX(s.width, 1), r.size.height / MAX(s.height, 1));
    CGSize d = CGSizeMake(s.width * k, s.height * k);
    [img drawInRect:CGRectMake(CGRectGetMidX(r) - d.width / 2, CGRectGetMidY(r) - d.height / 2, d.width, d.height)];
}

static void text(NSString *s, CGPoint p, CGFloat size, UIFontWeight weight, UIColor *color, BOOL centered) {
    NSDictionary *attrs = @{NSFontAttributeName: [UIFont systemFontOfSize:size weight:weight], NSForegroundColorAttributeName: color};
    CGSize z = [s sizeWithAttributes:attrs];
    [s drawAtPoint:CGPointMake(centered ? p.x - z.width / 2 : p.x, p.y - z.height / 2) withAttributes:attrs];
}

// An album cover stand-in: a gradient square with a soft shape, so the art never needs a real cover.
static void cover(CGContextRef c, CGRect r, UIColor *a, UIColor *b) {
    CGContextSaveGState(c);
    [[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:r.size.width * 0.08] addClip];
    linear(c, r, a, b, NO);
    glow(c, CGPointMake(CGRectGetMinX(r) + r.size.width * 0.7, CGRectGetMinY(r) + r.size.height * 0.3), r.size.width * 0.6, UIColor.whiteColor, 0.28);
    [[UIColor colorWithWhite:0 alpha:0.18] setFill];
    CGContextFillEllipseInRect(c, CGRectMake(CGRectGetMinX(r) - r.size.width * 0.2, CGRectGetMaxY(r) - r.size.height * 0.45, r.size.width * 0.9, r.size.height * 0.9));
    CGContextRestoreGState(c);
}

static void record(CGContextRef c, CGRect disc, UIColor *label) {
    CGContextSaveGState(c);
    CGContextSetShadowWithColor(c, CGSizeMake(0, disc.size.height * 0.04), disc.size.height * 0.08, [UIColor colorWithWhite:0 alpha:0.6].CGColor);
    [[UIColor colorWithWhite:0.04 alpha:1] setFill];
    CGContextFillEllipseInRect(c, disc);
    CGContextRestoreGState(c);
    CGFloat side = disc.size.width;
    CGContextSetLineWidth(c, MAX(0.6, side / 220));
    for (CGFloat i = 0.04; i < 0.30; i += 0.022) {
        [[UIColor colorWithWhite:1 alpha:(fmod(i * 100, 7) < 2.2 ? 0.10 : 0.05)] setStroke];
        CGContextStrokeEllipseInRect(c, CGRectInset(disc, side * i, side * i));
    }
    CGContextSaveGState(c);
    CGContextAddEllipseInRect(c, disc);
    CGContextClip(c);
    glow(c, CGPointMake(CGRectGetMinX(disc) + side * 0.3, CGRectGetMinY(disc) + side * 0.25), side * 0.45, UIColor.whiteColor, 0.10);
    CGContextRestoreGState(c);
    CGRect l = CGRectInset(disc, side * 0.31, side * 0.31);
    CGContextSaveGState(c);
    CGContextAddEllipseInRect(c, l);
    CGContextClip(c);
    linear(c, l, mix(label, UIColor.whiteColor, 0.25), mix(label, UIColor.blackColor, 0.3), NO);
    CGContextRestoreGState(c);
    [[UIColor colorWithWhite:0.02 alpha:1] setFill];
    CGContextFillEllipseInRect(c, CGRectInset(disc, side * 0.485, side * 0.485));
}

#pragma mark - one picture per add-on

static void drawVinyl(CGContextRef c, CGSize S, UIColor *accent) {
    CGFloat side = S.height * 0.66, cy = S.height / 2, cx = S.width * 0.42;
    CGRect sleeve = CGRectMake(cx - side / 2, cy - side / 2, side, side);
    record(c, CGRectMake(cx - side * 0.12, cy - side * 0.47, side * 0.94, side * 0.94), accent);
    CGContextSaveGState(c);
    CGContextSetShadowWithColor(c, CGSizeMake(0, side * 0.04), side * 0.1, [UIColor colorWithWhite:0 alpha:0.7].CGColor);
    cover(c, sleeve, mix(accent, UIColor.whiteColor, 0.15), mix(accent, UIColor.blackColor, 0.55));
    CGContextRestoreGState(c);
    symbol(@"music.note", CGRectInset(sleeve, side * 0.34, side * 0.34), [UIColor colorWithWhite:1 alpha:0.85], UIFontWeightSemibold);
    // the spin, as a curved arrow
    UIBezierPath *arc = [UIBezierPath bezierPathWithArcCenter:CGPointMake(cx + side * 0.35, cy) radius:side * 0.58 startAngle:-M_PI * 0.32 endAngle:-M_PI * 0.08 clockwise:YES];
    arc.lineWidth = MAX(2, side / 50);
    arc.lineCapStyle = kCGLineCapRound;
    [[accent colorWithAlphaComponent:0.9] setStroke];
    [arc stroke];
}

static void drawDynamic(CGContextRef c, CGSize S, UIColor *accent) {
    CGFloat side = S.height * 0.56, cy = S.height / 2;
    CGRect art = CGRectMake(S.width * 0.14, cy - side / 2, side, side);
    UIColor *warm = [UIColor colorWithRed:1 green:0.42 blue:0.35 alpha:1], *cool = [UIColor colorWithRed:0.30 green:0.62 blue:1 alpha:1];
    CGContextSaveGState(c);
    CGContextSetShadowWithColor(c, CGSizeMake(0, 6), 16, [UIColor colorWithWhite:0 alpha:0.6].CGColor);
    cover(c, art, warm, mix(accent, UIColor.blackColor, 0.2));
    CGContextRestoreGState(c);
    // arrow from the cover to the swatches
    CGFloat ax = CGRectGetMaxX(art) + S.width * 0.05;
    symbol(@"arrow.right", CGRectMake(ax, cy - side * 0.12, side * 0.3, side * 0.24), [UIColor colorWithWhite:1 alpha:0.55], UIFontWeightBold);
    NSArray<UIColor *> *dots = @[warm, accent, cool];
    CGFloat d = side * 0.42, x0 = ax + side * 0.42;
    for (NSUInteger i = 0; i < dots.count; i++) {
        CGRect r = CGRectMake(x0 + i * d * 0.62, cy - d / 2 + (i == 1 ? -d * 0.18 : d * 0.12), d, d);
        CGContextSaveGState(c);
        CGContextSetShadowWithColor(c, CGSizeMake(0, 4), 10, [UIColor colorWithWhite:0 alpha:0.5].CGColor);
        [dots[i] setFill];
        CGContextFillEllipseInRect(c, r);
        CGContextRestoreGState(c);
        [[UIColor colorWithWhite:1 alpha:0.35] setStroke];
        CGContextSetLineWidth(c, 1.5);
        CGContextStrokeEllipseInRect(c, CGRectInset(r, 0.75, 0.75));
    }
    // a toggle tinted with the picked color
    CGRect sw = CGRectMake(x0 + d * 0.3, cy + side * 0.36, side * 0.5, side * 0.28);
    fillRound(sw, sw.size.height / 2, warm);
    [UIColor.whiteColor setFill];
    CGContextFillEllipseInRect(c, CGRectInset(CGRectMake(CGRectGetMaxX(sw) - sw.size.height, sw.origin.y, sw.size.height, sw.size.height), 2.5, 2.5));
}

static void drawPlaylistTools(CGContextRef c, CGSize S, UIColor *accent) {
    CGFloat w = S.width * 0.52, rowH = S.height * 0.13, x = S.width * 0.12, y0 = S.height * 0.18;
    NSArray *widths = @[@0.78, @0.62, @0.70, @0.55];
    for (NSUInteger i = 0; i < 4; i++) {
        CGFloat y = y0 + i * (rowH + S.height * 0.045);
        BOOL dup = i == 2;
        fillRound(CGRectMake(x, y, w, rowH), rowH * 0.28, [UIColor colorWithWhite:1 alpha:dup ? 0.04 : 0.08]);
        cover(c, CGRectMake(x + rowH * 0.15, y + rowH * 0.15, rowH * 0.7, rowH * 0.7), i % 2 ? accent : mix(accent, UIColor.whiteColor, 0.4), mix(accent, UIColor.blackColor, 0.5));
        CGFloat lx = x + rowH * 1.05, lw = (w - rowH * 1.3) * [widths[i] doubleValue];
        fillRound(CGRectMake(lx, y + rowH * 0.28, lw, rowH * 0.18), rowH * 0.09, [UIColor colorWithWhite:1 alpha:dup ? 0.25 : 0.75]);
        fillRound(CGRectMake(lx, y + rowH * 0.58, lw * 0.6, rowH * 0.14), rowH * 0.07, [UIColor colorWithWhite:1 alpha:0.3]);
        if (dup) {
            [[UIColor colorWithRed:1 green:0.35 blue:0.4 alpha:0.9] setStroke];
            CGContextSetLineWidth(c, 2);
            CGContextMoveToPoint(c, x + 6, y + rowH / 2);
            CGContextAddLineToPoint(c, x + w - 6, y + rowH / 2);
            CGContextStrokePath(c);
        }
    }
    CGFloat bx = x + w + S.width * 0.07, bs = S.height * 0.34;
    CGRect badge = CGRectMake(bx, S.height * 0.2, bs, bs);
    CGContextSaveGState(c);
    CGContextSetShadowWithColor(c, CGSizeMake(0, 5), 14, [accent colorWithAlphaComponent:0.6].CGColor);
    fillRound(badge, bs * 0.28, accent);
    CGContextRestoreGState(c);
    symbol(@"arrow.up.arrow.down", CGRectInset(badge, bs * 0.24, bs * 0.24), UIColor.whiteColor, UIFontWeightBold);
    CGRect badge2 = CGRectMake(bx + bs * 0.25, CGRectGetMaxY(badge) + S.height * 0.06, bs * 0.72, bs * 0.72);
    fillRound(badge2, bs * 0.2, [UIColor colorWithWhite:1 alpha:0.12]);
    symbol(@"shuffle", CGRectInset(badge2, bs * 0.17, bs * 0.17), [UIColor colorWithWhite:1 alpha:0.9], UIFontWeightBold);
}

static void drawGenres(CGContextRef c, CGSize S, UIColor *accent) {
    CGFloat side = S.height * 0.46, cy = S.height * 0.42;
    CGRect art = CGRectMake(S.width / 2 - side / 2, cy - side / 2 - S.height * 0.04, side, side);
    CGContextSaveGState(c);
    CGContextSetShadowWithColor(c, CGSizeMake(0, 6), 16, [UIColor colorWithWhite:0 alpha:0.6].CGColor);
    cover(c, art, mix(accent, UIColor.whiteColor, 0.2), mix(accent, UIColor.blackColor, 0.6));
    CGContextRestoreGState(c);
    symbol(@"waveform", CGRectInset(art, side * 0.28, side * 0.28), [UIColor colorWithWhite:1 alpha:0.85], UIFontWeightSemibold);
    NSArray *tags = @[@"indie pop", @"bedroom pop", @"alt R&B"];
    CGFloat fs = S.height * 0.075, pad = fs * 0.8, gap = fs * 0.6;
    NSDictionary *attrs = @{NSFontAttributeName: [UIFont systemFontOfSize:fs weight:UIFontWeightSemibold]};
    CGFloat total = 0;
    for (NSString *t in tags) total += [t sizeWithAttributes:attrs].width + 2 * pad;
    total += gap * (tags.count - 1);
    CGFloat x = S.width / 2 - total / 2, y = CGRectGetMaxY(art) + S.height * 0.08, h = fs * 2;
    for (NSUInteger i = 0; i < tags.count; i++) {
        CGFloat tw = [tags[i] sizeWithAttributes:attrs].width + 2 * pad;
        CGRect pill = CGRectMake(x, y, tw, h);
        fillRound(pill, h / 2, i == 0 ? accent : [UIColor colorWithWhite:1 alpha:0.12]);
        text(tags[i], CGPointMake(CGRectGetMidX(pill), CGRectGetMidY(pill)), fs, UIFontWeightSemibold, UIColor.whiteColor, YES);
        x += tw + gap;
    }
}

static void drawLyrics(CGContextRef c, CGSize S, UIColor *accent) {
    CGRect card = CGRectMake(S.width * 0.1, S.height * 0.16, S.width * 0.8, S.height * 0.68);
    CGContextSaveGState(c);
    CGContextSetShadowWithColor(c, CGSizeMake(0, 8), 20, [UIColor colorWithWhite:0 alpha:0.55].CGColor);
    fillRound(card, S.height * 0.08, [UIColor colorWithWhite:0 alpha:0.45]);
    CGContextRestoreGState(c);
    CGContextSaveGState(c);
    [[UIBezierPath bezierPathWithRoundedRect:card cornerRadius:S.height * 0.08] addClip];
    linear(c, card, [accent colorWithAlphaComponent:0.35], [accent colorWithAlphaComponent:0.05], YES);
    CGContextRestoreGState(c);
    CGFloat x = CGRectGetMinX(card) + S.width * 0.06, fs = S.height * 0.085;
    text(@"and the city lights", CGPointMake(x, CGRectGetMinY(card) + card.size.height * 0.22), fs * 0.8, UIFontWeightSemibold, [UIColor colorWithWhite:1 alpha:0.3], NO);
    text(@"are singing back to me", CGPointMake(x, CGRectGetMinY(card) + card.size.height * 0.47), fs * 1.15, UIFontWeightHeavy, UIColor.whiteColor, NO);
    text(@"every night, every night", CGPointMake(x, CGRectGetMinY(card) + card.size.height * 0.73), fs * 0.8, UIFontWeightSemibold, [UIColor colorWithWhite:1 alpha:0.45], NO);
    CGRect note = CGRectMake(CGRectGetMaxX(card) - S.height * 0.2, CGRectGetMinY(card) - S.height * 0.06, S.height * 0.2, S.height * 0.2);
    CGContextSaveGState(c);
    CGContextSetShadowWithColor(c, CGSizeMake(0, 4), 10, [accent colorWithAlphaComponent:0.7].CGColor);
    [accent setFill];
    CGContextFillEllipseInRect(c, note);
    CGContextRestoreGState(c);
    symbol(@"quote.bubble.fill", CGRectInset(note, note.size.width * 0.25, note.size.width * 0.25), UIColor.whiteColor, UIFontWeightBold);
}

static void drawTrash(CGContextRef c, CGSize S, UIColor *accent) {
    CGFloat w = S.width * 0.46, rowH = S.height * 0.15, x = S.width * 0.1;
    for (NSUInteger i = 0; i < 3; i++) {
        CGFloat y = S.height * 0.2 + i * (rowH + S.height * 0.06);
        BOOL gone = i == 1;
        CGContextSaveGState(c);
        if (gone) { CGContextTranslateCTM(c, w * 0.12, 0); CGContextSetAlpha(c, 0.55); }
        fillRound(CGRectMake(x, y, w, rowH), rowH * 0.28, [UIColor colorWithWhite:1 alpha:0.08]);
        cover(c, CGRectMake(x + rowH * 0.15, y + rowH * 0.15, rowH * 0.7, rowH * 0.7), gone ? [UIColor colorWithRed:1 green:0.4 blue:0.4 alpha:1] : accent, mix(accent, UIColor.blackColor, 0.5));
        fillRound(CGRectMake(x + rowH, y + rowH * 0.3, w * 0.55, rowH * 0.16), rowH * 0.08, [UIColor colorWithWhite:1 alpha:0.7]);
        fillRound(CGRectMake(x + rowH, y + rowH * 0.58, w * 0.32, rowH * 0.13), rowH * 0.07, [UIColor colorWithWhite:1 alpha:0.3]);
        CGContextRestoreGState(c);
    }
    CGFloat bs = S.height * 0.5;
    CGRect bin = CGRectMake(S.width * 0.66, S.height / 2 - bs / 2, bs, bs);
    CGContextSaveGState(c);
    CGContextSetShadowWithColor(c, CGSizeMake(0, 6), 18, [accent colorWithAlphaComponent:0.6].CGColor);
    [accent setFill];
    CGContextFillEllipseInRect(c, bin);
    CGContextRestoreGState(c);
    symbol(@"trash.fill", CGRectInset(bin, bs * 0.26, bs * 0.26), UIColor.whiteColor, UIFontWeightBold);
}

static void drawShuffle(CGContextRef c, CGSize S, UIColor *accent) {
    CGFloat bs = S.height * 0.4;
    CGRect badge = CGRectMake(S.width / 2 - bs / 2, S.height * 0.12, bs, bs);
    CGContextSaveGState(c);
    CGContextSetShadowWithColor(c, CGSizeMake(0, 6), 18, [accent colorWithAlphaComponent:0.7].CGColor);
    fillRound(badge, bs * 0.3, accent);
    CGContextRestoreGState(c);
    symbol(@"shuffle", CGRectInset(badge, bs * 0.22, bs * 0.22), UIColor.whiteColor, UIFontWeightBold);
    text(@"+", CGPointMake(CGRectGetMaxX(badge) + bs * 0.12, CGRectGetMinY(badge) + bs * 0.12), bs * 0.4, UIFontWeightHeavy, accent, YES);
    // a queue where no artist (color) repeats back to back
    NSArray<UIColor *> *artists = @[accent, [UIColor colorWithRed:1 green:0.55 blue:0.3 alpha:1], [UIColor colorWithRed:0.3 green:0.75 blue:1 alpha:1], accent, [UIColor colorWithRed:0.4 green:0.9 blue:0.55 alpha:1], [UIColor colorWithRed:1 green:0.55 blue:0.3 alpha:1]];
    CGFloat d = S.height * 0.16, gap = d * 0.45, total = artists.count * d + (artists.count - 1) * gap;
    CGFloat x = S.width / 2 - total / 2, y = CGRectGetMaxY(badge) + S.height * 0.14;
    for (NSUInteger i = 0; i < artists.count; i++) {
        CGRect r = CGRectMake(x + i * (d + gap), y, d, d);
        cover(c, r, mix(artists[i], UIColor.whiteColor, 0.15), mix(artists[i], UIColor.blackColor, 0.45));
        if (i + 1 < artists.count) {
            [[UIColor colorWithWhite:1 alpha:0.3] setFill];
            CGContextFillEllipseInRect(c, CGRectMake(CGRectGetMaxX(r) + gap / 2 - 2, CGRectGetMidY(r) - 2, 4, 4));
        }
    }
}

static void drawGeneric(CGContextRef c, CGSize S, UIColor *accent) {
    CGFloat bs = S.height * 0.46;
    CGRect badge = CGRectMake(S.width / 2 - bs / 2, S.height / 2 - bs / 2, bs, bs);
    CGContextSaveGState(c);
    CGContextSetShadowWithColor(c, CGSizeMake(0, 6), 18, [accent colorWithAlphaComponent:0.7].CGColor);
    fillRound(badge, bs * 0.3, accent);
    CGContextRestoreGState(c);
    symbol(@"puzzlepiece.extension.fill", CGRectInset(badge, bs * 0.22, bs * 0.22), UIColor.whiteColor, UIFontWeightBold);
}

// The same finish on every picture, so the shop reads as one set: the add-on's symbol as a faint watermark, a soft
// vignette, a glass highlight across the top and a thin inner rim.
static void finish(CGContextRef c, CGSize S, NSString *addonID) {
    CGRect all = (CGRect){CGPointZero, S};
    CGFloat mark = S.height * 0.9;
    CGContextSaveGState(c);
    CGContextSetAlpha(c, 0.05);
    symbol(MRGAddonSymbol(addonID), CGRectMake(S.width - mark * 0.72, S.height - mark * 0.78, mark, mark), UIColor.whiteColor, UIFontWeightBlack);
    CGContextRestoreGState(c);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat vig[] = {0, 0, 0, 0, 0, 0, 0, 0.42};
    CGGradientRef g = CGGradientCreateWithColorComponents(space, vig, NULL, 2);
    CGPoint mid = CGPointMake(S.width / 2, S.height * 0.45);
    CGContextDrawRadialGradient(c, g, mid, MIN(S.width, S.height) * 0.35, mid, hypot(S.width, S.height) * 0.62, kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
    CGFloat shine[] = {1, 1, 1, 0.11, 1, 1, 1, 0};
    g = CGGradientCreateWithColorComponents(space, shine, NULL, 2);
    CGContextDrawLinearGradient(c, g, CGPointZero, CGPointMake(0, S.height * 0.42), 0);
    CGGradientRelease(g);
    CGColorSpaceRelease(space);
    [[UIColor colorWithWhite:1 alpha:0.10] setStroke];
    UIBezierPath *rim = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(all, 0.75, 0.75) cornerRadius:16];
    rim.lineWidth = 1.5;
    [rim stroke];
}

UIImage *MRGAddonArt(NSString *addonID, CGSize size) {
    if (size.width < 10 || size.height < 10) size = CGSizeMake(640, 360);
    UIColor *accent = MRGAccent() ?: [UIColor colorWithRed:0.66 green:0.42 blue:1 alpha:1];
    static NSCache *cache;
    if (!cache) cache = [NSCache new];
    NSString *key = [NSString stringWithFormat:@"%@|%.0fx%.0f|%06lX", addonID ?: @"", size.width, size.height, (long)MRGRGBFromColor(accent)];
    UIImage *hit = [cache objectForKey:key];
    if (hit) return hit;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        @try {
            CGRect all = (CGRect){CGPointZero, size};
            linear(c, all, mix(accent, [UIColor colorWithWhite:0.06 alpha:1], 0.78), [UIColor colorWithWhite:0.035 alpha:1], NO);
            glow(c, CGPointMake(size.width * 0.85, size.height * 0.1), size.width * 0.6, accent, 0.35);
            glow(c, CGPointMake(size.width * 0.1, size.height * 1.0), size.width * 0.45, mix(accent, UIColor.whiteColor, 0.2), 0.18);
            NSString *a = addonID ?: @"";
            if ([a isEqualToString:@"vinyl"]) drawVinyl(c, size, accent);
            else if ([a isEqualToString:@"dynamic-colors"]) drawDynamic(c, size, accent);
            else if ([a isEqualToString:@"playlist-tools"]) drawPlaylistTools(c, size, accent);
            else if ([a isEqualToString:@"genres"]) drawGenres(c, size, accent);
            else if ([a isEqualToString:@"popup-lyrics"]) drawLyrics(c, size, accent);
            else if ([a isEqualToString:@"trash"]) drawTrash(c, size, accent);
            else if ([a isEqualToString:@"shuffle-plus"]) drawShuffle(c, size, accent);
            else drawGeneric(c, size, accent);
            finish(c, size, a);
        } @catch (NSException *e) {
            MRGDJLog(@"addons: art for %@ threw %@", addonID, e.reason);
        }
    }];
    if (img) [cache setObject:img forKey:key];
    return img;
}

NSString *MRGAddonSymbol(NSString *addonID) {
    NSDictionary *map = @{@"vinyl": @"record.circle", @"dynamic-colors": @"paintpalette.fill", @"playlist-tools": @"list.bullet.rectangle.fill",
                          @"genres": @"tag.fill", @"popup-lyrics": @"quote.bubble.fill", @"trash": @"trash.fill", @"shuffle-plus": @"shuffle"};
    return map[addonID ?: @""] ?: @"puzzlepiece.extension.fill";
}

// Each add-on gets its own hue near the accent, so a list of tiles reads as a set and not one color repeated.
static CGFloat hueShift(NSString *addonID) {
    NSArray *order = knownIDs();
    NSUInteger i = [order indexOfObject:addonID ?: @""];
    if (i == NSNotFound) return 0;
    return ((CGFloat)i / MAX((CGFloat)order.count, 1) - 0.5) * 0.16;
}

UIImage *MRGAddonIcon(NSString *addonID, CGFloat side) {
    if (side < 8) side = 32;
    UIColor *accent = MRGAccent() ?: [UIColor colorWithRed:0.66 green:0.42 blue:1 alpha:1];
    static NSCache *cache;
    if (!cache) cache = [NSCache new];
    NSString *key = [NSString stringWithFormat:@"icon|%@|%.0f|%06lX", addonID ?: @"", side, (long)MRGRGBFromColor(accent)];
    UIImage *hit = [cache objectForKey:key];
    if (hit) return hit;
    CGFloat h = 0, s = 0, b = 0, a = 1;
    if (![accent getHue:&h saturation:&s brightness:&b alpha:&a]) { h = 0.75; s = 0.6; b = 0.9; }
    h = fmod(h + hueShift(addonID) + 1, 1);
    UIColor *top = [UIColor colorWithHue:h saturation:MIN(1, s * 0.85) brightness:MIN(1, MAX(b, 0.7) * 1.05) alpha:1];
    UIColor *bottom = [UIColor colorWithHue:fmod(h + 0.04, 1) saturation:MIN(1, s * 1.1) brightness:MAX(b, 0.6) * 0.62 alpha:1];
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        @try {
            CGRect all = CGRectMake(0, 0, side, side);
            UIBezierPath *tile = [UIBezierPath bezierPathWithRoundedRect:all cornerRadius:side * 0.27];
            CGContextSaveGState(c);
            [tile addClip];
            linear(c, all, top, bottom, NO);
            glow(c, CGPointMake(side * 0.25, side * 0.1), side * 0.7, UIColor.whiteColor, 0.28);
            CGContextRestoreGState(c);
            [[UIColor colorWithWhite:1 alpha:0.22] setStroke];
            UIBezierPath *rim = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(all, 0.5, 0.5) cornerRadius:side * 0.27 - 0.5];
            rim.lineWidth = 1;
            [rim stroke];
            symbol(MRGAddonSymbol(addonID), CGRectInset(all, side * 0.24, side * 0.24), UIColor.whiteColor, UIFontWeightSemibold);
        } @catch (NSException *e) {}
    }];
    if (img) [cache setObject:img forKey:key];
    return img;
}
