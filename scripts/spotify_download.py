#!/usr/bin/env python3
"""
spotify_download.py — spotdl download driver with verified retries.

Runs `spotdl download`, then checks on disk which tracks are actually present
(using the saved .spotdl song data and the same file-name logic spotdl uses).
If tracks are missing, spotdl is re-run — targeting the local .spotdl data
file, so retries never re-fetch from Spotify — until everything is present or
the attempt budget is exhausted.

Why: a plain re-run of the same spotdl command usually fixes the 1–2 tracks
that failed (YouTube throttling, flaky search results). This automates exactly
that, with an on-disk check instead of trusting spotdl's exit code (spotdl
exits 0 even when individual songs fail).

Before the first retry, scripts/ytdlp_refresh.py is run with --force: when
*every* track fails, the cause is almost always an outdated yt-dlp module in
spotdl's venv (YouTube changed something), and no amount of retrying helps
until it is updated. The refresh is cheap when yt-dlp is already current.

Tracks that already exist in another playlist's folder are skipped by spotdl
("duplicate", via --scan-for-songs); those are copied from the library into
this playlist's folder instead of re-downloaded, so every playlist folder
ends up complete.

For URL targets, `--save-file` is added to the first attempt so the fetched
song data lands in the cache dir — this is what makes verification possible,
and it doubles as the playlist cache the app's precheck offers to reuse.

Exit codes: 0 = every track verified on disk (or nothing to verify against),
1 = tracks still missing after all attempts.

Usage (all flags after `--` are forwarded verbatim to `spotdl download`):
  spotify_download.py --spotdl PATH --target URL_OR_SPOTDL_FILE \
      --output TEMPLATE [--format mp3] [--cache-dir DIR] [--attempts 3] \
      -- --config --user-auth --bitrate 320k --threads 4 --scan-for-songs

Designed to run on the Python interpreter inside spotdl's pipx venv so that
`spotdl` is importable without extra installs.
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path


def _track_id(url: str) -> str:
    m = re.search(r"track/([A-Za-z0-9]+)", url or "")
    return m.group(1) if m else ""


def scan_library(base: Path) -> dict:
    """
    Map the Spotify track id of every MP3 under base to its path, read from
    the WOAS (source URL) ID3 frame that spotdl writes. Mirrors what spotdl's
    --scan-for-songs uses to detect cross-playlist duplicates.
    """
    from mutagen.id3 import ID3

    index: dict = {}
    for mp3 in base.rglob("*.mp3"):
        try:
            frame = ID3(mp3).get("WOAS")
        except Exception:
            continue
        tid = _track_id(getattr(frame, "url", "") if frame else "")
        if tid and tid not in index:
            index[tid] = mp3
    return index


def verify(data_path: Path, template: str, ext: str):
    """
    Compare data_path's songs against the disk. Returns (missing, dup_copies):
      missing    — display names with no file at the expected path and no
                   copy anywhere in the library
      dup_copies — (src, dst, name) for tracks that exist elsewhere in the
                   library (spotdl skips downloading those as "(duplicate)"
                   with --scan-for-songs) and just need copying into this
                   playlist's folder
    Returns (None, []) when there is no usable song data to verify against.
    """
    from spotdl.types.song import Song
    from spotdl.utils.formatter import create_file_name

    try:
        with open(data_path) as f:
            data = json.load(f)
    except Exception:
        return None, []
    songs = data if isinstance(data, list) else data.get("songs", [])
    if not songs:
        return None, []

    candidates = []
    for d in songs:
        try:
            song = Song.from_dict(d)
            path = Path(create_file_name(song, template, ext))
        except Exception:
            continue  # unverifiable entry — never retry-loop on it
        if not path.exists():
            candidates.append((song, path))
    if not candidates:
        return [], []

    # Library base = static prefix of the output template
    # (e.g. "…/Music/Soundloader/{list-name}/…" → "…/Music/Soundloader").
    library: dict = {}
    prefix = template.split("{", 1)[0]
    base = Path(prefix) if prefix.endswith("/") else Path(prefix).parent
    if str(base) not in ("", ".") and base.is_dir():
        library = scan_library(base)

    missing, dup_copies = [], []
    for song, path in candidates:
        name = f"{song.artist} - {song.name}"
        src = library.get(_track_id(song.url))
        if src:
            dup_copies.append((src, path, name))
        else:
            missing.append(name)
    return missing, dup_copies


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--spotdl", required=True, help="Path to the spotdl binary")
    ap.add_argument("--target", required=True,
                    help="Spotify URL or .spotdl data file to download")
    ap.add_argument("--output", required=True,
                    help="spotdl output template (absolute path)")
    ap.add_argument("--format", default="mp3")
    ap.add_argument("--cache-dir", default="",
                    help="Where to save fetched song data for URL targets")
    ap.add_argument("--attempts", type=int, default=3)
    ap.add_argument("spotdl_args", nargs=argparse.REMAINDER,
                    help="Args after -- are forwarded to spotdl download")
    args = ap.parse_args()

    extra = args.spotdl_args
    if extra and extra[0] == "--":
        extra = extra[1:]

    # Resolve the song-data file used for verification and cached retries.
    target = args.target
    save_flag: list = []
    if Path(target).is_file():
        data_path = Path(target)
    else:
        data_path = None
        m = re.search(r"(?:playlist|album|track)/([A-Za-z0-9]+)", target)
        if m and args.cache_dir:
            data_path = Path(args.cache_dir) / f"{m.group(1)}.spotdl"
            data_path.parent.mkdir(parents=True, exist_ok=True)
            save_flag = ["--save-file", str(data_path)]

    missing = None
    for attempt in range(1, args.attempts + 1):
        cmd = [args.spotdl, "download", target,
               "--output", args.output, "--format", args.format]
        cmd += extra + save_flag
        proc = subprocess.run(cmd)

        if data_path is None:
            # Nothing to verify against — single run, like before.
            return proc.returncode

        missing, dup_copies = verify(data_path, args.output, args.format)
        if missing is None:
            return proc.returncode

        # Tracks already in the library under another playlist: spotdl skips
        # downloading them ("duplicate"), so copy them into this folder to
        # keep every playlist folder complete.
        for src, dst, name in dup_copies:
            try:
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst)
                print(f"[dl] ⧉ Copied library duplicate into playlist: {name}")
            except OSError as e:
                print(f"[dl] Failed to copy duplicate {name}: {e}",
                      file=sys.stderr)
                missing.append(name)

        if not missing:
            print("[dl] ✅ All tracks verified on disk.")
            return 0

        if attempt < args.attempts:
            delay = 5 * attempt
            print(f"[dl] ⟳ {len(missing)} track(s) missing — "
                  f"retry {attempt + 1}/{args.attempts} in {delay}s:")
            for name in missing:
                print(f"        {name}")
            if attempt == 1:
                # Outdated yt-dlp = every track fails; make sure the retry
                # runs on a current one. Never raises, exits 0 regardless.
                refresh = Path(__file__).resolve().parent / "ytdlp_refresh.py"
                if refresh.is_file():
                    subprocess.run([sys.executable, str(refresh), "--force"])
            time.sleep(delay)
            # Retry from the local data file — no Spotify re-fetch.
            if data_path.is_file():
                target = str(data_path)
                save_flag = []

    print(f"[dl] ❌ {len(missing)} track(s) still missing "
          f"after {args.attempts} attempts:")
    for name in missing:
        print(f"        {name}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
