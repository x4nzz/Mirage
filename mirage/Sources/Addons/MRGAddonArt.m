#import "Addons/MRGAddonArt.h"
#import "Addons/MRGAddon.h"
#import "MRGDJLog.h"

// The art is one designed set (scripts/mirage-art.py): flat geometric covers on a shared grid, Mirage purple with
// one secondary tone per add-on, and matching icon tiles. They are rendered on the build machine and compiled in as
// image data (MRGAddonArtData.m), so the phone shows exactly the previewed pictures and draws nothing itself.
typedef struct { const char *addon; const char *kind; const unsigned char *bytes; size_t length; } MRGArtBlob;
extern const MRGArtBlob MRGArtBlobs[];
extern const size_t MRGArtBlobCount;

static NSArray<NSString *> *knownIDs(void) {
    return @[@"vinyl", @"dynamic-colors", @"playlist-tools", @"genres", @"popup-lyrics", @"trash", @"shuffle-plus"];
}
BOOL MRGAddonHasArt(NSString *addonID) { return addonID.length && [knownIDs() containsObject:addonID]; }

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
                          @"genres": @"tag.fill", @"popup-lyrics": @"quote.bubble.fill", @"trash": @"trash.fill", @"shuffle-plus": @"shuffle"};
    return map[addonID ?: @""] ?: @"puzzlepiece.extension.fill";
}
