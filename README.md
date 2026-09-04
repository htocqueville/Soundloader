# Soundloader

A macOS app to download music from **Spotify**, **YouTube**, and **SoundCloud** playlists. No terminal knowledge required after setup.

## Requirements

- macOS 12 or later
- Internet connection

## Installation

> **First time with Terminal?** Follow these steps exactly — it's just copy-paste.

### Step 1 — Open Terminal

Press **⌘ + Space**, type `Terminal`, press **Enter**.

### Step 2 — Run the installer

Copy and paste these three lines into Terminal, then press **Enter**:

```bash
git clone https://github.com/htocqueville/soundloader.git
cd soundloader
bash setup.sh
```

Wait a few minutes until you see **"Setup complete!"**. Then open **Soundloader** from your Applications or Spotlight.

---

## Spotify Setup (one-time, ~5 min)

Spotify requires a free developer key. You only do this once.

1. Go to [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) and log in
2. Create an app — add both Redirect URIs: `http://127.0.0.1:9900/` and `http://127.0.0.1:9900`
3. Copy your **Client ID** and **Client Secret** from the app's Settings page

When you open Soundloader for the first time and enter a Spotify URL, it will ask for these two values and guide you through a one-time browser login.

→ Detailed guide with screenshots: [docs/spotify-setup.md](docs/spotify-setup.md)

## YouTube Setup (one-time)

YouTube uses your Safari session to avoid bot detection. Grant Terminal access to Safari cookies:

1. Open **System Settings → Privacy & Security → Full Disk Access**
2. Click **+** and add **Terminal** (found in `/Applications/Utilities/`)
3. Restart Terminal, then re-run `bash setup.sh`

You must be **logged into YouTube in Safari** for downloads to work.

## SoundCloud

No setup needed — SoundCloud downloads work immediately.

---

## Usage

1. Open **Soundloader** from Applications or Spotlight
2. Paste a Spotify, YouTube, or SoundCloud playlist URL
3. Click **Download**
4. A Terminal window shows live progress
5. Files are saved to `~/Music/music-downloader/<playlist name>/`

Already-downloaded tracks are skipped automatically.

**Supported URLs:**
- `https://open.spotify.com/playlist/...`
- `https://www.youtube.com/playlist?list=...` or `https://youtu.be/...`
- `https://soundcloud.com/.../sets/...`

---

## Updating

The app checks for updates automatically at launch and will notify you when one is available.

yt-dlp (the downloader behind every source) is refreshed automatically before each download, at most once a day — YouTube changes its rules every few weeks, and an outdated yt-dlp makes every track fail. `bash setup.sh` refreshes it too.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| App doesn't open / "damaged" error | Re-run `bash setup.sh` |
| Spotify: "INVALID_CLIENT" | Check Client ID and Secret in your Spotify app settings |
| Spotify: "Invalid redirect URI" | Add both `http://127.0.0.1:9900/` and `http://127.0.0.1:9900` as Redirect URIs |
| YouTube: "Operation not permitted" on cookies | Grant Terminal Full Disk Access (see YouTube Setup above) |
| Download stops mid-playlist | Re-run — already-downloaded tracks are skipped |
| Every track fails with `YT-DLP download error` / `HTTP Error 403` | yt-dlp is outdated. The app updates it before the next download; if it keeps failing, re-run `bash setup.sh` |

---

## Credits

- [nyekuuu/spotify-downloader](https://github.com/nyekuuu/spotify-downloader) — spotdl with OAuth support
- [yt-dlp/yt-dlp](https://github.com/yt-dlp/yt-dlp)
- [FFmpeg](https://ffmpeg.org)

## License

MIT
