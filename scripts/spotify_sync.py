#!/usr/bin/env python3
"""
spotify_sync.py — Reconcile a Spotify playlist's local folder before re-downloading.

Run before `spotdl download` so that previously-downloaded songs survive a
playlist reorder. spotdl's "file already exists" check is name-based, so when
{list-position} changes, the same song is downloaded again under a new name.

This script:
  1. Calls `spotdl save` to fetch the current playlist (with current positions)
  2. Reads ID3 tags of every MP3 in the playlist folder
  3. Matches files to songs by (title, first artist) — the same key spotdl uses
  4. Renames each matched file to the path spotdl would generate today
  5. Deletes duplicate files left over from previous reorders
  6. Reports orphan files that no longer match any track in the playlist

Designed to run on the Python interpreter inside spotdl's pipx venv so that
`spotdl` and `mutagen` are importable without extra installs.
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path
import time

from mutagen.id3 import ID3, ID3NoHeaderError
from spotdl.types.song import Song
from spotdl.utils.formatter import create_file_name


TEMPLATE = "{list-name}/{list-position} - {artists} - {title}.{output-ext}"


def normalize(s: str) -> str:
    return re.sub(r"\s+", " ", s.lower().strip())


def read_tags(path: Path):
    try:
        tags = ID3(path)
    except (ID3NoHeaderError, Exception):
        return "", []
    title_frame = tags.get("TIT2")
    artist_frame = tags.get("TPE1")
    title = title_frame.text[0].strip() if title_frame and title_frame.text else ""
    artists: list[str] = []
    if artist_frame and artist_frame.text:
        # spotdl writes multi-artist as "A/B/C"
        raw = artist_frame.text[0]
        artists = [a.strip() for a in raw.split("/") if a.strip()]
    return title, artists


def _spotdl_config() -> dict:
    """Read ~/.spotdl/config.json, return {} on error."""
    try:
        cfg_path = Path.home() / ".spotdl" / "config.json"
        with open(cfg_path) as f:
            return json.load(f)
    except Exception:
        return {}


def _spotipy_client():
    """
    Return an authenticated spotipy.Spotify instance.
    Tries user-auth first (cached token), falls back to client credentials.
    Never opens a browser.
    """
    from spotipy import Spotify
    from spotipy.oauth2 import SpotifyOAuth, SpotifyClientCredentials, CacheFileHandler

    cfg = _spotdl_config()
    cid = cfg.get("client_id", "")
    cs  = cfg.get("client_secret", "")
    if not cid or not cs:
        raise RuntimeError("No Spotify credentials in ~/.spotdl/config.json")

    cache_path = str(Path.home() / ".spotdl" / ".spotipy")
    handler = CacheFileHandler(cache_path)

    # Try user-auth with cached token (no browser).
    cached = handler.get_cached_token()
    if cached:
        auth = SpotifyOAuth(
            client_id=cid,
            client_secret=cs,
            redirect_uri="http://127.0.0.1:9900/",
            scope="playlist-read-private,playlist-read-collaborative",
            cache_handler=handler,
            open_browser=False,
        )
        return Spotify(auth_manager=auth)

    # Fall back to client credentials (public playlists only).
    return Spotify(auth_manager=SpotifyClientCredentials(
        client_id=cid,
        client_secret=cs,
    ))


def run_spotdl_save(spotdl_path: str, url: str) -> list[dict]:
    """
    Fetch playlist tracks from the Spotify API directly (no subprocess, no
    YouTube-Music check). Returns a list of song dicts compatible with
    Song.from_dict() — only the fields needed for create_file_name() are
    populated; the rest get safe defaults.
    """
    import re as _re
    m = _re.search(r"playlist/([A-Za-z0-9]+)", url)
    if not m:
        sys.stderr.write("[sync] Not a playlist URL; skipping pre-sync.\n")
        return []
    playlist_id = m.group(1)

    try:
        sp = _spotipy_client()

        # Playlist name.
        info = sp.playlist(playlist_id, fields="name")
        list_name = (info or {}).get("name", "")
        if not list_name:
            return []

        # All tracks (paginated).
        # Note: Spotify API now uses "item" key instead of "track" in playlist items
        # (API change ~2025). We support both for backwards compatibility.
        raw_items: list[dict] = []
        page = sp.playlist_tracks(playlist_id)
        while page:
            raw_items.extend(page.get("items", []))
            page = sp.next(page) if page.get("next") else None

        total = len(raw_items)
        songs: list[dict] = []
        for pos, item in enumerate(raw_items, 1):
            # Support both old ("track") and new ("item") Spotify API response keys
            track = (item or {}).get("item") or (item or {}).get("track")
            if not track or track.get("is_local"):
                continue
            # Skip episodes and non-track items
            if track.get("type") not in ("track", None):
                continue
            artists = [a["name"] for a in track.get("artists", [])]
            if not artists:
                continue
            album = track.get("album") or {}
            album_artists = [a["name"] for a in album.get("artists", [])]
            release_date = album.get("release_date", "") or ""
            year = 0
            if release_date:
                try:
                    year = int(release_date[:4])
                except ValueError:
                    pass

            # IMPORTANT: every Optional field in Song dataclass that spotdl's
            # downloader.search_and_download() checks for None must be set to
            # a non-None value here. Otherwise spotdl triggers reinit_song()
            # which makes 3 Spotify API calls per song (track + artist + album).
            # For 49 songs that's ~150 API calls and the user's daily quota
            # is exhausted in seconds.
            songs.append({
                "name":         track["name"],
                "artists":      artists,
                "artist":       artists[0],
                "list_name":    list_name,
                "list_position": pos,
                "list_length":  total,
                "genres":       [],
                "disc_number":  track.get("disc_number") or 1,
                "disc_count":   1,
                "album_name":   album.get("name", ""),
                "album_artist": album_artists[0] if album_artists else artists[0],
                "album_id":     album.get("id", ""),
                "album_type":   album.get("album_type", "single"),
                "duration":     (track.get("duration_ms") or 0) // 1000,
                "year":         year,
                "date":         release_date,
                "track_number": track.get("track_number") or 0,
                "tracks_count": album.get("total_tracks") or 1,
                "song_id":      track.get("id", ""),
                "artist_id":    (track.get("artists") or [{}])[0].get("id", ""),
                "explicit":     track.get("explicit", False),
                "publisher":    "",
                "url":          f"https://open.spotify.com/track/{track.get('id', '')}",
                "isrc":         (track.get("external_ids") or {}).get("isrc"),
                "cover_url":    (album.get("images") or [{}])[0].get("url"),
                "copyright_text": None,
            })

        if songs:
            print(f"[sync] Fetched {len(songs)} tracks from '{list_name}'.")
        return songs

    except Exception as exc:
        sys.stderr.write(f"[sync] Spotify fetch failed: {exc}; skipping pre-sync.\n")
        return []


def load_from_cache(cache_file: str) -> list[dict]:
    """Load songs_data from a previously saved .spotdl cache file."""
    try:
        with open(cache_file) as f:
            data = json.load(f)
        songs = data if isinstance(data, list) else data.get("songs", [])
        name = songs[0].get("list_name", "?") if songs else "?"
        print(f"[sync] Using cached playlist data: {name} ({len(songs)} tracks).")
        return songs
    except Exception as e:
        print(f"[sync] Cache read failed ({e}); will fetch from Spotify.", file=sys.stderr)
        return []


def save_to_cache(songs_data: list[dict], cache_dir: str, playlist_id: str) -> None:
    """Persist songs_data to cache so subsequent runs can reuse it."""
    if not cache_dir or not playlist_id or not songs_data:
        return
    cache_path = Path(cache_dir) / f"{playlist_id}.spotdl"
    try:
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        with open(cache_path, "w") as f:
            json.dump(songs_data, f, ensure_ascii=False)
        print(f"[sync] Playlist metadata cached → {cache_path.name}")
    except Exception as e:
        print(f"[sync] Cache write failed: {e}", file=sys.stderr)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--output-base", required=True,
                    help="Base directory ending in '/Soundloader'")
    ap.add_argument("--spotdl", required=True)
    ap.add_argument("--cache-file", default="",
                    help="Path to a .spotdl cache file to use instead of fetching from Spotify.")
    ap.add_argument("--cache-dir", default="",
                    help="Directory where fetched playlist data should be cached.")
    args = ap.parse_args()

    # Derive playlist ID from URL for cache operations.
    import re as _re
    _m = _re.search(r"playlist/([A-Za-z0-9]+)", args.url)
    playlist_id = _m.group(1) if _m else ""

    # Resolve songs_data: prefer supplied cache file, fall back to Spotify fetch.
    if args.cache_file:
        songs_data = load_from_cache(args.cache_file)
    else:
        songs_data = run_spotdl_save(args.spotdl, args.url)
        if songs_data and args.cache_dir and playlist_id:
            save_to_cache(songs_data, args.cache_dir, playlist_id)

    if not songs_data:
        return 0  # Non-fatal: let the download proceed without pre-sync.

    list_name = (songs_data[0].get("list_name") or "").strip()
    if not list_name:
        return 0  # Single track, not a playlist — nothing to reorder.

    output_base = Path(args.output_base).expanduser()
    songs = [Song.from_dict(d) for d in songs_data]

    # Compute the canonical (current) path for each song.
    song_targets: list[tuple[Song, Path]] = []
    for song in songs:
        target_rel = create_file_name(song, TEMPLATE, "mp3")
        song_targets.append((song, output_base / target_rel))

    playlist_dir = (output_base / list_name).resolve()
    if not playlist_dir.is_dir():
        print(f"[sync] Playlist folder not found yet: {playlist_dir}")
        return 0

    # Index existing MP3s by (title, first artist) — same key spotdl effectively uses.
    files_by_key: dict[tuple[str, str], list[Path]] = {}
    all_files: list[Path] = sorted(playlist_dir.glob("*.mp3"))
    for mp3 in all_files:
        title, artists = read_tags(mp3)
        if not title or not artists:
            continue
        key = (normalize(title), normalize(artists[0]))
        files_by_key.setdefault(key, []).append(mp3)

    renames: list[tuple[Path, Path]] = []
    duplicates: list[Path] = []
    matched_files: set[Path] = set()
    missing: list[tuple[int, str, str]] = []

    for song, target_path in song_targets:
        artists = song.artists or [song.artist]
        if not song.name or not artists:
            continue
        key = (normalize(song.name), normalize(artists[0]))
        candidates = files_by_key.get(key, [])
        if not candidates:
            missing.append((song.list_position, song.name, artists[0]))
            continue
        chosen = candidates[0]
        matched_files.add(chosen)
        # Any extra files matching the same song are stale duplicates.
        for extra in candidates[1:]:
            duplicates.append(extra)
            matched_files.add(extra)
        if chosen.resolve() != target_path.resolve():
            renames.append((chosen, target_path))

    orphans = [f for f in all_files if f not in matched_files]

    # Delete duplicates first so they don't collide with rename targets.
    for d in duplicates:
        try:
            d.unlink()
            print(f"[sync] removed duplicate: {d.name}")
        except OSError as e:
            print(f"[sync] failed to remove {d.name}: {e}", file=sys.stderr)

    # Two-pass rename to avoid collisions when two files swap positions.
    if renames:
        staged: list[tuple[Path, Path]] = []
        for i, (src, dst) in enumerate(renames):
            tmp = src.parent / f".__sync_tmp_{i}__{src.name}"
            try:
                src.rename(tmp)
                staged.append((tmp, dst))
            except OSError as e:
                print(f"[sync] failed to stage {src.name}: {e}", file=sys.stderr)
        for tmp, dst in staged:
            try:
                if dst.exists():
                    dst.unlink()
                dst.parent.mkdir(parents=True, exist_ok=True)
                tmp.rename(dst)
                print(f"[sync] renamed: {dst.name}")
            except OSError as e:
                print(f"[sync] failed to rename to {dst.name}: {e}", file=sys.stderr)

    if orphans:
        print(f"[sync] {len(orphans)} file(s) no longer in playlist (kept):")
        for o in orphans:
            print(f"         {o.name}")

    if missing:
        print(f"[sync] {len(missing)} song(s) to download:")
        for pos, title, artist in missing:
            print(f"         {pos:02d} - {artist} - {title}")
    else:
        print("[sync] all playlist tracks already present locally.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
