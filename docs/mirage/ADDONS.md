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
theme is code, from this repo or from anywhere else. The catalog that ships in the app is
[`addons/themes/catalog.json`](../../addons/themes/catalog.json) (ten themes). The marketplace is the first
section of the shop: tap a theme to preview it, apply it, or remove it. A theme's `dynamicColors` flag says
whether the dynamic colors add-on may replace its accent.

The shop can also fetch `https://raw.githubusercontent.com/x4nzz/Mirage/main/addons/themes/catalog.json`.
Every theme in that file is checked (only the known keys, colors as `#RRGGBB`, no paths) and a theme that
doesn't pass is dropped. **Download theme list** turns the fetch off. Off, or a fetch that fails, shows the
bundled catalog and says so.

## 0.6.2: lyrics shelf, add-ons on the main page

- **Pop-up lyrics 2.0** is a shelf at the top of Home, not an overlay. Mirage adds the card's height to
  the top inset of Home's feed (`Home_CarouselKit.TouchCancellingCollectionView`) and puts the card in
  that room, so the shelves below move down and the card scrolls with them. When Spotify sets its own
  inset again, Mirage adds the room back on top of it. The room closes (animated) when there are no
  synced lyrics, an ad is playing, nothing is playing, or the add-on is off. The active line is large and
  bright, the lines around it are smaller, dimmer and softly blurred, and the column springs to each new
  line. Settings: text size (18–30) and lines shown (3, 4 or 5). Tapping the card opens the player
  through Spotify's now playing bar. In Low Power Mode or with Reduce Motion the lines change without
  the spring or the blur, and the clock ticks twice a second instead of ten times.
- **Add-ons on the main Mirage page**: every built-in add-on is a row with its icon, state, an on/off
  switch (the same hooks as the shop) and a chevron into its settings. The shop stays for browsing.
- **Polish**: icon tiles on every settings row, a header on the main page, icon tiles on shop cards, and
  one finish on all preview art.
- **Version check**: About → Version reads `0.6.2 (date time)` and every launch logs
  `Mirage <version> (<build date>) loaded` to the DJ log and the system log.

## 0.6.1: the shop and what changed per add-on

**The shop.** Each card shows its own preview, drawn on the phone in the accent color (`MRGAddonArt.m`; no
download, the index's `preview` URL is only used for an add-on this build doesn't draw). A card has one control,
a switch; the label next to it reads the stored state (**On** / **Off**) and an **ON** badge sits on the picture
while it's on. There is no separate Get button any more. The Settings row appears under a card only while that
add-on is on. Switching takes effect immediately (the enable/disable hook runs) and is saved.

**Settings save themselves.** Every write goes through to disk as it's made, and the Mirage settings (never API
keys, listening history, or per-launch flags like `.launching`) are also copied to
`Documents/Mirage/settings-autosave.plist` after each change and whenever Spotify leaves the screen. If Spotify's
defaults come back empty, that copy is restored at launch before any add-on starts. Save & load stays for files
and presets; loading one now also starts or stops the add-ons it changes.

| Add-on | 0.6.1 fix |
|---|---|
| all | Leaving Spotify within 12 s of launch no longer counts as a launch crash (it used to turn every add-on off at the next launch). |
| `trash` | The Now Playing button sat on top of Spotify's ⌄ minimize button; it's now beside it. Shows/hides on the switch. A track trashed from another song's menu gets its own name. |
| `shuffle-plus` | Also triggered by the player state's shuffle flag, so Spotify's own shuffle button works; turning shuffle or Shuffle+ off clears the queue it filled. |
| `popup-lyrics` | Appears and disappears on Home right away; its timer follows Low Power Mode live; lyrics requested once per song. |
| `playlist-tools` | Removing an exact duplicate (same URI) removed the original too; such playlists are rewritten in order instead. |
| `genres` | A failed lookup isn't cached as "no genres"; a late answer isn't shown on the next song. |
| `vinyl` | Holds still in Low Power Mode. |
| `dynamic-colors` | No change; it now starts right away when a preset turns it on. |

## Shipped in 0.6.0

| Id | What |
|---|---|
| `vinyl` | Now Playing record. Spin speed and side, same keys as before. |
| `dynamic-colors` | Cover color on the accent, toggles, and Vitrine's glass. |
| `shuffle-plus` | Playlist and album shuffle through Spotify's queue. |
| `trash` | Skip trashed songs, including in the AI DJ. |
| `popup-lyrics` | Synced lyrics at the top of Home, from Vitrine's lyrics. |
| `genres` | Genres on Now Playing. |
| `playlist-tools` | Sort, duplicates, shuffled copy. |

Themes are not add-ons. They are the marketplace at the top of the shop.

## Vinyl (Now Playing)

The cover shrinks and moves to one side, and a record peeks out from behind it. The record spins while a
song plays and stops when you pause; its label is the album art, and the grooves and light are drawn in
code. It follows the cover's real position and size every frame, including while the player is pulled
down. Settings: spin speed (Slow, 33⅓ RPM, 45 RPM) and which side the record is on. Those are the schema
rows, stored at the same keys as before (`mirage.addon.vinyl.turn`, `mirage.addon.vinyl.left`). If
Spotify's player changes and the cover can't be found, Now Playing stays stock and the DJ log says
`vinyl: player cover not found`.

Code: `mirage/Sources/MRGVinyl.x`.
