# Mirage

Spotify for iOS, in glass, with an AI DJ and add-ons. Mirage is a fork of
[Vitrine](https://github.com/meownyaaa/vitrine), itself the GPL-3.0 fork of
[spoti.pw / Chroma](https://github.com/skopevoj/spoti.pw) (up to 0.21.1). Vitrine's tweak (`tweak/`) ships
untouched; Mirage adds its own next to it (`mirage/`).

- **Mirage DJ**: sets picked from what you really play, talked over between songs like Spotify's DJ, with your own
  AI key and a free or ElevenLabs voice. [More](docs/mirage/AI-DJ.md)
- **Backgrounds**: a picture, GIF or video behind Home, Now Playing or Library.
- **Add-on Shop**: features that ship inside Mirage, all off until you turn them on. [More](docs/mirage/ADDONS.md)

## Install

Bring your own decrypted Spotify **9.1.90** IPA (none is shared here), build, then sign and install with Ksign,
Feather, SideStore or any certificate signer.

    scripts/mirage-setup-linux.sh                   # once (Linux); macOS and GitHub Actions: docs/mirage/BUILDING.md
    scripts/mirage-build.sh path/to/Spotify.ipa     # out/Mirage-<version>-<spotify>.ipa

Step by step: [docs/mirage/INSTALL.md](docs/mirage/INSTALL.md) · Building: [docs/mirage/BUILDING.md](docs/mirage/BUILDING.md)

| | |
|---|---|
| The glass redesign | iOS 26+ |
| Legacy look | iOS 16.1+ |
| Live Activity | iOS 17+ |

## Add-ons

| Add-on | What it does |
|---|---|
| Vinyl | The Now Playing cover becomes a sleeve with a spinning record. |
| Dynamic colors | Mirage's accent and Vitrine's glass, tinted from the cover. |
| Shuffle+ | Shuffle with no artist twice in a row. |
| Trash | Trashed songs are skipped everywhere. |
| Pop-up lyrics | A synced lyrics shelf on Home; tap it for the lyrics view. |
| Genres | The song's genres on Now Playing. |
| Playlist tools | Sort a playlist, remove duplicates, or save a shuffled copy. |
| Radio | An endless station that learns from your skips and likes. |
| Focus mode | Just the cover and the controls, on black. |
| On repeat | Your most played lately, from your real history. |
| More like this | Songs like what's playing, queued or saved. |
| Cover ring | The song's progress as a ring round the cover. |
| Lyrics backdrop | The cover moves beside the title; big synced lyrics take its place. |
| Queue tools | Reorder the real queue, Play next, queue after the album. |
| Up Next | The next songs on the cover. |

Details and settings: [docs/mirage/ADDONS.md](docs/mirage/ADDONS.md). Changes: [CHANGELOG.md](CHANGELOG.md).
Vitrine's own docs: [docs/tweaks.md](docs/tweaks.md).

## Credits and license

Built on [Vitrine](https://github.com/meownyaaa/vitrine) and
[spoti.pw](https://github.com/skopevoj/spoti.pw) by Vojtěch Škopek (0.21.1, the last GPL-3.0 release), with
[cyan](https://github.com/asdfzxcvbn/pyzule-rw), [Theos](https://theos.dev), [FLEX](https://github.com/FLEXTool/FLEX)
and [EeveeSpotify Reincarnated](https://github.com/SideloadLabs/EeveeSpotifyReincarnated).

GPL-3.0, like Vitrine and spoti.pw. Not affiliated with Spotify.
