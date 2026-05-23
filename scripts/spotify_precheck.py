#!/usr/bin/env python3
"""
spotify_precheck.py — Pre-download check for Soundloader.

Checks:
  1. Whether Spotify API credentials are rate-limited.
  2. Whether a fresh cached .spotdl file exists for this playlist.

Outputs a single pipe-separated line to stdout (parsed by Soundloader.applescript):

  STATUS|RETRY_AFTER|CACHE_FILE|PLAYLIST_NAME|TRACK_COUNT|CACHE_AGE_HOURS

  STATUS values:
    OK                — API OK, no fresh cache
    OK_CACHE          — API OK, fresh cache available
    RATE_LIMITED      — rate-limited, no fresh cache
    RATE_LIMITED_CACHE — rate-limited, but fresh cache available

  RETRY_AFTER is seconds (0 when not rate-limited).
  CACHE_FILE is the absolute path to the .spotdl cache file (empty if none).
  CACHE_AGE_HOURS is a float rounded to 1 decimal (0 if no cache).

Notes:
- If the stored token is expired or missing, rate-limit detection is skipped
  (status defaults to OK/OK_CACHE based on cache alone).
- Errors silently fall back to "OK" so a precheck failure never blocks a download.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


# Cache is considered fresh for up to 23 h (safely under Spotify's daily quota window).
CACHE_TTL_SECONDS = 23 * 3600


# ── Helpers ──────────────────────────────────────────────────────────────────

def extract_playlist_id(url: str) -> str:
    m = re.search(r"playlist/([A-Za-z0-9]+)", url)
    return m.group(1) if m else ""


def load_token(spotdl_dir: Path) -> str:
    """Return the stored Spotify access token if valid, else empty string."""
    token_file = spotdl_dir / ".spotipy"
    try:
        with open(token_file) as f:
            data = json.load(f)
        if time.time() >= data.get("expires_at", 0):
            return ""   # expired
        return data.get("access_token", "")
    except Exception:
        return ""


def check_api_rate_limit(token: str) -> tuple[bool, int]:
    """
    Make a cheap GET /v1/me call.
    Returns (is_rate_limited, retry_after_seconds).
    Any non-429 error is treated as "not rate-limited" so the download can try.
    """
    try:
        req = urllib.request.Request(
            "https://api.spotify.com/v1/me",
            headers={"Authorization": f"Bearer {token}"},
        )
        urllib.request.urlopen(req, timeout=5)
        return False, 0
    except urllib.error.HTTPError as e:
        if e.code == 429:
            retry = int(e.headers.get("Retry-After", 86400))
            return True, retry
        return False, 0   # 401 (expired), 403, etc. — not a rate limit
    except Exception:
        return False, 0   # network error — let spotdl handle it


def check_via_client_credentials(config_path: Path) -> tuple[bool, int]:
    """
    Fallback when no user token is available.
    Gets a client-credentials token, then tests an API call.
    Returns (is_rate_limited, retry_after_seconds).
    """
    import base64
    try:
        with open(config_path) as f:
            cfg = json.load(f)
        client_id = cfg.get("client_id", "")
        client_secret = cfg.get("client_secret", "")
        if not client_id or not client_secret:
            return False, 0

        creds = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
        req = urllib.request.Request(
            "https://accounts.spotify.com/api/token",
            data=b"grant_type=client_credentials",
            headers={
                "Authorization": f"Basic {creds}",
                "Content-Type": "application/x-www-form-urlencoded",
            },
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            token = json.loads(resp.read()).get("access_token", "")
        if not token:
            return False, 0
        return check_api_rate_limit(token)
    except urllib.error.HTTPError as e:
        if e.code == 429:
            retry = int(e.headers.get("Retry-After", 86400))
            return True, retry
        return False, 0
    except Exception:
        return False, 0


def check_cache(cache_dir: Path, playlist_id: str) -> tuple[str, str, int, float]:
    """
    Return (cache_file_path, playlist_name, track_count, age_hours)
    or ("", "", 0, 0.0) if no fresh cache exists.
    """
    if not playlist_id:
        return "", "", 0, 0.0
    cache_file = cache_dir / f"{playlist_id}.spotdl"
    if not cache_file.exists():
        return "", "", 0, 0.0
    age = time.time() - cache_file.stat().st_mtime
    if age > CACHE_TTL_SECONDS:
        return "", "", 0, 0.0
    try:
        with open(cache_file) as f:
            songs = json.load(f)
        if not isinstance(songs, list):
            songs = songs.get("songs", [])
        playlist_name = songs[0].get("list_name", "") if songs else ""
        return str(cache_file), playlist_name, len(songs), round(age / 3600, 1)
    except Exception:
        return "", "", 0, 0.0


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--spotdl-dir",
                    default=os.path.expanduser("~/.spotdl"))
    ap.add_argument("--cache-dir",
                    default=os.path.expanduser("~/.soundloader/cache"))
    args = ap.parse_args()

    playlist_id = extract_playlist_id(args.url)
    cache_dir = Path(args.cache_dir)
    spotdl_dir = Path(args.spotdl_dir)

    # Check cache first (cheap, local).
    cache_file, playlist_name, track_count, age_hours = check_cache(
        cache_dir, playlist_id
    )

    # Check rate-limit (fast network call).
    # Prefer the stored user token; fall back to a fresh client-credentials token.
    is_rate_limited = False
    retry_after = 0
    token = load_token(spotdl_dir)
    if token:
        is_rate_limited, retry_after = check_api_rate_limit(token)
    else:
        is_rate_limited, retry_after = check_via_client_credentials(
            spotdl_dir / "config.json"
        )

    # Determine status.
    if is_rate_limited:
        status = "RATE_LIMITED_CACHE" if cache_file else "RATE_LIMITED"
    else:
        status = "OK_CACHE" if cache_file else "OK"

    safe_name = playlist_name.replace("|", " ").replace("\n", " ")
    print(f"{status}|{retry_after}|{cache_file}|{safe_name}|{track_count}|{age_hours}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # Safety net: never let precheck crash block a download.
        print("OK||||0|0.0")
        sys.exit(0)
