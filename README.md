# Soundloader

An app for **macOS** and **Windows** to download music from **Spotify**, **YouTube**, and **SoundCloud** playlists. No terminal knowledge required after setup.

## Requirements

- macOS 12 or later, **or** Windows 10/11
- Internet connection

## Installation

### macOS

> **First time with Terminal?** Follow these steps exactly — it's just copy-paste.

**Step 1 — Open Terminal**: Press **⌘ + Space**, type `Terminal`, press **Enter**.

**Step 2 — Run the installer**: Copy and paste these three lines into Terminal, then press **Enter**:

```bash
git clone https://github.com/htocqueville/soundloader.git
cd soundloader
bash setup.sh
```

Wait a few minutes until you see **"Setup complete!"**. Then open **Soundloader** from your Applications or Spotlight.

### Windows

> **First time with PowerShell?** Follow these steps exactly — it's just copy-paste.

**Step 1 — Install Git** (if you don't have it): open **PowerShell** (press **Win**, type `PowerShell`, press **Enter**) and run:

```powershell
winget install Git.Git
```

Then close and reopen PowerShell.

**Step 2 — Run the installer**: Copy and paste these three lines into PowerShell, then press **Enter**:

```powershell
git clone https://github.com/htocqueville/soundloader.git
cd soundloader
powershell -ExecutionPolicy Bypass -File setup.ps1
```

Wait a few minutes until you see **"Setup complete!"**. Then open **Soundloader** from the Start Menu or the Desktop shortcut.

---

## Spotify Setup (one-time, ~5 min)

Spotify requires a free developer key. You only do this once.

1. Go to [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) and log in
2. Create an app — add both Redirect URIs: `http://127.0.0.1:9900/` and `http://127.0.0.1:9900`
3. Copy your **Client ID** and **Client Secret** from the app's Settings page

When you open Soundloader for the first time and enter a Spotify URL, it will ask for these two values and guide you through a one-time browser login.

→ Detailed guide with screenshots: [docs/spotify-setup.md](docs/spotify-setup.md)

## YouTube Setup (one-time)

YouTube uses your browser session to avoid bot detection.

### macOS

Downloads use your **Safari** cookies. Grant Terminal access to Safari cookies:

1. Open **System Settings → Privacy & Security → Full Disk Access**
2. Click **+** and add **Terminal** (found in `/Applications/Utilities/`)
3. Restart Terminal, then re-run `bash setup.sh`

You must be **logged into YouTube in Safari** for downloads to work.

### Windows

Setup detects an installed browser automatically (**Firefox** is preferred — it's the most reliable for cookie access on Windows; Chrome and Edge encrypt their cookies in a way that sometimes blocks reading them).

You must be **logged into YouTube in that browser** for downloads to work. You can change the browser in **Settings → YouTube Browser** inside the app.

## SoundCloud

No setup needed — SoundCloud downloads work immediately.

---

## Usage

1. Open **Soundloader** (macOS: Applications or Spotlight — Windows: Start Menu or Desktop)
2. Paste a Spotify, YouTube, or SoundCloud playlist URL
3. Click **Download**
4. A terminal window shows live progress
5. Files are saved to your Music folder, under `Soundloader/<playlist name>/`

Already-downloaded tracks are skipped automatically.

**Supported URLs:**
- `https://open.spotify.com/playlist/...`
- `https://www.youtube.com/playlist?list=...` or `https://youtu.be/...`
- `https://soundcloud.com/.../sets/...`

---

## Updating

The app checks for updates automatically at launch and will notify you when one is available.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| App doesn't open / "damaged" error (macOS) | Re-run `bash setup.sh` |
| App doesn't open (Windows) | Re-run `powershell -ExecutionPolicy Bypass -File setup.ps1` |
| `winget` not found (Windows) | Install **App Installer** from the Microsoft Store |
| Spotify: "INVALID_CLIENT" | Check Client ID and Secret in your Spotify app settings |
| Spotify: "Invalid redirect URI" | Add both `http://127.0.0.1:9900/` and `http://127.0.0.1:9900` as Redirect URIs |
| YouTube: "Operation not permitted" on cookies (macOS) | Grant Terminal Full Disk Access (see YouTube Setup above) |
| YouTube: cookie errors (Windows) | Switch to Firefox in **Settings → YouTube Browser**, and make sure you're logged into YouTube there |
| Download stops mid-playlist | Re-run — already-downloaded tracks are skipped |

---

## Credits

- [nyekuuu/spotify-downloader](https://github.com/nyekuuu/spotify-downloader) — spotdl with OAuth support
- [yt-dlp/yt-dlp](https://github.com/yt-dlp/yt-dlp)
- [FFmpeg](https://ffmpeg.org)

## License

MIT
