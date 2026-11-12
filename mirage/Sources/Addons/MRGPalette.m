#import "Addons/MRGPalette.h"
#import "MRGPlayer.h"
#import <dlfcn.h>

static void hsv(double r, double g, double b, double *h, double *s, double *v) {
    double mx = MAX(r, MAX(g, b)), mn = MIN(r, MIN(g, b)), d = mx - mn;
    *v = mx;
    *s = mx > 0 ? d / mx : 0;
    if (d <= 0) { *h = 0; return; }
    double hh = mx == r ? fmod((g - b) / d, 6) : mx == g ? (b - r) / d + 2 : (r - g) / d + 4;
    *h = hh < 0 ? (hh + 6) / 6 : hh / 6;
}

// 32x32 downsample; pixels grouped by hue (12 bins) and brightness (3 bins), grays in a bin of their own per
// brightness. Each group's color is the average of its pixels (not a bucket's corner), so the color is the cover's.
MRGPalette MRGPaletteFromImage(UIImage *image) {
    MRGPalette p = {-1, -1};
    CGImageRef cg = image.CGImage;
    if (!cg) return p;
    enum { N = 32, Groups = 12 * 3 + 3 };
    uint8_t px[N * N * 4];
    memset(px, 0, sizeof px);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, N, N, 8, N * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) return p;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, N, N), cg);
    CGContextRelease(ctx);
    // 0.6.8: the middle of a cover counts more than its edges (borders, frames and text bands sit there), and a
    // color needs a real share of the weighted cover to count as its vibrant one.
    double sumR[Groups] = {0}, sumG[Groups] = {0}, sumB[Groups] = {0}, sumS[Groups] = {0}, sumV[Groups] = {0}, weight[Groups] = {0};
    int count[Groups] = {0};
    int total = 0;
    double totalWeight = 0;
    for (int i = 0; i < N * N; i++) {
        if (px[i * 4 + 3] < 128) continue;
        int x = i % N, y = i / N;
        double dx = fabs(x + 0.5 - N / 2.0) / (N / 2.0), dy = fabs(y + 0.5 - N / 2.0) / (N / 2.0);
        double w = 1.0 - 0.55 * MIN(1.0, MAX(dx, dy) * MAX(dx, dy));
        double r = px[i * 4] / 255.0, g = px[i * 4 + 1] / 255.0, b = px[i * 4 + 2] / 255.0, h, s, v;
        hsv(r, g, b, &h, &s, &v);
        int vb = v < 0.35 ? 0 : v < 0.7 ? 1 : 2;
        int group = (s < 0.16 || v < 0.08) ? 36 + vb : (int)MIN(11, floor(h * 12)) * 3 + vb;
        sumR[group] += r * w; sumG[group] += g * w; sumB[group] += b * w; sumS[group] += s * w; sumV[group] += v * w;
        weight[group] += w;
        count[group]++;
        total++;
        totalWeight += w;
    }
    if (total < 16 || totalWeight <= 0) return p;
    int dom = -1, vib = -1;
    double vibScore = 0;
    for (int k = 0; k < Groups; k++) {
        if (!count[k]) continue;
        if (dom < 0 || weight[k] > weight[dom]) dom = k;
        if (k >= 36) continue;
        double share = weight[k] / totalWeight, s = sumS[k] / weight[k], v = sumV[k] / weight[k];
        if (share < 0.025 || s < 0.25 || v < 0.2) continue;
        double score = sqrt(share) * s * s * (0.4 + v);
        if (score > vibScore) { vibScore = score; vib = k; }
    }
#define RGB_OF(k) (((NSInteger)lround(sumR[k] / weight[k] * 255) << 16) | ((NSInteger)lround(sumG[k] / weight[k] * 255) << 8) | (NSInteger)lround(sumB[k] / weight[k] * 255))
    if (dom >= 0) p.dominant = RGB_OF(dom);
    if (vib >= 0) p.vibrant = RGB_OF(vib);
#undef RGB_OF
    return p;
}

static double channelLin(double c) { return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); }

double MRGLuminance(NSInteger rgb) {
    return 0.2126 * channelLin(((rgb >> 16) & 255) / 255.0) + 0.7152 * channelLin(((rgb >> 8) & 255) / 255.0) + 0.0722 * channelLin((rgb & 255) / 255.0);
}

double MRGContrast(NSInteger a, NSInteger b) {
    double la = MRGLuminance(a), lb = MRGLuminance(b);
    return (MAX(la, lb) + 0.05) / (MIN(la, lb) + 0.05);
}

NSInteger MRGPaletteAccent(MRGPalette palette) {
    NSInteger c = palette.vibrant >= 0 ? palette.vibrant : palette.dominant;
    if (c < 0) return -1;
    double r = ((c >> 16) & 255) / 255.0, g = ((c >> 8) & 255) / 255.0, b = (c & 255) / 255.0, h, s, v;
    hsv(r, g, b, &h, &s, &v);
    if (s < 0.16) return 0xEBEBEB;   // a gray cover: near white, which reads on black
    // Lift brightness (keeping the hue) until it reads on Spotify's near-black at 3:1 or better. Plain math, not
    // UIColor: the theme add-on swizzles UIColor's constructors.
    for (int i = 0; i < 14; i++) {
        double hh = h * 6, f = hh - floor(hh), pp = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
        double rr, gg, bb;
        switch ((int)floor(hh) % 6) {
            case 0: rr = v; gg = t; bb = pp; break;
            case 1: rr = q; gg = v; bb = pp; break;
            case 2: rr = pp; gg = v; bb = t; break;
            case 3: rr = pp; gg = q; bb = v; break;
            case 4: rr = t; gg = pp; bb = v; break;
            default: rr = v; gg = pp; bb = q; break;
        }
        NSInteger rgb = ((NSInteger)lround(rr * 255) << 16) | ((NSInteger)lround(gg * 255) << 8) | (NSInteger)lround(bb * 255);
        if (MRGContrast(rgb, 0x121212) >= 3 || (v >= 1 && s <= 0.35)) return rgb;
        if (v < 1) v = MIN(1, v + 0.08); else s = MAX(0.35, s - 0.08);
    }
    return c;
}

static NSCache *sPalettes;

BOOL MRGPaletteCached(NSString *uri, MRGPalette *out) {
    if (!uri.length) return NO;
    NSValue *v = [sPalettes objectForKey:uri];
    if (!v) return NO;
    if (out) [v getValue:out size:sizeof(MRGPalette)];
    return YES;
}

static void finish(NSString *uri, MRGPalette p, void (^done)(NSString *, MRGPalette)) {
    if (!sPalettes) sPalettes = [NSCache new];
    if (uri.length && (p.dominant >= 0 || p.vibrant >= 0)) [sPalettes setObject:[NSValue valueWithBytes:&p objCType:@encode(MRGPalette)] forKey:uri];
    if (done) done(uri, p);
}

void MRGPaletteForNowPlaying(void (^done)(NSString *uri, MRGPalette palette)) {
    if (!sPalettes) sPalettes = [NSCache new];
    NSDictionary *now = MRGNowPlaying();
    NSString *uri = now[@"uri"];
    MRGPalette hit;
    if (MRGPaletteCached(uri, &hit)) { if (done) done(uri, hit); return; }
    NSString *urlString = now[@"image"];
    NSURL *url = [urlString isKindOfClass:NSString.class] && [urlString hasPrefix:@"https://"] ? [NSURL URLWithString:urlString] : nil;
    if (url) {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.timeoutInterval = 10;
        [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            MRGPalette p = {-1, -1};
            @try { if (data.length) p = MRGPaletteFromImage([UIImage imageWithData:data]); } @catch (NSException *e) {}
            dispatch_async(dispatch_get_main_queue(), ^{ finish(uri, p, done); });
        }] resume];
        return;
    }
    // No URL: the artwork Vitrine keeps for the playing song, when it is that song's.
    UIImage *(*art)(NSString **, NSString **) = (UIImage *(*)(NSString **, NSString **))dlsym(RTLD_DEFAULT, "SGRNowPlayingArtwork");
    UIImage *image = nil;
    if (art) {
        NSString *artURI = nil;
        @try { image = art(&artURI, NULL); } @catch (NSException *e) { image = nil; }
        if (artURI.length && uri.length && ![artURI isEqualToString:uri]) image = nil;
    }
    if (!image) { MRGPalette none = {-1, -1}; if (done) done(uri, none); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        MRGPalette p = {-1, -1};
        @try { p = MRGPaletteFromImage(image); } @catch (NSException *e) {}
        dispatch_async(dispatch_get_main_queue(), ^{ finish(uri, p, done); });
    });
}
