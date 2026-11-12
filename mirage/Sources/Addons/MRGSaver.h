#import <UIKit/UIKit.h>
UIViewController *MRGSaverPage(void);
// The keychain copy of the settings (no API keys, no history): "Keychain · last saved <time>" for About, and a restore
// that applies it (completion on the main thread).
NSString *MRGSettingsBackupSummary(void);
void MRGSettingsRestoreBackup(void (^done)(NSUInteger restored, NSString *error));
