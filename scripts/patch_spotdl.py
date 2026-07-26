#!/usr/bin/env python3
"""
patch_spotdl.py — Apply Soundloader's spotdl patches (cross-platform).

Run with the Python interpreter of spotdl's pipx venv so `import spotdl`
resolves to the installed package:

    macOS   : ~/.local/pipx/venvs/spotdl/bin/python  scripts/patch_spotdl.py
    Windows : %PIPX_VENVS%\\spotdl\\Scripts\\python.exe scripts\\patch_spotdl.py

Patches applied (all idempotent — safe to re-run):
  1. console/entry_point.py    — YTM IP-block: crash → warning + provider fallback
  2. providers/audio/youtube.py — search via yt-dlp instead of broken pytube
  3. utils/matching.py          — lenient duration / artists filters
  4. providers/audio/base.py    — validate top candidates with yt-dlp
  5. utils/search.py            — skip Spotify API calls for un-tagged local files
  6. ~/.spotdl/config.json      — drop dead 'piped' audio provider
"""
import json
import sys
from pathlib import Path

try:
    import spotdl
except ImportError:
    print("ERROR: cannot import spotdl — run this script with the venv's python.")
    sys.exit(1)

SPOTDL_ROOT = Path(spotdl.__file__).parent


def patch_file(path: Path, marker: str, replacements: list[tuple[str, str]], label: str) -> None:
    """Apply text replacements to `path` unless `marker` is already present."""
    if not path.is_file():
        print(f"[skip] {label}: {path} not found")
        return
    src = path.read_text(encoding="utf-8")
    if marker in src:
        print(f"[ok]   {label}: already patched")
        return
    missing = [old for old, _ in replacements if old not in src]
    if missing:
        print(f"[skip] {label}: source signature changed — patch not applied")
        return
    for old, new in replacements:
        src = src.replace(old, new)
    path.write_text(src, encoding="utf-8")
    print(f"[done] {label}: patch applied")


# ── 1. YTM block: crash → graceful fallback ──────────────────────────────────

OLD_YTM = '''            raise DownloaderError(
                "You are blocked by YouTube Music. "
                "Please use a VPN, change youtube-music to piped, or use other audio providers"
            )'''

NEW_YTM = '''            logger.warning(
                "YouTube Music is currently unavailable (IP block or regional restriction). "
                "Falling back to remaining audio providers: %s",
                [p for p in downloader_settings["audio_providers"] if p != "youtube-music"],
            )
            downloader_settings["audio_providers"] = [
                p for p in downloader_settings["audio_providers"] if p != "youtube-music"
            ]
            if not downloader_settings["audio_providers"]:
                raise DownloaderError(
                    "YouTube Music is blocked and no fallback audio providers are configured. "
                    "Add 'youtube' or 'piped' to audio_providers in your spotdl config."
                )'''

patch_file(
    SPOTDL_ROOT / "console" / "entry_point.py",
    marker='logger.warning(\n                "YouTube Music is currently unavailable',
    replacements=[(OLD_YTM, NEW_YTM)],
    label="YTM graceful fallback",
)


# ── 2. YouTube provider: yt-dlp search instead of pytube ─────────────────────

NEW_GET_RESULTS = '''    def get_results(
        self, search_term: str, *_args, **_kwargs
    ) -> List[Result]:  # pylint: disable=W0221
        """
        Get results from YouTube.

        # SOUNDLOADER-PATCH: use yt-dlp instead of pytube (pytube cannot parse
        # YouTube's modern lockupViewModel/gridShelfViewModel renderers, so it
        # returns results with duration=0 and view_count=0, which causes
        # spotdl's matcher to discard every hit).
        """
        import yt_dlp

        ydl_opts = {
            "quiet": True,
            "no_warnings": True,
            "extract_flat": True,
            "skip_download": True,
        }

        results: List[Result] = []
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(f"ytsearch20:{search_term}", download=False)
        except Exception:
            return []

        if not info or not info.get("entries"):
            return []

        for entry in info["entries"]:
            if not entry:
                continue
            video_id = entry.get("id", "")
            if not video_id:
                continue
            results.append(
                Result(
                    source=self.name,
                    url=entry.get("url") or f"https://www.youtube.com/watch?v={video_id}",
                    verified=False,
                    name=entry.get("title", "") or "",
                    duration=int(entry.get("duration") or 0),
                    author=entry.get("uploader") or entry.get("channel") or "",
                    search_query=search_term,
                    views=int(entry.get("view_count") or 0),
                    result_id=video_id,
                )
            )
        return results
'''


def patch_youtube_provider() -> None:
    import re

    path = SPOTDL_ROOT / "providers" / "audio" / "youtube.py"
    label = "YouTube provider (yt-dlp search)"
    if not path.is_file():
        print(f"[skip] {label}: {path} not found")
        return
    src = path.read_text(encoding="utf-8")
    if "# SOUNDLOADER-PATCH: use yt-dlp" in src:
        print(f"[ok]   {label}: already patched")
        return
    old_re = re.compile(
        r'    def get_results\(\s*\n'
        r'        self, search_term: str, \*_args, \*\*_kwargs\s*\n'
        r'    \) -> List\[Result\]:.*?return results\n',
        re.DOTALL,
    )
    if not old_re.search(src):
        print(f"[skip] {label}: source signature changed — patch not applied")
        return
    path.write_text(old_re.sub(NEW_GET_RESULTS, src), encoding="utf-8")
    print(f"[done] {label}: patch applied")


patch_youtube_provider()


# ── 3. Matcher: lenient duration / artists filters ───────────────────────────

OLD_ARTISTS = '''        # Ignore results with artists match lower than 70%
        if artists_match < 70 and result.source != "slider.kz":
            debug(
                song.song_id,
                result.result_id,
                "Skipping result due to artists match lower than 70%",
            )
            continue'''

NEW_ARTISTS = '''        # SOUNDLOADER-PATCH: artists filter disabled — slug normalisation
        # makes artists_match collapse to 0% on perfect matches (e.g.
        # "Marius Acke" vs "mariusacke"). Rely on the combined name+time
        # check below instead.
        pass'''

OLD_TIME = '''        # Skip results with time match lower than 25%
        if time_match < 25:
            debug(
                song.song_id,
                result.result_id,
                "Skipping result due to time match lower than 25%",
            )
            continue

        # If the time match is lower than 50%
        # and the average match is lower than 75%
        # we skip the result
        if time_match < 50 and average_match < 75:
            debug(
                song.song_id,
                result.result_id,
                "Skipping result due to time match < 50% and average match < 75%",
            )
            continue'''

NEW_TIME = '''        # SOUNDLOADER-PATCH: combined name+time OR average filter.
        # Keep a result if (name+time are both strong) OR (combined avg ≥ 60).
        strong_name_time = (name_match >= 80) and (time_match >= 50)
        if not strong_name_time and average_match < 60:
            debug(
                song.song_id,
                result.result_id,
                f"Skipping: name={name_match:.0f} time={time_match:.0f} avg={average_match:.0f}",
            )
            continue'''

patch_file(
    SPOTDL_ROOT / "utils" / "matching.py",
    marker="# SOUNDLOADER-PATCH: artists filter disabled",
    replacements=[(OLD_ARTISTS, NEW_ARTISTS), (OLD_TIME, NEW_TIME)],
    label="lenient matcher",
)


# ── 4. Audio search: validate top candidates before returning ────────────────

OLD_BEST = '''        # get the result with highest score
        best_result, best_score = self.get_best_result(results)
        logger.debug(
            "[%s] Returning best result %s with score %s",
            song.song_id,
            best_result.url,
            best_score,
        )

        return best_result.url'''

NEW_BEST = '''        # SOUNDLOADER-PATCH: validate top candidates with yt-dlp before
        # returning. Walk the top-5 by score, fetch lightweight metadata, and
        # return the first one yt-dlp can actually reach. Falls back to the
        # upstream best result if every candidate is unfetchable.
        sorted_candidates = sorted(
            results.items(), key=lambda x: x[1], reverse=True
        )
        for candidate, candidate_score in sorted_candidates[:5]:
            try:
                self.get_download_metadata(candidate.url, download=False)
            except Exception as exc:  # pylint: disable=broad-except
                logger.debug(
                    "[%s] Candidate %s (score %s) unfetchable: %s",
                    song.song_id, candidate.url, candidate_score, exc,
                )
                continue
            logger.debug(
                "[%s] Returning validated best %s with score %s",
                song.song_id, candidate.url, candidate_score,
            )
            return candidate.url

        best_result, best_score = self.get_best_result(results)
        logger.debug(
            "[%s] All candidates unfetchable; returning unvalidated best %s",
            song.song_id, best_result.url,
        )
        return best_result.url'''

patch_file(
    SPOTDL_ROOT / "providers" / "audio" / "base.py",
    marker="# SOUNDLOADER-PATCH: validate",
    replacements=[(OLD_BEST, NEW_BEST)],
    label="candidate validation",
)


# ── 5. gather_known_songs: skip API calls for un-tagged files ────────────────

OLD_SCAN = '''        # If the songs doesn't have metadata, try to get it from the filename
        if song is None or song.url is None:
            search_results = get_search_results(path.stem)
            if len(search_results) == 0:
                continue

            song = search_results[0]'''

NEW_SCAN = '''        # Skip files without proper metadata instead of calling the Spotify
        # search API (patched by Soundloader setup to preserve API quota).
        if song is None or song.url is None:
            continue'''

patch_file(
    SPOTDL_ROOT / "utils" / "search.py",
    marker="to preserve API quota",
    replacements=[(OLD_SCAN, NEW_SCAN)],
    label="local-scan API skip",
)


# ── 6. Config: drop dead 'piped' audio provider ──────────────────────────────

def clean_config() -> None:
    cfg_path = Path.home() / ".spotdl" / "config.json"
    if not cfg_path.is_file():
        print("[skip] config cleanup: no config.json yet")
        return
    try:
        cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    except Exception:
        print("[skip] config cleanup: unreadable config.json")
        return
    providers = cfg.get("audio_providers", [])
    if "piped" in providers:
        cfg["audio_providers"] = [a for a in providers if a != "piped"]
        cfg_path.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
        print("[done] config cleanup: removed 'piped' from audio_providers")
    else:
        print("[ok]   config cleanup: already clean")


clean_config()

print("All spotdl patches processed.")
