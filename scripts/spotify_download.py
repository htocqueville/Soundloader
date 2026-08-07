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
import subprocess
import sys
import time
from pathlib import Path


def _track_id(url: str) -> str:
    m = re.search(r"track/([A-Za-z0-9]+)", url or "")
    return m.group(1) if m else ""


def scan_library_track_ids(base: Path) -> set:
    """
    Collect the Spotify track ids of every MP3 under base, read from the WOAS
    (source URL) ID3 frame that spotdl writes. Mirrors what spotdl's
    --scan-for-songs uses to skip cross-playlist duplicates.
    """
    from mutagen.id3 import ID3

    ids = set()
    for mp3 in base.rglob("*.mp3"):
        try:
            frame = ID3(mp3).get("WOAS")
        except Exception:
            continue
        tid = _track_id(getattr(frame, "url", "") if frame else "")
        if tid:
            ids.add(tid)
    return ids


def compute_missing(data_path: Path, template: str, ext: str):
    """
    Return the display names of tracks in data_path that spotdl would still
    try to download: no file at the expected path AND no copy anywhere in the
    library (spotdl skips those as "(duplicate)" with --scan-for-songs).
    Returns None when there is no usable song data to verify against.
    """
    from spotdl.types.song import Song
    from spotdl.utils.formatter import create_file_name

    try:
        with open(data_path) as f:
            data = json.load(f)
    except Exception:
        return None
    songs = data if isinstance(data, list) else data.get("songs", [])
    if not songs:
        return None

    candidates = []
    for d in songs:
        try:
            song = Song.from_dict(d)
            path = Path(create_file_name(song, template, ext))
        except Exception:
            continue  # unverifiable entry — never retry-loop on it
        if not path.exists():
            candidates.append(song)
    if not candidates:
        return []

    # Library base = static prefix of the output template
    # (e.g. "…/Music/Soundloader/{list-name}/…" → "…/Music/Soundloader").
    library_ids = set()
    prefix = template.split("{", 1)[0]
    base = Path(prefix).parent if not prefix.endswith("/") else Path(prefix)
    if str(base) not in ("", ".") and base.is_dir():
        library_ids = scan_library_track_ids(base)

    return [f"{song.artist} - {song.name}" for song in candidates
            if not (_track_id(song.url) and _track_id(song.url) in library_ids)]


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

        missing = compute_missing(data_path, args.output, args.format)
        if missing is None:
            return proc.returncode
        if not missing:
            print("[dl] ✅ All tracks verified on disk.")
            return 0

        if attempt < args.attempts:
            delay = 5 * attempt
            print(f"[dl] ⟳ {len(missing)} track(s) missing — "
                  f"retry {attempt + 1}/{args.attempts} in {delay}s:")
            for name in missing:
                print(f"        {name}")
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
