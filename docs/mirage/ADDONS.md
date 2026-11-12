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

## 0.6.6: radio, focus, the queue, Now Playing add-ons, version resilience

New add-ons (all off by default, each with its own shop art and icon, settings on the Mirage page once on):

| Add-on | Where it shows | Its settings |
|---|---|---|
| **Radio** (Library) | runs in the background; Spotify's queue | its page: Start / Stop, Coming up, What it learned, Forget |
| **Focus mode** (Now Playing) | a ◎ button in the middle of the player's footer row (Connect · ◎ · queue) | Focus mode on, True black background, Keep the lyrics preview |
| **On repeat** (Library) | its page | Recently played / On repeat this week, Play all, Save as a playlist |
| **More like this** (Library) | its page | Like this song / Like this playlist, then Add them to the queue or Save as a new playlist |
| **Cover ring** (Now Playing) | a progress line around the player's cover | Color (Accent, From the cover, White), Thickness |
| **Lyrics backdrop** (Now Playing) | synced lines over the dimmed cover | Cover dimming, Text size (live) |
| **Queue tools** (Playback) | Play next / After this album in a song's ⋯ menu | its page: Spotify's queue, drag to reorder, swipe to remove or Play next |
| **Up Next** (Now Playing) | a row at the bottom of the cover; a card when you hold its middle | Row on the cover, Card on hold |

- **Radio** keeps three of its picks waiting in Spotify's real queue, refilled after every song and
  every 20 s. It's seeded from the artist playing (or your history) and artists like them. It learns
  per artist as you listen: a skip in the first 30 s weighs an artist down, a full play lifts them, and
  a like (the player's heart) lifts them more and brings in artists like them. Queued picks by an
  artist that sank are taken out and replaced. It never queues a trashed or repeated song or the same
  artist twice in a row. Starting another playlist yourself stops it; Spotify's own autoplay doesn't.
- **Focus mode** leaves only the cover, previous / play-pause / next, the queue and Connect, on true
  black. Everything else goes invisible in place (nothing moves) and comes back exactly as it was.
- **Shuffle+** now appears in Spotify's **Listening modes** sheet (9.1.90 opens it from a playlist's
  shuffle button) as a third row, with its icon, subtitle and a check while on. Picking it turns
  Smart Shuffle off through Spotify's plain Shuffle, then Shuffle+ takes over the queue.
- **Vinyl**: record color (Black, From the cover, Accent, Clear red, White; From the cover tints the
  base, grooves, rim and light per track) and sleeve (Plain, Glossy, Worn). **Spin to the song's BPM**
  takes one turn per four beats when Spotify gives the tempo, otherwise the speed you chose.
- **AI DJ → How much like me** (Light / Strong / Max): Talk like me now works from a counted profile
  of how you write (casing, the slang you use, stretched words, emoji, punctuation, length), taken
  from the chat and the vibe box. It only changes how the DJ talks. Facts still come only from real
  data, and lines read aloud have no emoji.
- **Version resilience**: see [COMPATIBILITY.md](COMPATIBILITY.md). On a Spotify build other than
  9.1.90 the fragile hooks stay off, and About → **Run on this Spotify anyway** turns them back on.
- Every add-on description is one line, and the shop shows the built-in add-on's own text.

Limits, honestly:

- Cover ring is a progress ring, not a waveform: Spotify gives the app no waveform data for a track.
- BPM spin depends on the Web API's audio features, which Spotify closed to many apps in 2024. When
  it refuses three times, Vinyl uses the chosen speed for the rest of the session.
- Automix is Premium-only on 9.1.90 and has no setting Mirage can reach, so Shuffle+ doesn't touch it.
- Spotify Free can refuse queue edits. Radio, Queue tools and More like this say so when it does.
- Lyrics backdrop needs Vitrine's synced lyrics.

## 0.6.5: new art, clearer lyrics glass, voices that sound different, keychain backup

- **Art.** Every shop cover and icon is redrawn in the Vinyl card's style: a soft blurred mesh-gradient ground,
  one glossy hero object with soft shadows, and fine grain (`scripts/mirage-art.py`, writes `MRGAddonArtData.m`).
- **Pop-up lyrics.** *Glass clarity* (clear ↔ frosted) and *Tint* sliders apply live while dragging. The default is
  clearer, and the lines get a subtle shadow so they stay readable on clear glass. `MRGAddonSetting.live` makes a
  slider post changes continuously.
- **Voices.** A preset no longer switches ElevenLabs (or the provider's voice) back to the free voice. Each preset
  picks its ElevenLabs model: whisper, soothing, spark, hype and late night use `eleven_v3` with an audio tag
  (`[whispers]` before every sentence for the whisper), v3's stability steps and ellipses instead of `<break/>`.
  If v3 is refused (HTTP 400/403/422) they fall back to `eleven_multilingual_v2` (which follows *style*) and then to
  `eleven_flash_v2_5`. Narrator and classic use multilingual v2. Soft & Close keeps flash first. Every request logs
  its model, stability, style and speed. The iPhone voice gets a per-preset volume. Each preset row has a Preview
  button.
- **Settings footers** are gone or down to one short line.
- **Keychain backup.** The autosave set (no API keys, no history) is also kept in the keychain item
  `com.x4nzz.mirage.settings` / `settings` (AfterFirstUnlock, not synced, default access group). It's restored at
  launch when the defaults and the autosave file are both empty. About → *Settings backup* shows the last save, and
  *Restore from backup* applies it by hand. Whether the item survives a reinstall depends on the signing team and
  access group: re-signing with another team (Ksign) or LiveContainer's keychain handling may hide it.

## 0.6.4: stability, safe mode, Shuffle+ on the shuffle button

Stability (what was freezing or crashing Spotify, and what changed):

- **Themes** swizzled every `UIColor` creation and parsed the theme JSON from defaults on each one. The
  theme is now cached under a lock and the swizzle reads two atomics.
- **Settings changes** were posted synchronously after a `-synchronize` on every write, re-laid out every
  background view, and Genres posted one on every song. Posts are now coalesced (50 ms), background
  relayout is coalesced (250 ms) and Genres no longer posts.
- **Autosave** reacted to `NSUserDefaultsDidChangeNotification` (Spotify writes defaults on every track),
  read all defaults and wrote a plist on the main thread. It now saves on its own queue, debounced, from
  Mirage's own changes and on background.
- **Dynamic colors** decode and sample the cover on a utility queue; **Genres** no longer walks the whole
  window on every Now Playing layout; **Trash** and **Pop-up lyrics** find their host views once.
- **Pop-up lyrics** used KVO on Home's `contentInset` to re-apply its room whenever Spotify set the inset,
  which Spotify does on every layout; the two could keep re-laying Home out. The room is now added and
  removed inside the feed's own `contentInset` accessors, so Spotify always reads back what it set.
- **Shuffle+** ordered the whole playlist on the main thread with an O(n²) artist search; ordering now
  runs off the main thread, linear, over the 200 songs that can be queued.
- **Launch**: add-ons start 0.6 s after Spotify finishes launching, the duplicate-Mirage scan runs on a
  utility queue, and the only disk work before `main()` is two tiny files.

Diagnostics:

- `Documents/Mirage/breadcrumbs.log` keeps the last Mirage events (launch, add-ons starting, tracks,
  Shuffle+, trash skips, caught exceptions, memory warnings, a main thread stuck for 2 s or more).
  Settings → Mirage → About → **Share diagnostics** shares it with the version, image UUID, device,
  add-ons on and the DJ log. No keys.
- **Safe mode**: when two launches in a row die in their first 10 seconds, the next one starts with every
  add-on off, says so in an alert and in About, and offers to turn them back on. An add-on is blamed on
  its own only when it crashes inside its own start-up.

Add-ons:

- The Mirage page lists only add-ons that are on; settings of an add-on that is off can't be opened
  anywhere.
- New art: one designed set made by `scripts/mirage-art.py` (flat geometry on a shared grid, Mirage
  purple with one secondary tone per add-on), compiled in as image data.
- **Pop-up lyrics**: the Home card is liquid glass (Vitrine's glass when loaded, `UIGlassEffect` on
  iOS 26, an ultra-thin material before), with no shadow or fill over the background.
- **Shuffle+** is a fourth state of Spotify's shuffle button: Off → Shuffle → Smart Shuffle (when
  offered) → Shuffle+ (a small `+` on the button) → Off. Long-press the button for a menu.

## 0.6.3: which Mirage is running

- Settings → Mirage → About shows the version with its build date, the file this Mirage runs from and the
  first part of its LC_UUID. If another copy of Mirage is loaded in the same app (an old `Mirage.dylib` or
  `.deb` injected again by the signer, or a tweak folder), Mirage names that file and its version in a
  one-time alert, in a red About row and in the DJ log. It also keeps its own drawer row on top and hides
  the other copy's row, so the drawer opens the new settings.
- `scripts/mirage-build.sh` fails unless the finished IPA has exactly one Mirage image and it is the
  version in `mirage/VERSION`.

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
