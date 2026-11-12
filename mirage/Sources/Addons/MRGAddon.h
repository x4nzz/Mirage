// The add-on framework. An add-on is a feature that ships inside Mirage (the shop never downloads code):
// an id, a name, a category, a version, a description, default settings, a settings schema the shop
// renders on its own, and enable/disable hooks. Installed state stays mirage.addon.<id>, the same
// switch the shop has always used.
//
// A launch that dies inside an add-on's enable hook leaves a flag set. The next launch turns that
// add-on off and the shop says so. A hook that throws is turned off immediately, the same way.
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, MRGAddonControl) {
    MRGAddonControlToggle = 0,
    MRGAddonControlSlider,
    MRGAddonControlPicker,
    MRGAddonControlColor,   // stored as 0xRRGGBB
};

@interface MRGAddonSetting : NSObject
@property (nonatomic, copy) NSString *key;          // "mirage.*" used as-is, otherwise mirage.addon.<id>.<key>
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *footer;
@property (nonatomic) MRGAddonControl control;
@property (nonatomic, strong) id fallback;          // used when nothing is stored
@property (nonatomic) double minimum;
@property (nonatomic) double maximum;
@property (nonatomic, copy) NSArray<NSString *> *options;
@property (nonatomic, copy) NSArray *values;        // picker: one stored value per option
+ (instancetype)toggle:(NSString *)key title:(NSString *)title fallback:(BOOL)on;
+ (instancetype)slider:(NSString *)key title:(NSString *)title min:(double)min max:(double)max fallback:(double)v;
+ (instancetype)picker:(NSString *)key title:(NSString *)title options:(NSArray<NSString *> *)options values:(NSArray *)values fallback:(id)fallback;
+ (instancetype)color:(NSString *)key title:(NSString *)title fallbackRGB:(NSInteger)rgb;
@end

@protocol MRGAddon <NSObject>
- (NSString *)addonID;
- (NSString *)addonName;
- (NSString *)addonCategory;
- (NSString *)addonVersion;
- (NSString *)addonDescription;
- (NSArray<MRGAddonSetting *> *)addonSettings;   // empty when the add-on has no settings of its own
- (void)addonDidEnable;
- (void)addonDidDisable;
@optional
- (NSString *)addonSummary;                      // the settings row's detail, nil to leave it blank
@end

void MRGAddonRegister(id<MRGAddon> addon);
// Runs the enable/disable hook. A throw while enabling turns the add-on off and records a shop notice.
void MRGAddonRunEnable(NSString *addonID);
void MRGAddonRunDisable(NSString *addonID);
NSArray<id<MRGAddon>> *MRGRegisteredAddons(void);
id<MRGAddon> MRGAddonObject(NSString *addonID);

NSString *MRGAddonSettingKey(NSString *addonID, NSString *key);
id MRGAddonValue(NSString *addonID, MRGAddonSetting *setting);
void MRGAddonSetValue(NSString *addonID, MRGAddonSetting *setting, id value);

BOOL MRGAddonFlag(NSString *addonID, NSString *key, BOOL fallback);
void MRGAddonSetFlag(NSString *addonID, NSString *key, BOOL on);
double MRGAddonNumber(NSString *addonID, NSString *key, double fallback);
void MRGAddonSetNumber(NSString *addonID, NSString *key, double value);
NSInteger MRGAddonInteger(NSString *addonID, NSString *key, NSInteger fallback);
void MRGAddonSetInteger(NSString *addonID, NSString *key, NSInteger value);

UIViewController *MRGAddonSettingsPage(NSString *addonID);

// Set when an add-on was turned off because it crashed or threw. Nil otherwise.
NSString *MRGAddonCrashNotice(NSString *addonID);
void MRGAddonClearCrashNotice(NSString *addonID);

// Low Power Mode, or Spotify not in the foreground: animated work should stop.
BOOL MRGEffectsPaused(void);

// The shop's first section (the theme marketplace). rows of 0 hides it.
void MRGSetShopHeader(NSString *title, NSInteger rows,
                      UITableViewCell *(^cell)(UITableView *table, NSInteger row),
                      void (^select)(UIViewController *shop, NSInteger row),
                      NSString *(^footer)(void));
NSString *MRGShopHeaderTitle(void);
NSInteger MRGShopHeaderRows(void);
UITableViewCell *MRGShopHeaderCell(UITableView *table, NSInteger row);
void MRGShopHeaderSelect(UIViewController *shop, NSInteger row);
NSString *MRGShopHeaderFooter(void);

UIColor *MRGColorFromRGB(NSInteger rgb);
NSInteger MRGRGBFromColor(UIColor *color);
