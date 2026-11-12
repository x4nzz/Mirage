// Add-on "Vinyl" (Now Playing): the player's cover becomes a record sleeve. The cover shrinks and slides to one side,
// and a vinyl record peeks out from behind it on the other, spinning while a song plays and standing still when it's
// paused. The record is drawn in code (grooves, a rim, a light that stays put while the disc turns, a center hole) and
// its label is the album art.
//
// Spotify's tree (from Vitrine's notes): CoverArtCellImpl > UIView > UIView > CoverArtTiltView (≥200pt in the player,
// 40pt in the bar) > the cover (an ElementView the tilt view's size; Vitrine scales it down while paused).
//
// 0.5.4: the record follows where the cover really is every frame (its presentation layer, read in the tilt view's
// space), not just the cover's transform, and keeps following the same cover whatever its size. 0.5.2/0.5.3 lost the
// cover when Spotify shrank its frame to dismiss the player, so the record was left behind full size while the sheet
// was pulled down.
// 0.5.2: the record lives inside the tilt view, below the cover, so it moves, fades and animates with the cover in
// every transition (opening and closing the player, the swipe between songs, pulling the player down). The tilt view's
// own scale and shift carry it too. When the cover itself is scaled (Vitrine's paused shrink), the record copies that
// transform about the cover's center and the very same animation, every frame it changes, so it never lags and jumps.
// 0.5.1 kept the tilt view in an unretained reference on the cell; a tilt view Spotify rebuilt left it pointing at
// freed memory, and the next pass crashed. Nothing here holds a Spotify view strongly or unretained: the record is
// stored on the tilt view itself and holds it weakly.
//
// 0.5.4: bigger again (0.5.3 never let the sleeve outgrow Spotify's art and peeked 30%, so on a phone it barely changed):
// the sleeve plus a 20% peek span the screen less 12pt each side, about a 305pt cover on a 390pt iPhone (78%).
// 0.5.3: the sleeve plus the record showing past it now fill Now Playing's art row. 0.5.2 shrank the cover to 70% of the
// tilt view and fit the record inside the tilt view's own width, which left a small cover and empty space at the sides.
// Now the piece is sized from the cover cell's width (a small side margin kept) and the record peeks out less, so the
// cover is as big as the row allows; it is never taller than Spotify's own art (no overlap with the title or lyrics
// below), stays square, and the record stays centered on it vertically and scales with it.
#import <UIKit/UIKit.h>
#import "MRGCompat.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import "MRGAddons.h"
#import "MRGPrefs.h"
#import "MRGPlayer.h"
#import "MRGDJLog.h"
#import "MRGNowKit.h"
#import "MRGSpotifyWeb.h"

// 0.6.6 variants: the record's color (black, the cover's own colors, the accent, clear red, white), the sleeve's
// finish (plain, glossy, worn), and a spin that follows the song's tempo (one turn per four beats) when Spotify gives
// the app the song's BPM; when it doesn't (its audio features endpoint is closed to many apps), the chosen speed.
static NSInteger recordColor(void) { return [NSUserDefaults.standardUserDefaults integerForKey:@"mirage.addon.vinyl.color"]; }
static NSInteger sleeveStyle(void) { return [NSUserDefaults.standardUserDefaults integerForKey:@"mirage.addon.vinyl.sleeve"]; }
static BOOL followBPM(void) { return [NSUserDefaults.standardUserDefaults boolForKey:@"mirage.addon.vinyl.bpm"]; }
static NSInteger labelStyle(void) { return [NSUserDefaults.standardUserDefaults integerForKey:@"mirage.addon.vinyl.label"]; }   // 0 cover, 1 plain
static BOOL shine(void) { id v = [NSUserDefaults.standardUserDefaults objectForKey:@"mirage.addon.vinyl.shine"]; return [v isKindOfClass:NSNumber.class] ? [v boolValue] : YES; }
static double sTempo;            // the playing song's BPM, 0 when unknown
static NSString *sTempoFor;
static double turnSeconds(void) {
    if (followBPM() && sTempo > 0) return MIN(3.5, MAX(1.0, 240.0 / sTempo));
    return MRGVinylSecondsPerTurn();
}

// How much record shows past the sleeve, of the sleeve's width (0.6.7: a setting, Less / Normal / More).
static CGFloat peekAmount(void) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:@"mirage.addon.vinyl.peek"];
    double p = [v isKindOfClass:NSNumber.class] ? [v doubleValue] : 0.20;
    return MIN(0.32, MAX(0.10, p));
}
#define kPeek peekAmount()
static const CGFloat kMargin = 12;          // the piece's side margin on screen
static const CGFloat kMinCover = 0.55;      // the sleeve never gets smaller than this, of the tilt view's size
static const CGFloat kDisc = 0.92;          // the record's diameter, of the sleeve's width
static char kVinylKey, kOursKey, kClipKey, kUnclippedKey, kSleeveKey;
static CFTimeInterval sg_glideUntil;   // right after the add-on or its side changed: the cover glides, else it is set

static Class tiltClass(void) {
    static Class c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView"); });
    return c;
}
static Class cellClass(void) {
    static Class c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl"); });
    return c;
}

static UIView *findTilt(UIView *v, int depth) {
    if (!v || depth > 8) return nil;
    Class c = tiltClass();
    if (c && [v isKindOfClass:c] && v.bounds.size.width >= 200) return v;
    for (UIView *s in v.subviews) { UIView *t = findTilt(s, depth + 1); if (t) return t; }
    return nil;
}

static BOOL inPlayerCell(UIView *v) {
    Class c = cellClass();
    for (UIView *p = v.superview; p && c; p = p.superview) if ([p isKindOfClass:c]) return YES;
    return NO;
}

// The biggest image showing inside the cover.
static UIImage *coverImage(UIView *v, int depth) {
    if (!v || depth > 8) return nil;
    if ([v isKindOfClass:UIImageView.class]) {
        UIImage *img = ((UIImageView *)v).image;
        if (img.size.width >= 60) return img;
    }
    for (UIView *s in v.subviews) { UIImage *i = coverImage(s, depth + 1); if (i) return i; }
    return nil;
}

static void logState(NSString *state) {
    static NSString *last;
    if ([state isEqualToString:last]) return;
    last = [state copy];
    MRGDJLog(@"vinyl: %@", state);
}

#pragma mark - the record

@interface MRGVinylView : UIView
@property (nonatomic, weak) UIView *tilt;
@property (nonatomic) CGFloat dir;   // 1: record on the right
@end

@interface MRGVinylProxy : NSObject
@property (nonatomic, weak) MRGVinylView *owner;
@end

@implementation MRGVinylView {
    CALayer *_disc;             // turns
    CAGradientLayer *_base;
    CAShapeLayer *_grooves, *_rings, *_rim;
    CALayer *_label;
    CAShapeLayer *_labelRing, *_hole;
    CAGradientLayer *_sheen;    // stays still: the light on the record
    CAShapeLayer *_sheenMask;
    CADisplayLink *_link;
    NSUInteger _frames;
    __weak UIImage *_shownImage;
    NSString *_shownURL;
    double _turn;
    BOOL _spinning, _built, _followed;
    CGFloat _builtSide;
    __weak UIView *_cover;      // the cover being followed, held weakly
    CGAffineTransform _lastM;
    float _lastOpacity;
    NSInteger _colorMode;
    __weak UIImage *_colorImage;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.5;
    self.layer.shadowRadius = 16;
    self.layer.shadowOffset = CGSizeMake(0, 8);
    _lastM = CGAffineTransformIdentity;
    _lastOpacity = 1;
    _disc = [CALayer layer];
    _base = [CAGradientLayer layer];
    _base.type = kCAGradientLayerRadial;
    _base.colors = @[(id)[UIColor colorWithWhite:0.20 alpha:1].CGColor, (id)[UIColor colorWithWhite:0.09 alpha:1].CGColor, (id)[UIColor colorWithWhite:0.04 alpha:1].CGColor];
    _base.locations = @[@0, @0.6, @1];
    _base.startPoint = CGPointMake(0.5, 0.5);
    _base.endPoint = CGPointMake(1, 1);
    _grooves = [CAShapeLayer layer];
    _grooves.fillColor = nil;
    _grooves.strokeColor = [UIColor colorWithWhite:1 alpha:0.07].CGColor;
    _grooves.lineWidth = 0.6;
    _rings = [CAShapeLayer layer];
    _rings.fillColor = nil;
    _rings.strokeColor = [UIColor colorWithWhite:0 alpha:0.85].CGColor;
    _rim = [CAShapeLayer layer];
    _rim.fillColor = nil;
    _rim.strokeColor = [UIColor colorWithWhite:1 alpha:0.16].CGColor;
    _rim.lineWidth = 1.5;
    _label = [CALayer layer];
    _label.masksToBounds = YES;
    _label.contentsGravity = kCAGravityResizeAspectFill;
    _label.backgroundColor = MRGAccent().CGColor;
    _labelRing = [CAShapeLayer layer];
    _labelRing.fillColor = nil;
    _labelRing.strokeColor = [UIColor colorWithWhite:0 alpha:0.55].CGColor;
    _labelRing.lineWidth = 2;
    _hole = [CAShapeLayer layer];
    _hole.fillColor = [UIColor colorWithWhite:0.03 alpha:1].CGColor;
    _hole.strokeColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    _hole.lineWidth = 0.75;
    for (CALayer *l in @[_base, _grooves, _rings, _rim, _label, _labelRing, _hole]) [_disc addSublayer:l];
    [self.layer addSublayer:_disc];
    _sheen = [CAGradientLayer layer];
    _sheen.type = kCAGradientLayerConic;
    _sheen.startPoint = CGPointMake(0.5, 0.5);
    _sheen.endPoint = CGPointMake(0.5, 0);
    UIColor *clear = [UIColor colorWithWhite:1 alpha:0], *lit = [UIColor colorWithWhite:1 alpha:0.20], *soft = [UIColor colorWithWhite:1 alpha:0.09];
    _sheen.colors = @[(id)clear.CGColor, (id)lit.CGColor, (id)clear.CGColor, (id)clear.CGColor, (id)soft.CGColor, (id)clear.CGColor, (id)clear.CGColor];
    _sheen.locations = @[@0, @0.08, @0.18, @0.5, @0.58, @0.68, @1];
    _sheenMask = [CAShapeLayer layer];
    _sheenMask.fillRule = kCAFillRuleEvenOdd;
    _sheen.mask = _sheenMask;
    [self.layer addSublayer:_sheen];
    _turn = turnSeconds();
    _colorMode = -1;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsChanged) name:MRGSettingsChangedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(trackChanged) name:MRGPlayerTrackChangedNotification object:nil];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [_link invalidate]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat side = MIN(b.size.width, b.size.height);
    if (side < 10 || (_built && fabs(side - _builtSide) < 0.5)) return;
    _built = YES;
    _builtSide = side;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGRect sq = CGRectMake((b.size.width - side) / 2, (b.size.height - side) / 2, side, side);
    // The disc turns around its own center: bounds and position, not a frame, so a spin in flight is never moved.
    _disc.bounds = (CGRect){CGPointZero, sq.size};
    _disc.position = CGPointMake(CGRectGetMidX(sq), CGRectGetMidY(sq));
    CGRect d = _disc.bounds;
    CGPoint mid = CGPointMake(side / 2, side / 2);
    CGFloat R = side / 2;
    _base.frame = d;
    _base.cornerRadius = R;
    _base.masksToBounds = YES;
    UIBezierPath *g = [UIBezierPath bezierPath];
    for (CGFloat r = R * 0.42; r < R * 0.95; r += MAX(1.2, R / 48)) [g appendPath:[UIBezierPath bezierPathWithArcCenter:mid radius:r startAngle:0 endAngle:2 * M_PI clockwise:YES]];
    _grooves.frame = d;
    _grooves.path = g.CGPath;
    UIBezierPath *rings = [UIBezierPath bezierPath];   // the quiet gaps between tracks
    for (NSNumber *f in @[@0.55, @0.68, @0.82]) [rings appendPath:[UIBezierPath bezierPathWithArcCenter:mid radius:R * f.doubleValue startAngle:0 endAngle:2 * M_PI clockwise:YES]];
    _rings.frame = d;
    _rings.path = rings.CGPath;
    _rings.lineWidth = MAX(1, R / 80);
    _rim.frame = d;
    _rim.path = [UIBezierPath bezierPathWithArcCenter:mid radius:R - 1 startAngle:0 endAngle:2 * M_PI clockwise:YES].CGPath;
    CGFloat l = side * 0.38;
    _label.frame = CGRectMake(mid.x - l / 2, mid.y - l / 2, l, l);
    _label.cornerRadius = l / 2;
    _labelRing.frame = d;
    _labelRing.path = [UIBezierPath bezierPathWithArcCenter:mid radius:l / 2 startAngle:0 endAngle:2 * M_PI clockwise:YES].CGPath;
    CGFloat h = MAX(3, side * 0.02);
    _hole.frame = d;
    _hole.path = [UIBezierPath bezierPathWithArcCenter:mid radius:h startAngle:0 endAngle:2 * M_PI clockwise:YES].CGPath;
    _sheen.frame = sq;
    UIBezierPath *m = [UIBezierPath bezierPathWithOvalInRect:(CGRect){CGPointZero, sq.size}];
    [m appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectInset((CGRect){CGPointZero, sq.size}, (side - l) / 2, (side - l) / 2)]];
    _sheenMask.frame = _sheen.bounds;
    _sheenMask.path = m.CGPath;
    self.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:sq].CGPath;
    [CATransaction commit];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [_link invalidate];
    _link = nil;
    if (!self.window) return;
    MRGVinylProxy *p = [MRGVinylProxy new];
    p.owner = self;
    _link = [CADisplayLink displayLinkWithTarget:p selector:@selector(frame:)];
    if ([_link respondsToSelector:@selector(setPreferredFramesPerSecond:)]) _link.preferredFramesPerSecond = NSProcessInfo.processInfo.isLowPowerModeEnabled ? 30 : 60;
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self startSpin];
    [self slowTick];
    [self fetchTempo];
}

- (void)startSpin {
    [_disc removeAnimationForKey:@"spin"];
    _disc.speed = 1;
    _disc.timeOffset = 0;
    _disc.beginTime = 0;
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    a.fromValue = @0;
    a.toValue = @(2 * M_PI);
    a.duration = _turn;
    a.repeatCount = HUGE_VALF;
    a.removedOnCompletion = NO;
    [_disc addAnimation:a forKey:@"spin"];
    _spinning = YES;
}

// Apple's pause and resume of a layer's animations: stopping keeps the record where it was.
- (void)setSpinning:(BOOL)on {
    if (on == _spinning) return;
    _spinning = on;
    if (!on) {
        CFTimeInterval t = [_disc convertTime:CACurrentMediaTime() fromLayer:nil];
        _disc.speed = 0;
        _disc.timeOffset = t;
    } else {
        CFTimeInterval paused = _disc.timeOffset;
        _disc.speed = 1;
        _disc.timeOffset = 0;
        _disc.beginTime = 0;
        _disc.beginTime = [_disc convertTime:CACurrentMediaTime() fromLayer:nil] - paused;
    }
}

- (void)settingsChanged {
    [self applyColors:NO];
    [self applyLabel];
    _sheen.hidden = !shine();
    // 0.6.7: turning BPM on fetches the playing song's tempo now (0.6.6 waited for the next song).
    NSString *playing = MRGNowPlaying()[@"uri"];
    if (followBPM() && playing.length && ![sTempoFor isEqualToString:playing]) { dispatch_async(dispatch_get_main_queue(), ^{ [self fetchTempo]; }); }
    double turn = turnSeconds();
    if (fabs(turn - _turn) > 0.01) {
        _turn = turn;
        BOOL was = _spinning;
        [self startSpin];
        if (!was) [self setSpinning:NO];
    }
    [self.tilt setNeedsLayout];
}

- (void)trackChanged {
    _shownImage = nil;   // the next tick reads the new cover
    _shownURL = nil;
    [self.tilt setNeedsLayout];
    [self fetchTempo];
}

// Follow BPM: the song's tempo, then the spin changes to match (the chosen speed until it comes, or if it never does).
- (void)fetchTempo {
    if (!followBPM()) return;
    NSString *uri = MRGNowPlaying()[@"uri"];
    if (!uri.length || [uri isEqualToString:sTempoFor]) { [self settingsChanged]; return; }
    sTempoFor = [uri copy];
    sTempo = 0;
    __weak typeof(self) weak = self;
    MRGWebTempo(uri, ^(double bpm) {
        if (![sTempoFor isEqualToString:uri]) return;
        sTempo = bpm;
        if (bpm > 0) MRGDJLog(@"vinyl: %.0f BPM, a turn every %.2fs", bpm, turnSeconds());
        [weak settingsChanged];
    });
    [self settingsChanged];
}

// The label: the cover art, or plain (the record's own tint, a ring and the hole), like a white-label pressing.
- (void)applyLabel {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (labelStyle() == 1) {
        _label.contents = nil;
        UIColor *c = recordColor() == 4 ? [UIColor colorWithWhite:0.15 alpha:1] : recordColor() == 0 ? [UIColor colorWithWhite:0.93 alpha:1] : MRGAccent();
        if (recordColor() == 1 && _colorImage) c = MRGNowVividColor(_colorImage) ?: c;
        _label.backgroundColor = c.CGColor;
    } else {
        _label.backgroundColor = MRGAccent().CGColor;
        if (_shownImage.CGImage) _label.contents = (__bridge id)_shownImage.CGImage;
    }
    [CATransaction commit];
}

// The record's colors: 0 black, 1 the cover's, 2 the accent, 3 clear red, 4 white.
static UIColor *shade(UIColor *c, CGFloat brightness, CGFloat alpha) {
    CGFloat h, sat, b, a;
    if (![c getHue:&h saturation:&sat brightness:&b alpha:&a]) return [UIColor colorWithWhite:brightness alpha:alpha];
    return [UIColor colorWithHue:h saturation:MIN(1, sat * 1.05) brightness:brightness alpha:alpha];
}
- (void)applyColors:(BOOL)imageChanged {
    NSInteger mode = recordColor();
    if (mode == _colorMode && !(mode == 1 && imageChanged)) return;
    UIColor *tint = nil;
    if (mode == 1) {
        UIImage *img = _shownImage ?: MRGNowCoverImage(self.tilt);
        if (img && img == _colorImage && mode == _colorMode) return;
        _colorImage = img;
        tint = img ? MRGNowVividColor(img) : nil;
        if (!tint) mode = 0;
    } else if (mode == 2) tint = MRGAccent();
    _colorMode = recordColor();
    [CATransaction begin];
    // 0.6.7 root cause of "record color changes nothing": these layers are inside the disc, whose speed is 0 whenever
    // the record stands still (paused, Low Power Mode). An implicit animation added to them then never runs, so the
    // record kept showing its old colors. A still record now changes at once; a spinning one fades over 0.6s.
    if (_spinning && _disc.speed > 0) [CATransaction setAnimationDuration:0.6];
    else [CATransaction setDisableActions:YES];
    UIColor *groove = [UIColor colorWithWhite:1 alpha:0.07], *ring = [UIColor colorWithWhite:0 alpha:0.85], *rim = [UIColor colorWithWhite:1 alpha:0.16];
    NSArray *base;
    UIColor *lit = [UIColor colorWithWhite:1 alpha:0.20], *soft = [UIColor colorWithWhite:1 alpha:0.09];
    switch (mode) {
        case 1: case 2:
            base = @[(id)shade(tint, 0.42, 1).CGColor, (id)shade(tint, 0.20, 1).CGColor, (id)shade(tint, 0.08, 1).CGColor];
            groove = [tint colorWithAlphaComponent:0.16];
            rim = [tint colorWithAlphaComponent:0.45];
            ring = shade(tint, 0.05, 0.8);
            lit = [shade(tint, 1, 1) colorWithAlphaComponent:0.26];
            break;
        case 3:
            base = @[(id)[UIColor colorWithRed:0.86 green:0.10 blue:0.16 alpha:0.86].CGColor, (id)[UIColor colorWithRed:0.62 green:0.04 blue:0.10 alpha:0.80].CGColor, (id)[UIColor colorWithRed:0.36 green:0.02 blue:0.06 alpha:0.86].CGColor];
            groove = [UIColor colorWithWhite:1 alpha:0.10];
            ring = [UIColor colorWithRed:0.25 green:0 blue:0.03 alpha:0.6];
            rim = [UIColor colorWithWhite:1 alpha:0.30];
            lit = [UIColor colorWithWhite:1 alpha:0.32];
            break;
        case 4:
            base = @[(id)[UIColor colorWithWhite:0.97 alpha:1].CGColor, (id)[UIColor colorWithWhite:0.88 alpha:1].CGColor, (id)[UIColor colorWithWhite:0.74 alpha:1].CGColor];
            groove = [UIColor colorWithWhite:0 alpha:0.08];
            ring = [UIColor colorWithWhite:0 alpha:0.22];
            rim = [UIColor colorWithWhite:0 alpha:0.14];
            lit = [UIColor colorWithWhite:1 alpha:0.5];
            soft = [UIColor colorWithWhite:1 alpha:0.25];
            break;
        default:
            base = @[(id)[UIColor colorWithWhite:0.20 alpha:1].CGColor, (id)[UIColor colorWithWhite:0.09 alpha:1].CGColor, (id)[UIColor colorWithWhite:0.04 alpha:1].CGColor];
            break;
    }
    _base.colors = base;
    _grooves.strokeColor = groove.CGColor;
    _rings.strokeColor = ring.CGColor;
    _rim.strokeColor = rim.CGColor;
    UIColor *clear = [lit colorWithAlphaComponent:0];
    _sheen.colors = @[(id)clear.CGColor, (id)lit.CGColor, (id)clear.CGColor, (id)clear.CGColor, (id)soft.CGColor, (id)clear.CGColor, (id)clear.CGColor];
    [CATransaction commit];
}

// The cover inside the tilt view: its biggest visible subview other than the record.
static UIView *coverIn(UIView *tilt) {
    UIView *best = nil;
    CGFloat side = MIN(tilt.bounds.size.width, tilt.bounds.size.height), bestArea = 0;
    for (UIView *s in tilt.subviews) {
        if ([s isKindOfClass:MRGVinylView.class] || s.hidden) continue;
        CGSize z = s.bounds.size;
        if (z.width < side * 0.8 || z.height < side * 0.8) continue;
        if (z.width * z.height > bestArea) { bestArea = z.width * z.height; best = s; }
    }
    return best;
}

// 0.5.4: the cover being followed. 0.5.2 looked it up every frame by size (at least 80% of the tilt view), so when
// Spotify shrank the cover's own frame to dismiss the player (pulling it down) or when it was mid-shrink, the lookup
// failed, the record fell back to no transform and was left behind at full size. Now the cover is found once and kept
// (weakly) whatever its size, until it leaves this tilt view's window or turns up in another cover's tilt view.
- (UIView *)trackedCover {
    UIView *tilt = self.tilt, *c = _cover;
    if (c && c.window && c.window == tilt.window && c != self) {
        Class tc = tiltClass();
        UIView *owner = nil;
        for (UIView *p = c.superview; p; p = p.superview) if (tc && [p isKindOfClass:tc]) { owner = p; break; }
        if (!owner || owner == tilt) return c;
    }
    c = coverIn(tilt);
    if (c) _cover = c;
    return c;
}

// Every frame: where the cover really is right now (its presentation layer, so any animation counts: Spotify's dismiss
// and its frame or spring changes, Vitrine's paused shrink, a swipe between songs), read in the tilt view's own space,
// and the record placed the same way relative to it. In the tilt view's unscaled space the stock cover is a square of the
// tilt view's side centered in it (the record is laid out against that); whatever maps that square onto the cover now
// is applied to the record about its own center. The record stays a subview of the tilt view, inside the player's
// sheet, so everything the sheet and the tilt view do carries it too; nothing is in window or screen coordinates.
- (void)frame:(CADisplayLink *)link {
    @try {
        UIView *tilt = self.tilt;
        if (!tilt || self.superview != tilt) return;
        UIView *cover = [self trackedCover];
        if (!cover) return;   // nothing to follow this frame: stays where it was
        CALayer *cl = (CALayer *)cover.layer.presentationLayer ?: cover.layer;
        CALayer *tl = (CALayer *)tilt.layer.presentationLayer ?: tilt.layer;
        CGRect cb = cl.bounds;
        CGPoint m = CGPointMake(CGRectGetMidX(cb), CGRectGetMidY(cb));
        CGPoint P0 = [cl convertPoint:m toLayer:tl];
        CGPoint Px = [cl convertPoint:CGPointMake(m.x + cb.size.width / 2, m.y) toLayer:tl];
        CGPoint Py = [cl convertPoint:CGPointMake(m.x, m.y + cb.size.height / 2) toLayer:tl];
        CGSize S = tilt.bounds.size;
        CGFloat half = MIN(S.width, S.height) / 2;
        if (half < 1 || !isfinite(P0.x) || !isfinite(Px.x) || !isfinite(Py.y)) return;
        // Linear part: the stock cover's half-axes onto the cover's half-axes now. A square cover keeps the record round.
        CGFloat a = (Px.x - P0.x) / half, b = (Px.y - P0.y) / half, c = (Py.x - P0.x) / half, d = (Py.y - P0.y) / half;
        if (!isfinite(a) || !isfinite(d) || fabs(a * d - b * c) < 1e-4) return;
        // The stock cover's center (cc0) goes to P0; the record turns about its own center vc:
        // vc + L(p - vc) + T = P0 + L(p - cc0)  =>  T = P0 - vc + L(vc - cc0).
        CGPoint cc0 = CGPointMake(S.width / 2, S.height / 2), vc = self.center;
        CGFloat dx = vc.x - cc0.x, dy = vc.y - cc0.y;
        CGAffineTransform M = CGAffineTransformMake(a, b, c, d, P0.x - vc.x + a * dx + c * dy, P0.y - vc.y + b * dx + d * dy);
        float op = cl.opacity;
        CGFloat q = 0.25;   // ignore sub-quarter-point jitter
        BOOL same = fabs(M.a - _lastM.a) < 1e-4 && fabs(M.b - _lastM.b) < 1e-4 && fabs(M.c - _lastM.c) < 1e-4 && fabs(M.d - _lastM.d) < 1e-4
            && fabs(M.tx - _lastM.tx) < q && fabs(M.ty - _lastM.ty) < q && fabs(op - _lastOpacity) < 0.01 && _followed;
        if (!same) {
            _followed = YES;
            _lastM = M;
            _lastOpacity = op;
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [self.layer removeAnimationForKey:@"mrg.follow"];
            self.transform = M;
            self.layer.opacity = op;
            [CATransaction commit];
        }
        if (++_frames % 30 == 0) [self slowTick];
    } @catch (NSException *e) {
        MRGDJLog(@"vinyl: frame threw %@", e.reason);
    }
}

- (void)slowTick {
    @try {
        if (!self.window) return;
        if (!_disc.animationKeys.count) [self startSpin];
        // Low Power Mode: the record holds still (it still follows the cover), like the other animated add-ons.
        [self setSpinning:MRGPlayerIsPlaying() && !NSProcessInfo.processInfo.isLowPowerModeEnabled];
        UIImage *img = coverImage([self trackedCover] ?: self.tilt, 0);
        if (img && img != _shownImage && img.CGImage) {
            _shownImage = img;
            _label.contents = labelStyle() == 1 ? nil : (__bridge id)img.CGImage;
            [self applyColors:YES];
            [self applyLabel];
        } else if (_colorMode < 0) [self applyColors:NO]; else if (!img && !_label.contents) {
            NSDictionary *now = MRGNowPlaying();
            NSString *url = [now[@"image"] isKindOfClass:NSString.class] ? now[@"image"] : nil;
            if (url.length && ![url isEqualToString:_shownURL] && [url hasPrefix:@"https://"]) {
                _shownURL = url;
                __weak MRGVinylView *weak = self;
                [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
                    UIImage *got = data.length ? [UIImage imageWithData:data] : nil;
                    if (got) dispatch_async(dispatch_get_main_queue(), ^{ MRGVinylView *s = weak; if (s && !s->_shownImage && labelStyle() != 1) s->_label.contents = (__bridge id)got.CGImage; });
                }] resume];
            }
        }
    } @catch (NSException *e) {
        MRGDJLog(@"vinyl: tick threw %@", e.reason);
    }
}
@end

@implementation MRGVinylProxy
- (void)frame:(CADisplayLink *)link { MRGVinylView *o = self.owner; if (o) [o frame:link]; else [link invalidate]; }
@end

#pragma mark - the sleeve's finish

// On the cover itself (it moves with it): glossy is a light sweep and a lit edge; worn is ring wear where the record
// pressed through, scuffed edges and a soft crease. Plain is nothing.
@interface MRGVinylSleeve : UIView
@property (nonatomic) NSInteger style;
@property (nonatomic) CGFloat dir;
@end
@implementation MRGVinylSleeve {
    CAGradientLayer *_gloss;
    CAShapeLayer *_edge, *_wear, *_crease;
    CGSize _built;
    NSInteger _builtStyle;
    CGFloat _builtDir;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.clipsToBounds = YES;
    self.layer.zPosition = 3;
    self.accessibilityElementsHidden = YES;
    _gloss = [CAGradientLayer layer];
    _gloss.startPoint = CGPointMake(0, 0);
    _gloss.endPoint = CGPointMake(1, 1);
    _edge = [CAShapeLayer layer];
    _edge.fillColor = nil;
    _wear = [CAShapeLayer layer];
    _wear.fillColor = nil;
    _crease = [CAShapeLayer layer];
    _crease.fillColor = nil;
    for (CALayer *l in @[_gloss, _wear, _crease, _edge]) [self.layer addSublayer:l];
    _builtStyle = -1;
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    if (CGSizeEqualToSize(b.size, _built) && _style == _builtStyle && _dir == _builtDir) return;
    _built = b.size; _builtStyle = _style; _builtDir = _dir;
    UIView *cover = self.superview;
    CGFloat r = cover.layer.cornerRadius;
    for (UIView *s in cover.subviews) if (s != self && s.layer.cornerRadius > r) r = s.layer.cornerRadius;
    self.layer.cornerRadius = r;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *l in @[_gloss, _edge, _wear, _crease]) { l.frame = b; l.hidden = YES; }
    CGFloat side = MIN(b.size.width, b.size.height);
    if (_style == 1) {
        _gloss.hidden = NO;
        _gloss.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.42].CGColor, (id)[UIColor colorWithWhite:1 alpha:0.10].CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor, (id)[UIColor colorWithWhite:1 alpha:0.0].CGColor, (id)[UIColor colorWithWhite:1 alpha:0.08].CGColor];
        _gloss.locations = @[@0, @0.28, @0.42, @0.8, @1];
        _edge.hidden = NO;
        _edge.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, 0.75, 0.75) cornerRadius:MAX(0, r - 0.75)].CGPath;
        _edge.strokeColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        _edge.lineWidth = 1.5;
    } else if (_style == 2) {
        _wear.hidden = NO;
        CGPoint c = CGPointMake(CGRectGetMidX(b) + _dir * side * 0.03, CGRectGetMidY(b));
        _wear.path = [UIBezierPath bezierPathWithArcCenter:c radius:side * 0.41 startAngle:0 endAngle:2 * M_PI clockwise:YES].CGPath;
        _wear.strokeColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
        _wear.lineWidth = side * 0.035;
        _wear.lineDashPattern = @[@(side * 0.22), @(side * 0.03), @(side * 0.12), @(side * 0.05)];
        _edge.hidden = NO;
        _edge.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, 1.5, 1.5) cornerRadius:MAX(0, r - 1.5)].CGPath;
        _edge.strokeColor = [UIColor colorWithWhite:0.95 alpha:0.32].CGColor;
        _edge.lineWidth = 3;
        _edge.lineDashPattern = @[@(side * 0.05), @(side * 0.012), @(side * 0.11), @(side * 0.02)];
        _crease.hidden = NO;
        UIBezierPath *k = [UIBezierPath bezierPath];
        [k moveToPoint:CGPointMake(b.size.width * 0.68, 0)];
        [k addQuadCurveToPoint:CGPointMake(b.size.width, b.size.height * 0.30) controlPoint:CGPointMake(b.size.width * 0.86, b.size.height * 0.12)];
        _crease.path = k.CGPath;
        _crease.strokeColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
        _crease.lineWidth = 1.2;
    }
    [CATransaction commit];
}
@end

static void placeSleeve(UIView *tilt, UIView *cover, CGFloat dir) {
    MRGVinylSleeve *sleeve = objc_getAssociatedObject(tilt, &kSleeveKey);
    NSInteger style = sleeveStyle();
    if (style <= 0 || !cover) { [sleeve removeFromSuperview]; return; }
    if (!sleeve) { sleeve = [MRGVinylSleeve new]; objc_setAssociatedObject(tilt, &kSleeveKey, sleeve, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    sleeve.style = style;
    sleeve.dir = dir;
    if (sleeve.superview != cover) {
        sleeve.frame = cover.bounds;
        sleeve.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [cover addSubview:sleeve];
    } else if (!CGRectEqualToRect(sleeve.frame, cover.bounds)) sleeve.frame = cover.bounds;
    [sleeve setNeedsLayout];
}

#pragma mark - placing it

static void restore(UIView *tilt) {
    MRGVinylView *vinyl = objc_getAssociatedObject(tilt, &kVinylKey);
    NSValue *ours = objc_getAssociatedObject(tilt, &kOursKey);
    if (ours && CGAffineTransformEqualToTransform(tilt.transform, ours.CGAffineTransformValue)) {
        if (tilt.window && CACurrentMediaTime() < sg_glideUntil) [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{ tilt.transform = CGAffineTransformIdentity; } completion:nil];
        else tilt.transform = CGAffineTransformIdentity;
    }
    NSNumber *clip = objc_getAssociatedObject(tilt, &kClipKey);
    if (clip) tilt.clipsToBounds = clip.boolValue;
    NSHashTable *unclipped = objc_getAssociatedObject(tilt, &kUnclippedKey);
    for (UIView *v in unclipped.allObjects) v.clipsToBounds = YES;
    objc_setAssociatedObject(tilt, &kUnclippedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [vinyl removeFromSuperview];
    [(UIView *)objc_getAssociatedObject(tilt, &kSleeveKey) removeFromSuperview];
    objc_setAssociatedObject(tilt, &kSleeveKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tilt, &kVinylKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tilt, &kOursKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tilt, &kClipKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// The sleeve's scale (of the tilt view) and its shift, in the tilt view's superview. 0.5.4: the room is the screen's
// width (or the cover cell's, if narrower) less kMargin each side, and the sleeve plus the record peeking past it fill all
// of it, centered: about a 305pt cover and a 61pt peek on a 390pt iPhone. Unlike 0.5.3 the sleeve may be bigger than
// Spotify's own art; it is only kept from growing past the vertical room the cover cell gives it (at least the stock
// art's height), so it never reaches the title row. Sizes only (no positions on screen), so a swipe between songs or
// pulling the player down never changes it mid-move.
typedef struct { CGFloat scale, tx, cover, room, cellW, winW, vroom; } MRGVinylFitInfo;
static MRGVinylFitInfo vinylFit(UIView *tilt, CGFloat dir) {
    MRGVinylFitInfo f = {0};
    CGSize S = tilt.bounds.size;
    CGFloat side = MIN(S.width, S.height);
    UIView *sup = tilt.superview;
    CGPoint c = tilt.center;
    f.winW = tilt.window ? tilt.window.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    CGFloat mid = c.x, w = f.winW;
    f.vroom = side;
    UIView *cell = nil;
    Class cc = cellClass();
    for (UIView *p = tilt.superview; p && cc; p = p.superview) if ([p isKindOfClass:cc]) { cell = p; break; }
    if (cell && sup) {
        CGRect r = [cell convertRect:cell.bounds toView:sup];
        if (isfinite(r.origin.x) && isfinite(r.size.width) && r.size.width > 0 && isfinite(r.size.height)) {
            f.cellW = r.size.width;
            if (w <= 0 || r.size.width < w) w = r.size.width;
            mid = CGRectGetMidX(r);
            CGFloat up = c.y - CGRectGetMinY(r), down = CGRectGetMaxY(r) - c.y;
            if (up > 0 && down > 0) f.vroom = MAX(side, 2 * MIN(up, down));
        }
    }
    if (w <= 0) w = S.width + 2 * kMargin;
    f.room = w - 2 * kMargin;
    CGFloat cover = f.room / (1 + kPeek);
    cover = MIN(cover, f.vroom);
    cover = MAX(cover, side * kMinCover);
    cover = round(cover * 2) / 2;
    f.cover = cover;
    CGFloat coverMid = mid - dir * cover * kPeek / 2;
    f.scale = cover / side;
    f.tx = round((coverMid - c.x) * 2) / 2;
    return f;
}

static void MRGVinylApply(UIView *tilt) {
    @try {
        if (!tilt || tilt.bounds.size.width < 200) return;
        if (!MRGAddonInstalled(@"vinyl")) {
            if (objc_getAssociatedObject(tilt, &kVinylKey)) { restore(tilt); logState(@"off, Now Playing is stock again"); }
            return;
        }
        CGSize S = tilt.bounds.size;
        CGFloat side = MIN(S.width, S.height);
        if (side < 150 || !isfinite(side)) return;
        CGFloat dir = MRGVinylOnLeft() ? -1 : 1;
        // In the superview: the sleeve plus the record showing make one piece, centered in the cover cell's width.
        MRGVinylFitInfo fit = vinylFit(tilt, dir);
        CGFloat cover = fit.cover;
        CGAffineTransform t = CGAffineTransformMake(fit.scale, 0, 0, fit.scale, fit.tx, 0);
        NSValue *ours = objc_getAssociatedObject(tilt, &kOursKey);
        CGAffineTransform now = tilt.transform;
        BOOL mine = CGAffineTransformIsIdentity(now) || (ours && CGAffineTransformEqualToTransform(now, ours.CGAffineTransformValue));
        if (mine && CATransform3DIsAffine(tilt.layer.transform) && !CGAffineTransformEqualToTransform(now, t)) {
            // Turned on or the side changed: glide there. A layout pass that only re-asserts it changes nothing.
            BOOL glide = tilt.window && CACurrentMediaTime() < sg_glideUntil;
            if (glide) [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{ tilt.transform = t; } completion:nil];
            else tilt.transform = t;
            objc_setAssociatedObject(tilt, &kOursKey, [NSValue valueWithCGAffineTransform:t], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if (mine && CGAffineTransformEqualToTransform(now, t) && !ours) {
            objc_setAssociatedObject(tilt, &kOursKey, [NSValue valueWithCGAffineTransform:t], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }   // else Spotify is tilting the cover right now: left alone, taken back on a later pass

        // The record overhangs the tilt view's edge, so the tilt view must not clip (Spotify's doesn't; checked anyway).
        if (tilt.clipsToBounds) {
            if (!objc_getAssociatedObject(tilt, &kClipKey)) objc_setAssociatedObject(tilt, &kClipKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            tilt.clipsToBounds = NO;
            logState(@"the cover clipped its edges; unclipped for the record");
        }
        // The bigger piece can reach past the tilt view's own width, so the views between it and the cover cell must not
        // clip the record either. Held weakly; clipped again when the add-on is turned off.
        Class cc = cellClass();
        for (UIView *p = tilt.superview; p && cc && ![p isKindOfClass:cc]; p = p.superview) {
            if (!p.clipsToBounds) continue;
            NSHashTable *unclipped = objc_getAssociatedObject(tilt, &kUnclippedKey);
            if (!unclipped) { unclipped = [NSHashTable weakObjectsHashTable]; objc_setAssociatedObject(tilt, &kUnclippedKey, unclipped, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
            [unclipped addObject:p];
            p.clipsToBounds = NO;
        }

        MRGVinylView *vinyl = objc_getAssociatedObject(tilt, &kVinylKey);
        BOOL fresh = vinyl == nil;
        if (fresh) {
            vinyl = [MRGVinylView new];
            objc_setAssociatedObject(tilt, &kVinylKey, vinyl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        vinyl.tilt = tilt;
        vinyl.dir = dir;
        // In the tilt view's own (unscaled) space the sleeve is the whole tilt view.
        CGFloat disc = side * kDisc;
        CGRect bounds = CGRectMake(0, 0, disc, disc);
        CGPoint center = CGPointMake(S.width / 2 + dir * (side / 2 + side * kPeek - disc / 2), S.height / 2);
        [UIView performWithoutAnimation:^{
            if (!CGRectEqualToRect(vinyl.bounds, bounds)) vinyl.bounds = bounds;
            if (!CGPointEqualToPoint(vinyl.center, center)) vinyl.center = center;
        }];
        if (vinyl.superview != tilt) [tilt insertSubview:vinyl atIndex:0];
        else if (tilt.subviews.firstObject != vinyl) [tilt sendSubviewToBack:vinyl];
        placeSleeve(tilt, coverIn(tilt), dir);
        if (fresh && tilt.window && CACurrentMediaTime() < sg_glideUntil) {
            vinyl.alpha = 0;
            [UIView animateWithDuration:0.35 animations:^{ vinyl.alpha = 1; }];
        }
        CGRect tf = tilt.window ? [tilt.superview convertRect:tilt.frame toView:nil] : CGRectZero;
        logState([NSString stringWithFormat:@"on, art %.0fx%.0fpt, window %.0fpt, cell %.0fpt, room %.0fpt, vroom %.0fpt -> sleeve %.0fpt (x%.3f, shift %.1f), record %.0fpt peeking %.0fpt on the %@; sleeve on screen {%.0f,%.0f %.0fx%.0f}", S.width, S.height, fit.winW, fit.cellW, fit.room, fit.vroom, cover, fit.scale, fit.tx, side * kDisc * fit.scale, cover * kPeek, dir > 0 ? @"right" : @"left", tf.origin.x, tf.origin.y, tf.size.width, tf.size.height]);
    } @catch (NSException *e) {
        MRGDJLog(@"vinyl: layout threw %@, Now Playing stays stock", e.reason);
        @try { restore(tilt); } @catch (NSException *e2) {}
    }
}

%group MRGVinylHooks
%hook _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
- (void)layoutSubviews {
    %orig;
    UIView *tilt = (UIView *)self;
    if (tilt.bounds.size.width < 200) return;
    if (!MRGAddonInstalled(@"vinyl") && !objc_getAssociatedObject(tilt, &kVinylKey)) return;
    if (inPlayerCell(tilt)) MRGVinylApply(tilt);
}
- (void)didMoveToWindow {
    %orig;
    UIView *tilt = (UIView *)self;
    if (tilt.window && tilt.bounds.size.width >= 200 && MRGAddonInstalled(@"vinyl") && inPlayerCell(tilt)) [tilt setNeedsLayout];
}
%end

%hook _TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl
- (void)layoutSubviews {
    %orig;
    UIView *cell = (UIView *)self;
    UIView *tilt = findTilt(cell, 0);
    if (tilt && (MRGAddonInstalled(@"vinyl") || objc_getAssociatedObject(tilt, &kVinylKey))) MRGVinylApply(tilt);
}
%end
%end

// Turning the add-on on or off, or changing its settings, re-lays the covers on screen.
static void relayAll(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
            NSUInteger seen = 0;
            while (stack.count && seen < 4000) {
                UIView *v = stack.lastObject; [stack removeLastObject]; seen++;
                if (tiltClass() && [v isKindOfClass:tiltClass()] && v.bounds.size.width >= 200) { if (inPlayerCell(v)) MRGVinylApply(v); continue; }
                [stack addObjectsFromArray:v.subviews];
            }
        }
    }
}

@interface MRGVinylAddon : NSObject <MRGAddon>
@end
@implementation MRGVinylAddon
- (NSString *)addonID { return @"vinyl"; }
- (NSString *)addonName { return @"Vinyl"; }
- (NSString *)addonCategory { return @"Now Playing"; }
- (NSString *)addonVersion { return @"1.2"; }
- (NSString *)addonDescription { return @"The Now Playing cover becomes a sleeve with a spinning record peeking out."; }
- (NSArray<MRGAddonSetting *> *)addonSettings {
    MRGAddonSetting *speed = [MRGAddonSetting picker:@"mirage.addon.vinyl.turn" title:@"Spin speed" options:@[@"Slow", @"33⅓ RPM", @"45 RPM"] values:@[@4.0, @1.8, @1.33] fallback:@1.8];
    MRGAddonSetting *side = [MRGAddonSetting picker:@"mirage.addon.vinyl.left" title:@"Record side" options:@[@"Left", @"Right"] values:@[@YES, @NO] fallback:@NO];
    MRGAddonSetting *color = [MRGAddonSetting picker:@"mirage.addon.vinyl.color" title:@"Record color" options:@[@"Black", @"From the cover", @"Accent", @"Clear red", @"White"] values:@[@0, @1, @2, @3, @4] fallback:@0];
    MRGAddonSetting *sleeve = [MRGAddonSetting picker:@"mirage.addon.vinyl.sleeve" title:@"Sleeve" options:@[@"Plain", @"Glossy", @"Worn"] values:@[@0, @1, @2] fallback:@0];
    MRGAddonSetting *bpm = [MRGAddonSetting toggle:@"mirage.addon.vinyl.bpm" title:@"Spin to the song's BPM" fallback:NO];
    bpm.footer = @"Spotify keeps a song's BPM from many apps; when it does, the record turns at the speed above.";
    MRGAddonSetting *peek = [MRGAddonSetting picker:@"mirage.addon.vinyl.peek" title:@"Record showing" options:@[@"Less", @"Normal", @"More"] values:@[@0.12, @0.20, @0.30] fallback:@0.20];
    MRGAddonSetting *label = [MRGAddonSetting picker:@"mirage.addon.vinyl.label" title:@"Label" options:@[@"Album art", @"Plain"] values:@[@0, @1] fallback:@0];
    MRGAddonSetting *gleam = [MRGAddonSetting toggle:@"mirage.addon.vinyl.shine" title:@"Light on the record" fallback:YES];
    return @[speed, bpm, side, peek, color, label, sleeve, gleam];
}
- (void)addonDidEnable {}
- (void)addonDidDisable {}
- (NSString *)addonSummary {
    double s = MRGVinylSecondsPerTurn();
    NSArray *colors = @[@"Black", @"Cover", @"Accent", @"Red", @"White"];
    NSInteger c = MIN(4, MAX(0, recordColor()));
    return [NSString stringWithFormat:@"%@ · %@ · %@", followBPM() ? @"BPM" : s > 2.5 ? @"Slow" : s > 1.5 ? @"33⅓ RPM" : @"45 RPM", colors[c], MRGVinylOnLeft() ? @"Left" : @"Right"];
}
@end

%ctor {
    MRGAddonRegister([MRGVinylAddon new]);
    if (cellClass() && tiltClass() && MRGFragileHooksAllowed(@"Vinyl")) {
        %init(MRGVinylHooks);
        [NSNotificationCenter.defaultCenter addObserverForName:MRGSettingsChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            static NSString *last;
            NSString *now = [NSString stringWithFormat:@"%d%d%ld%.2f", MRGAddonInstalled(@"vinyl"), MRGVinylOnLeft(), (long)sleeveStyle(), peekAmount()];
            if ([now isEqualToString:last]) return;   // another setting: nothing to move
            last = now;
            sg_glideUntil = CACurrentMediaTime() + 0.6;
            @try { relayAll(); } @catch (NSException *e) {}
        }];
    }
}
