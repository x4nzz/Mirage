# Spotify versions

| Spotify | Status | Notes |
|---|---|---|
| 9.1.90 (919002269) | **Verified**: every Mirage feature and add-on was built against it | Mirage 0.6.6 builds use this IPA |
| anything else | Not verified | Mirage's fragile hooks are switched off (see below); the rest runs |

Mirage reads the running Spotify's `CFBundleShortVersionString` at launch (`mirage/Sources/MRGCompat.m`,
`MRGVerifiedSpotifyVersions()`). When it isn't on the list, the hooks below aren't installed, so an unknown build opens
stock Spotify screens instead of half-styled or broken ones. About shows `Spotify 9.x.y · not verified, N hooks off`,
and **Run on this Spotify anyway** turns them back on from the next launch. That switch is per install and isn't
included in exports or the keychain backup.

## Fragile hooks (off on unverified builds)

These change the layout of Swift views or sheets that Spotify renames or rebuilds between versions:

| Hook | Spotify classes it relies on |
|---|---|
| Vinyl | `CreativeWorkCommons_CoverArtTiltKit.CoverArtTiltView`, `NowPlaying_ContentLayersImpl.CoverArtCellImpl` |
| Genres | `NowPlaying_ScrollImpl.NPVBackgroundViewController` |
| Shuffle+ button | the `Components.UI.ShuffleButton` control |
| Shuffle+ in Listening modes | `SmartShuffle_CoreImpl.PlayModePickerView`, rows `Components.UI.PlayModeRow` |
| Trash button / menu row | `NowPlaying_ModesImpl.HeaderElementsUnit`, `ContextMenu_InternalImpl.ContextMenuViewController` |
| DJ player button | `NowPlaying_ModesImpl.HeaderElementsUnit` |
| Now Playing kit (Focus mode, Cover ring, Lyrics backdrop, Up Next) | `NowPlaying_ModesImpl` units (Header, Information, Duration, PlaybackControls, Footer, Floating), `NowPlaying_ScrollImpl.NPVScrollViewController` |
| Queue tools menu rows | `ContextMenu_InternalImpl.ContextMenuViewController` |

Every one of them also checks that its classes exist before hooking, and catches exceptions in its layout code.

## Always on

Settings, backgrounds, the profile and drawer rows, the AI DJ, listening history, Radio, On repeat, More like this,
playlists and the player/queue calls (Objective-C classes with each selector checked before it's sent).

## Adding a version

1. Build against the new IPA and walk through every add-on.
2. Add the version to `MRGVerifiedSpotifyVersions()` and to the table above.
