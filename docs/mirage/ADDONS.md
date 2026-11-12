# Mirage add-ons

The Add-on Shop (Settings → Mirage → Shop) lists add-ons. A copy of the list ships inside Mirage
(`addons/index.json`, also fetched from
`https://raw.githubusercontent.com/x4nzz/Mirage/main/addons/index.json`), and every add-on this build
registers is shown even when that list is older. Pull down in the shop to fetch it again. The shop works
offline.

**Add-ons are features that ship inside Mirage.** The shop never downloads and runs code. Turning one on
sets `mirage.addon.<id>` in Spotify's preferences and calls its enable hook; turning it off calls the
disable hook and puts Spotify back the way it was. An add-on listed in the index that this build doesn't
carry shows "Update Mirage".

The theme marketplace sits at the top of the shop, above the add-on list. Themes are data only. See
[Themes](#themes) once that section exists in this build.

If an add-on crashes while Spotify is opening, the next launch turns it off by itself and the shop shows
a notice under that add-on. Turn it back on to try again. A hook that throws is turned off immediately,
the same way, so one add-on can't keep taking Spotify down.

## Writing one

An add-on is an object that adopts `MRGAddon` (`mirage/Sources/Addons/MRGAddon.h`) and is registered from
its own constructor:

```objc
@interface MyAddon : NSObject <MRGAddon>
@end

@implementation MyAddon
- (NSString *)addonID { return @"my-addon"; }          // mirage.addon.my-addon
- (NSString *)addonName { return @"My Addon"; }
- (NSString *)addonCategory { return @"Now Playing"; } // the shop's type line
- (NSString *)addonVersion { return @"1.0"; }
- (NSString *)addonDescription { return @"What it changes, in a sentence or two."; }
- (NSArray<MRGAddonSetting *> *)addonSettings {
    // Keys that start with "mirage." are stored as written. Any other key is stored as
    // mirage.addon.<id>.<key>. The shop renders this list on its own: toggles, sliders,
    // pickers (a segmented control) and a #RRGGBB color.
    MRGAddonSetting *speed = [MRGAddonSetting slider:@"speed" title:@"Speed" min:0.5 max:2 fallback:1];
    speed.footer = @"Shown under the row in the settings page.";
    return @[
        [MRGAddonSetting toggle:@"bold" title:@"Bold type" fallback:NO],
        speed,
        [MRGAddonSetting picker:@"side" title:@"Side" options:@[@"Left", @"Right"] values:@[@0, @1] fallback:@0],
    ];
}
- (void)addonDidEnable { /* start. Throw, and the shop turns the add-on off. */ }
- (void)addonDidDisable { /* put Spotify's views back. */ }
- (NSString *)addonSummary { return @"what the shop's Settings row shows"; }
@end

%ctor {
    MRGAddonRegister([MyAddon new]);
    // Logos hooks stay installed; gate the work on MRGAddonInstalled(@"my-addon").
}
```

Rules that keep Spotify up:

- Check each Spotify class with `NSClassFromString` and each selector with `respondsToSelector:` before
  sending it. Wrap the work in `@try`, or call through `MRGSafeRun`.
- Don't keep an unretained or strong pointer at a Spotify view. Store your view on Spotify's view with
  `objc_setAssociatedObject`, and hold Spotify's view weakly.
- Read settings with `MRGAddonFlag`, `MRGAddonNumber`, `MRGAddonInteger` or, for a schema row,
  `MRGAddonValue`. They post `MRGSettingsChangedNotification` when they change. Listen for that, and for
  `MRGPlayerTrackChangedNotification` when the song changes.
- `MRGEffectsPaused()` is true in Low Power Mode and while Spotify is not the foreground app. Stop
  display links, video and other animation while it is.
- Restore Spotify's own state in `addonDidDisable`.
- Gate every hook on `MRGAddonInstalled(@"<id>")`.

Then tell the shop about it:

1. The register call above is what makes it built-in (`MRGAddonBuiltIn`).
2. Add an entry to `addons/index.json` and the same entry to `kBundledIndex` in
   `mirage/Sources/MRGAddons.m`:

   ```json
   {
     "id": "my-addon",
     "name": "My Addon",
     "description": "What it changes, in a sentence or two.",
     "preview": "https://raw.githubusercontent.com/x4nzz/Mirage/main/addons/previews/my-addon.png",
     "version": "1.0",
     "type": "Now Playing",
     "author": "you",
     "min_mirage": "0.6.0"
   }
   ```

   `min_mirage` is the first Mirage version that carries it; older builds show "Update Mirage".
3. Add a 16:9 preview (1200×675 PNG) in `addons/previews/`. Previews are cached per id and version, so bump
   `version` when you change the picture. Until the picture is there, the shop draws its own placeholder.

The shop gives every installed add-on an on/off switch and, when `addonSettings` is not empty, a Settings
row that pushes the schema page. A custom page is a normal `UIViewController`; push it with `MRGPushPage`.

## Themes

Themes are JSON only: colors, an accent, a glass tint, and an optional background reference. Nothing in a
theme is code, from this repo or from anywhere else. The catalog ships in the app
(`addons/themes/catalog.json`). A remote index can be turned off in the marketplace; with it off, or when
it can't be reached, the bundled catalog is what you see.

## Vinyl (Now Playing)

The cover shrinks and moves to one side, and a record peeks out from behind it. The record spins while a
song plays and stops when you pause; its label is the album art, and the grooves and light are drawn in
code. It follows the cover's real position and size every frame, including while the player is pulled
down. Settings: spin speed (Slow, 33⅓ RPM, 45 RPM) and which side the record is on. Those are the schema
rows, stored at the same keys as before (`mirage.addon.vinyl.turn`, `mirage.addon.vinyl.left`). If
Spotify's player changes and the cover can't be found, Now Playing stays stock and the DJ log says
`vinyl: player cover not found`.

Code: `mirage/Sources/MRGVinyl.x`.
