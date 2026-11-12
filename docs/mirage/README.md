# Mirage

Mirage is a tweak for Spotify on iPhone that sits on top of [Vitrine](https://github.com/meownyaaa/vitrine). It adds
custom backgrounds, an AI DJ that uses your own API key, and a shop of add-ons. Every add-on is off until you turn it on.

**Supported Spotify:** 9.1.90. On any other version the fragile hooks switch off ([COMPATIBILITY.md](COMPATIBILITY.md)).

## Install

1. Get `Mirage-<version>-9.1.90.ipa` onto the phone.
2. Sign and install it with Ksign. Leave tweak injection off, because everything is already inside.
3. Open Spotify, tap your avatar, then **Mirage** (just under Vitrine's *Mod Settings*).

Step by step: [INSTALL.md](INSTALL.md). To build it yourself: [BUILDING.md](BUILDING.md).

## Add-ons

Turn them on in **Mirage → Add-on Shop**. An add-on's settings show only while it is on. Each card has a battery line.

| Add-on | What it does | Battery |
|---|---|---|
| Vinyl | Turns the Now Playing cover into a sleeve with a spinning record peeking out | Higher |
| Pop-up lyrics | Synced lyrics shelf at the top of Home, line by line or word by word | Higher |
| Lyrics backdrop | Dims the Now Playing cover and scrolls big synced lyrics over it | Higher |
| Radio | Endless station that keeps the queue full and learns from your skips and likes | Some |
| Cover ring | Thin progress ring around the Now Playing cover | Low |
| Dynamic colors | Tints the accent and Vitrine's glass from the album cover | Low |
| Genres | The song's genres under its title on Now Playing | Low |
| Up Next | The next songs on the Now Playing cover | Low |
| Focus mode | A player button that leaves only the cover, the controls, the queue and devices | Low |
| Trash | Trash songs so they're skipped everywhere | Low |
| Shuffle+ | Shuffle that never plays the same artist twice in a row | Low |
| More like this | Songs like what's playing, queued or saved as a playlist | Low |
| On repeat | Recently played and this week's most played, from your history | Low |
| Queue tools | Reorder the queue, Play next, or queue after this album | Low |
| Playlist tools | Sort, remove duplicates, or save a shuffled copy, with undo | Low |

What's new in each version, and how to write an add-on: [ADDONS.md](ADDONS.md).

## AI DJ

Add a key for any supported provider under **Mirage → AI DJ**. **Start** keeps the song you're on and lines up picks
after it, chosen from that song and what you play. Type a vibe, or hold the mic and say it. The DJ never makes up
facts about songs. Details: [AI-DJ.md](AI-DJ.md).

## Settings and the keychain

- Every change is saved right away. It is also copied to Documents and to the iOS keychain.
- After a reinstall signed by the same team, the keychain copy comes back on its own. You can also use
  **About → Restore from backup**. Your theme and background are applied too, not only selected.
- Picture backgrounds are kept in the keychain as well, up to 8 of them. Videos are too big, so a restore names
  the ones you have to add again.
- **Save and load** exports a settings file. It never holds API keys, keychain data or listening history.

## Troubleshooting

- **A feature does nothing on a new Spotify version.** Its hook is off. Check About, then COMPATIBILITY.md.
- **Spotify closed twice while starting.** Safe mode turns the add-ons off. Turn them back on in Mirage.
- **The DJ says to add a key.** Go to **Mirage → AI DJ** and paste a key.
- **The mic says access is off.** Allow Microphone and Speech Recognition in Settings → Spotify.
- **Vinyl's BPM spin keeps a fixed speed.** Spotify often won't share a song's tempo, so the speed you picked is used.
- **Something else.** Go to **Mirage → AI DJ → DJ debug log** and share it.
