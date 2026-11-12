# Changelog

Mirage versions. Vitrine's own notes stay in its release history; Mirage does not edit `tweak/`.

## 0.6.0

- **Add-on framework.** An add-on has an id, name, category, version, description, default settings, a settings schema the shop renders (toggles, sliders, pickers, colors), and enable/disable hooks. If one crashes while Spotify is opening, the next launch turns it off and the shop says so.
- **Add-on shop.** The theme marketplace is the first section. Every add-on has an on/off switch and, when it has settings or its own page, a settings row.
- **Theme marketplace.** Themes are data only: colors, an accent, a glass tint, and an optional background reference. Ten themes ship in the app. A remote catalog can be turned off; if it is off or unreachable, the bundled list is used. A theme says whether dynamic colors may override it.
- **Dynamic colors.** A 24×24 sample of the cover is cached per track and blended into Mirage's accent, toggles, and Vitrine's glass. Strength, which of those to tint, and a fallback color are settings. The previous color stays up until the new one is ready.
- **Backgrounds page.** Background settings moved off the main Mirage page onto their own page, the same way AI DJ has its own. Saved backgrounds can be added, chosen, renamed, and deleted. Home, Now Playing, Library, and Everywhere can each use a different one. An existing background is kept. Video pauses in Low Power Mode.
- **Shuffle+.** Turning shuffle on for a playlist or album rebuilds Spotify's queue so the same artist doesn't play twice in a row and recent songs wait. If Spotify Free refuses the queue, Spotify's own shuffle is left as it is.
- **Trash.** Trash a song from Now Playing or its menu. Trashed songs are skipped in queues and playlists, and the AI DJ will not pick them. Restore them from the list. Auto-skip stops after about six an hour.
- **Pop-up lyrics.** Apple Music-style synced lyrics at the top of Home, using Vitrine's lines, lead line, and playback position. The row takes no touches. Font size, and what shows when nothing is playing, are settings.
- **Genres.** Shown on Now Playing. Spotify's player track has no genre field; metadata is used when a key contains "genre", otherwise the artist's genres from the Web API, cached on the phone.
- **Playlist tools.** Sort (date added, title, artist, duration), remove duplicates, or save a shuffled copy. Each change asks first. Sort and duplicate removal can be undone; undoing a shuffled copy removes that new playlist.
- **Save & load settings.** One versioned JSON file through the share sheet, checked on the way back in. Named presets stay on the phone. Backgrounds are names only unless **Include background files** is on. API keys and listening history are never included.

## 0.5.4

Vinyl follows the cover every frame, including while the player is pulled down, and is sized to about 78% of the screen width with a 20% peek. Builds are named `Mirage-<version>-<spotify>.ipa`.

Earlier Mirage notes are in [docs/mirage/AI-DJ.md](docs/mirage/AI-DJ.md).
