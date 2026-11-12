#import "Addons/MRGAddonArt.h"
#import "Addons/MRGAddon.h"
#import "MRGDJLog.h"

// The art is one designed set (scripts/mirage-art.py): flat geometric covers on a shared grid, Mirage purple with
// one secondary tone per add-on, and matching icon tiles. They are rendered on the build machine and compiled in as
// image data (MRGAddonArtData.m), so the phone shows exactly the previewed pictures and draws nothing itself.
typedef struct { const char *addon; const char *kind; const unsigned char *bytes; size_t length; } MRGArtBlob;
extern const MRGArtBlob MRGArtBlobs[];
extern const size_t MRGArtBlobCount;

// 0.6.7: an add-on has art when the compiled-in set has its cover and icon. 0.6.6 kept a hand-written list of the
// first seven ids here, so the eight add-ons added in 0.6.6 (whose art was compiled in) still drew the generic
// puzzle-piece picture. The table itself is the only list now.
static BOOL hasBlob(NSString *addonID, const char *kind) {
    const char *a = addonID.UTF8String;
    if (!a) return NO;
    for (size_t i = 0; i < MRGArtBlobCount; i++) if (!strcmp(MRGArtBlobs[i].kind, kind) && !strcmp(MRGArtBlobs[i].addon, a)) return YES;
    return NO;
}
BOOL MRGAddonHasArt(NSString *addonID) {
    if (!addonID.length || [addonID isEqualToString:@"generic"]) return NO;
    static NSMutableDictionary<NSString *, NSNumber *> *known;
    if (!known) known = [NSMutableDictionary dictionary];
    NSNumber *hit = known[addonID];
    if (!hit) { hit = @(hasBlob(addonID, "cover") && hasBlob(addonID, "icon")); known[addonID] = hit; }
    return hit.boolValue;
}

// The decoded original (3x), once per add-on and kind.
static UIImage *original(NSString *addonID, NSString *kind) {
    static NSCache *cache;
    if (!cache) cache = [NSCache new];
    NSString *addon = MRGAddonHasArt(addonID) ? addonID : @"generic";
    NSString *key = [NSString stringWithFormat:@"%@|%@", kind, addon];
    UIImage *hit = [cache objectForKey:key];
    if (hit) return hit;
    for (size_t i = 0; i < MRGArtBlobCount; i++) {
        const MRGArtBlob *b = &MRGArtBlobs[i];
        if (strcmp(b->kind, kind.UTF8String) != 0 || strcmp(b->addon, addon.UTF8String) != 0) continue;
        NSData *data = [NSData dataWithBytesNoCopy:(void *)b->bytes length:b->length freeWhenDone:NO];
        UIImage *img = [UIImage imageWithData:data scale:3];
        if (img) [cache setObject:img forKey:key];
        return img;
    }
    return nil;
}

// Aspect-filled into `size` (points), cached per size.
static UIImage *fitted(UIImage *src, CGSize size, NSString *cacheKey) {
    if (!src) return nil;
    static NSCache *cache;
    if (!cache) { cache = [NSCache new]; cache.countLimit = 48; }
    UIImage *hit = [cache objectForKey:cacheKey];
    if (hit) return hit;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGSize s = src.size;
        CGFloat k = MAX(size.width / MAX(s.width, 1), size.height / MAX(s.height, 1));
        CGSize d = CGSizeMake(s.width * k, s.height * k);
        [src drawInRect:CGRectMake((size.width - d.width) / 2, (size.height - d.height) / 2, d.width, d.height)];
    }];
    if (img) [cache setObject:img forKey:cacheKey];
    return img;
}

UIImage *MRGAddonArt(NSString *addonID, CGSize size) {
    if (size.width < 10 || size.height < 10) size = CGSizeMake(360, 203);
    @try {
        return fitted(original(addonID, @"cover"), size, [NSString stringWithFormat:@"cover|%@|%.0fx%.0f", addonID ?: @"", size.width, size.height]);
    } @catch (NSException *e) {
        MRGDJLog(@"addons: art for %@ threw %@", addonID, e.reason);
        return nil;
    }
}

UIImage *MRGAddonIcon(NSString *addonID, CGFloat side) {
    if (side < 8) side = 32;
    @try {
        return fitted(original(addonID, @"icon"), CGSizeMake(side, side), [NSString stringWithFormat:@"icon|%@|%.0f", addonID ?: @"", side]);
    } @catch (NSException *e) { return nil; }
}

NSString *MRGAddonSymbol(NSString *addonID) {
    NSDictionary *map = @{@"vinyl": @"record.circle", @"dynamic-colors": @"paintpalette.fill", @"playlist-tools": @"list.bullet.rectangle.fill",
                          @"genres": @"tag.fill", @"popup-lyrics": @"quote.bubble.fill", @"trash": @"trash.fill", @"shuffle-plus": @"shuffle",
                          @"radio": @"dot.radiowaves.left.and.right", @"focus": @"viewfinder", @"on-repeat": @"repeat",
                          @"more-like-this": @"sparkles", @"cover-ring": @"circle.circle", @"lyrics-backdrop": @"text.quote",
                          @"queue-tools": @"list.number", @"up-next": @"text.line.first.and.arrowtriangle.forward"};
    return map[addonID ?: @""] ?: @"puzzlepiece.extension.fill";
}
