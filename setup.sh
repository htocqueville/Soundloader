#!/bin/bash
set -euo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
RESET="\033[0m"

info()    { echo -e "${BOLD}==> $1${RESET}"; }
success() { echo -e "${GREEN}✓ $1${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $1${RESET}"; }
error()   { echo -e "${RED}✗ $1${RESET}"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BOLD}"
echo "╔══════════════════════════════════╗"
echo "║   Soundloader — Setup            ║"
echo "╚══════════════════════════════════╝"
echo -e "${RESET}"

# ── 1. Homebrew ───────────────────────────────────────────────────────────────
info "Checking Homebrew..."
if ! command -v brew &>/dev/null; then
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add brew to PATH for Apple Silicon
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
else
    success "Homebrew already installed"
fi

# ── 2. ffmpeg ─────────────────────────────────────────────────────────────────
info "Checking ffmpeg..."
if ! command -v ffmpeg &>/dev/null; then
    info "Installing ffmpeg..."
    brew install ffmpeg
else
    success "ffmpeg already installed"
fi

# ── 3. pipx ───────────────────────────────────────────────────────────────────
info "Checking pipx..."
if ! command -v pipx &>/dev/null; then
    info "Installing pipx..."
    brew install pipx
    pipx ensurepath
    export PATH="$HOME/.local/bin:$PATH"
else
    success "pipx already installed"
fi

# ── 4. Python version check (spotdl requires Python >=3.10, <3.14) ───────────
info "Checking Python version for spotdl..."

find_compatible_python() {
    for ver in python3.13 python3.12 python3.11 python3.10; do
        if command -v "$ver" &>/dev/null; then
            echo "$ver"; return
        fi
    done
    # Check if the default python3 falls in the compatible range
    if command -v python3 &>/dev/null; then
        local minor
        minor=$(python3 -c "import sys; print(sys.version_info.minor)" 2>/dev/null || echo "0")
        local major
        major=$(python3 -c "import sys; print(sys.version_info.major)" 2>/dev/null || echo "0")
        if [ "$major" -eq 3 ] && [ "$minor" -ge 10 ] && [ "$minor" -lt 14 ]; then
            echo "python3"; return
        fi
    fi
    echo ""
}

PYTHON_FOR_SPOTDL="$(find_compatible_python)"

if [ -z "$PYTHON_FOR_SPOTDL" ]; then
    warn "Python 3.10–3.13 not found (spotdl is not yet compatible with Python 3.14+)."
    info "Installing Python 3.13 via Homebrew..."
    brew install python@3.13
    PYTHON_FOR_SPOTDL="$(brew --prefix)/bin/python3.13"
    if [ ! -f "$PYTHON_FOR_SPOTDL" ]; then
        PYTHON_FOR_SPOTDL="python3.13"
    fi
fi

success "Using $PYTHON_FOR_SPOTDL for spotdl"

# ── 5. spotdl (official PyPI, >=4.5.2) ────────────────────────────────────────
# The nyekuuu fork (previously used for --user-auth OAuth) is stuck at 4.4.3
# and broke when Spotify's Feb–Mar 2026 API migration removed the
# /playlists/{id}/tracks endpoint (403 Forbidden on every playlist).
# Official spotdl has --user-auth upstream and, since 4.4.4, fetches playlist
# data without the restricted Web API. Note: since that migration, dev-mode
# Spotify apps can only read the items of the authenticated user's OWN
# playlists — other accounts' playlists return metadata only, by policy.
info "Checking spotdl..."
SPOTDL_SPEC="spotdl>=4.5.2"
if pipx list 2>/dev/null | grep -q "spotdl"; then
    info "Upgrading spotdl from PyPI..."
    pipx install --force --python "$PYTHON_FOR_SPOTDL" "$SPOTDL_SPEC" \
        || warn "spotdl upgrade failed, keeping existing version"
else
    info "Installing spotdl from PyPI..."
    pipx install --python "$PYTHON_FOR_SPOTDL" "$SPOTDL_SPEC"
fi

# ── 6. yt-dlp (always via brew — pip/system installs use outdated Python) ─────
# This binary serves the SoundCloud / YouTube handlers. spotdl does NOT use
# it: it downloads through the yt_dlp module of its own venv — see 7a.
info "Installing/updating yt-dlp via Homebrew..."
brew install yt-dlp 2>/dev/null || brew upgrade yt-dlp 2>/dev/null || true

# ── 7. Resolve binary paths ───────────────────────────────────────────────────
info "Resolving binary paths..."

# spotdl path inside its pipx venv
PIPX_VENVS="$(pipx environment --value PIPX_LOCAL_VENVS 2>/dev/null || echo "$HOME/.local/pipx/venvs")"
SPOTDL_PATH="$PIPX_VENVS/spotdl/bin/spotdl"

if [ ! -f "$SPOTDL_PATH" ]; then
    # Fallback: find in PATH
    SPOTDL_PATH="$(command -v spotdl 2>/dev/null || true)"
    if [ -z "$SPOTDL_PATH" ]; then
        error "spotdl binary not found. Try re-running setup.sh after restarting your terminal."
    fi
fi
success "spotdl: $SPOTDL_PATH"

# ── 7a. yt-dlp inside spotdl's venv ───────────────────────────────────────────
# spotdl downloads with the yt_dlp *module* of its pipx venv, never with the
# Homebrew binary above. When YouTube changes something, an outdated module
# fails every single track ("YT-DLP download error" — Sept 2026: HTTP 403 on
# the media while extraction still worked), and re-running setup.sh used to
# leave it stale since only brew got upgraded. The app now refreshes both
# copies daily via scripts/ytdlp_refresh.py; run it here too (--force) so a
# fresh install or an app update starts current.
info "Updating yt-dlp inside spotdl's venv..."
"$(dirname "$SPOTDL_PATH")/python3" "$SCRIPT_DIR/scripts/ytdlp_refresh.py" --force \
    || warn "yt-dlp refresh failed — the app will retry before the next download"

# yt-dlp path — prefer brew's version (ships with a modern Python runtime,
# avoids the LibreSSL/SSL issues of system Python 3.9 pip installs)
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
YTDLP_PATH="$BREW_PREFIX/bin/yt-dlp"
if [ ! -f "$YTDLP_PATH" ]; then
    # Fallback: anything in PATH
    YTDLP_PATH="$(command -v yt-dlp 2>/dev/null || true)"
fi
if [ -z "$YTDLP_PATH" ]; then
    error "yt-dlp binary not found. Try: brew install yt-dlp"
fi
success "yt-dlp: $YTDLP_PATH"

# ── 7b1c. Patch spotdl matcher: tolerate duration & secondary-artist gaps ─────
# Two real-world matching failures spotdl rejects too aggressively:
#   • Spotify radio edit vs YouTube extended mix (duration differs by 100s+).
#   • Spotify track with multiple credited artists, YouTube title only lists
#     the main one — and spotdl's slug normaliser collapses Marius Acke /
#     mariusacke / marius-acke inconsistently, so artists_match drops to 0
#     on what is actually a perfect match.
# Replace the strict artists/time filters with a smarter pass-condition:
#   (a) name_match ≥ 80 AND time_match ≥ 50, OR
#   (b) average_match ≥ 60.
MATCHING_PY="$(find "$PIPX_VENVS/spotdl/lib" -name "matching.py" -path "*/spotdl/utils/*" 2>/dev/null | head -1)"
if [ -n "$MATCHING_PY" ]; then
    info "Patching spotdl matcher for lenient duration / artists filters..."
    python3 - "$MATCHING_PY" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()
if "# SOUNDLOADER-PATCH: artists filter disabled" in src:
    print("Already patched.")
    sys.exit(0)

old_artists = '''        # Ignore results with artists match lower than 70%
        if artists_match < 70 and result.source != "slider.kz":
            debug(
                song.song_id,
                result.result_id,
                "Skipping result due to artists match lower than 70%",
            )
            continue'''
new_artists = '''        # SOUNDLOADER-PATCH: artists filter disabled — slug normalisation
        # makes artists_match collapse to 0% on perfect matches (e.g.
        # "Marius Acke" vs "mariusacke"). Rely on the combined name+time
        # check below instead.
        pass'''

old_time = '''        # Skip results with time match lower than 25%
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
new_time = '''        # SOUNDLOADER-PATCH: combined name+time OR average filter.
        # Keep a result if (name+time are both strong) OR (combined avg ≥ 60).
        strong_name_time = (name_match >= 80) and (time_match >= 50)
        if not strong_name_time and average_match < 60:
            debug(
                song.song_id,
                result.result_id,
                f"Skipping: name={name_match:.0f} time={time_match:.0f} avg={average_match:.0f}",
            )
            continue'''

if old_artists in src and old_time in src:
    src = src.replace(old_artists, new_artists).replace(old_time, new_time)
    with open(path, 'w') as f:
        f.write(src)
    print("Patch applied.")
else:
    print("Patch source not found; signature may have changed.")
PYEOF
    success "spotdl matcher patch done"
fi

# ── 7b1d. Patch spotdl search: validate candidates before returning ───────────
# When a search hit is age-restricted / removed / geo-blocked, spotdl returns
# its URL anyway and the download of that song fails (e.g. "Sign in to
# confirm your age" on explicit tracks). search() has several early returns
# (ISRC shortcuts, verified best ≥80) plus the final best-result block: guard
# every one of them with a yt-dlp reachability check (_sl_fetchable) so an
# unfetchable candidate falls through to the next candidate — or the next
# audio provider — instead of failing the song.
BASE_PY="$(find "$PIPX_VENVS/spotdl/lib" -name "base.py" -path "*/spotdl/providers/audio/*" 2>/dev/null | head -1)"
if [ -n "$BASE_PY" ]; then
    info "Patching spotdl audio search to validate candidates with yt-dlp..."
    python3 - "$BASE_PY" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()

changed = False

HELPER = '''    def _sl_fetchable(self, url: str) -> bool:
        """
        SOUNDLOADER-PATCH: True when yt-dlp can actually fetch url.
        Age-restricted, removed or geo-blocked videos raise during the
        metadata fetch; returning them would fail the whole download later.
        """
        try:
            self.get_download_metadata(url, download=False)
            return True
        except Exception:  # pylint: disable=broad-except
            logger.debug("Candidate %s unfetchable; skipping", url)
            return False

'''
ANCHOR = "    def search(self, song: Song, only_verified: bool = False) -> Optional[str]:"
if "_sl_fetchable" not in src and ANCHOR in src:
    src = src.replace(ANCHOR, HELPER + ANCHOR)
    changed = True

PAIRS = [
    # 1) single verified ISRC result
    ('''                logger.debug(
                    "[%s] Returning only ISRC result %s",
                    song.song_id,
                    isrc_results[0].url,
                )

                return isrc_results[0].url''',
     '''                logger.debug(
                    "[%s] Returning only ISRC result %s",
                    song.song_id,
                    isrc_results[0].url,
                )

                if self._sl_fetchable(isrc_results[0].url):
                    return isrc_results[0].url'''),
    # 2) best ISRC result above 80
    ('''                    if best_isrc[1] > 80.0:
                        logger.debug(
                            "[%s] Best ISRC result is %s with score %s",
                            song.song_id,
                            best_isrc[0].url,
                            best_isrc[1],
                        )

                        return best_isrc[0].url''',
     '''                    if best_isrc[1] > 80.0 and self._sl_fetchable(
                        best_isrc[0].url
                    ):
                        logger.debug(
                            "[%s] Best ISRC result is %s with score %s",
                            song.song_id,
                            best_isrc[0].url,
                            best_isrc[1],
                        )

                        return best_isrc[0].url'''),
    # 3) ISRC url found again in the text search results
    ('''            if isrc_result:
                logger.debug(
                    "[%s] Best ISRC result is %s", song.song_id, isrc_result.url
                )

                return isrc_result.url''',
     '''            if isrc_result and self._sl_fetchable(isrc_result.url):
                logger.debug(
                    "[%s] Best ISRC result is %s", song.song_id, isrc_result.url
                )

                return isrc_result.url'''),
    # 4) verified best result with score >= 80
    ('''                if best_score >= 80 and best_result.verified:
                    logger.debug(
                        "[%s] Returning verified best result %s with score %s",
                        song.song_id,
                        best_result.url,
                        best_score,
                    )

                    return best_result.url''',
     '''                if (
                    best_score >= 80
                    and best_result.verified
                    and self._sl_fetchable(best_result.url)
                ):
                    logger.debug(
                        "[%s] Returning verified best result %s with score %s",
                        song.song_id,
                        best_result.url,
                        best_score,
                    )

                    return best_result.url'''),
    # 5) view-count tie-breaker: get_views() calls get_download_metadata()
    #    without any guard, so ONE age-restricted candidate among the tied
    #    results aborts the whole search with AudioProviderError before any
    #    of the return-path guards run.
    ('''        data = self.get_download_metadata(url)

        return data["view_count"]''',
     '''        # SOUNDLOADER-PATCH: never let the view-count tie-breaker abort
        # the whole search - an age-restricted/removed candidate must count
        # as 0 views, not raise through search().
        try:
            data = self.get_download_metadata(url)
            return data.get("view_count") or 0
        except Exception:  # pylint: disable=broad-except
            logger.debug("get_views failed for %s; treating as 0", url)
            return 0'''),
    # 6) final best-result block: walk the top-5 by score
    ('''        # get the result with highest score
        best_result, best_score = self.get_best_result(results)
        logger.debug(
            "[%s] Returning best result %s with score %s",
            song.song_id,
            best_result.url,
            best_score,
        )

        return best_result.url''',
     '''        # SOUNDLOADER-PATCH: validate top candidates with yt-dlp before
        # returning. Walk the top-5 by score, fetch lightweight metadata, and
        # return the first one yt-dlp can actually reach. When every candidate
        # is unfetchable (e.g. all uploads of an explicit track are
        # age-restricted), return None so the next audio provider
        # (youtube -> soundcloud -> bandcamp) gets a chance, instead of
        # handing back a URL that is guaranteed to fail the download.
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

        logger.debug(
            "[%s] All candidates unfetchable; deferring to next provider",
            song.song_id,
        )
        return None'''),
]

missing = 0
for old, new in PAIRS:
    if new in src:
        continue
    if old in src:
        src = src.replace(old, new)
        changed = True
    else:
        missing += 1

if changed:
    with open(path, 'w') as f:
        f.write(src)
    print(f"Patch applied ({missing} pattern(s) not found)." if missing
          else "Patch applied.")
else:
    print("Already patched." if missing == 0
          else f"Nothing applied; {missing} pattern(s) not found.")
PYEOF
    success "spotdl search validation patch done"
fi

# ── 7b2. Patch spotdl: skip Spotify search for un-tagged files during scan ────
# spotdl's gather_known_songs() calls the Spotify search API for every MP3
# whose ID3 tags lack a WOAS (spotify URL) frame. On large libraries this
# burns the API quota in seconds (the daily limit is ~25k requests).
# Patch it to silently skip those files instead — they just won't be picked
# up by cross-folder deduplication, which is acceptable.
SEARCH_PY="$(find "$PIPX_VENVS/spotdl/lib" -name "search.py" -path "*/spotdl/utils/*" 2>/dev/null | head -1)"
if [ -n "$SEARCH_PY" ]; then
    info "Patching spotdl gather_known_songs to skip API calls on un-tagged files..."
    python3 - "$SEARCH_PY" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()
old = ('        # If the songs doesn\'t have metadata, try to get it from the filename\n'
       '        if song is None or song.url is None:\n'
       '            search_results = get_search_results(path.stem)\n'
       '            if len(search_results) == 0:\n'
       '                continue\n'
       '\n'
       '            song = search_results[0]')
new = ('        # Skip files without proper metadata instead of calling the Spotify\n'
       '        # search API (patched by Soundloader setup.sh to preserve API quota).\n'
       '        if song is None or song.url is None:\n'
       '            continue')
if old in src:
    with open(path, 'w') as f:
        f.write(src.replace(old, new))
    print("Patch applied.")
else:
    print("Patch already applied or signature changed; skipping.")
PYEOF
    success "spotdl gather_known_songs patch done"
fi

# ── 7c. Curate spotdl audio providers in the config ───────────────────────────
# - Drop piped: piped.video stopped serving JSON in 2025 (it now returns the
#   SPA HTML), so spotdl trips on JSONDecodeError for every track.
# - Append soundcloud and bandcamp as last-resort fallbacks: tracks missing
#   from YouTube (or only available there age-restricted) are often on
#   SoundCloud/Bandcamp, and providers are only consulted in order when the
#   previous ones return nothing usable.
SPOTDL_CONFIG="$HOME/.spotdl/config.json"
if [ -f "$SPOTDL_CONFIG" ]; then
    info "Curating spotdl audio_providers..."
    python3 - "$SPOTDL_CONFIG" <<'PYEOF'
import json, sys
p = sys.argv[1]
try:
    cfg = json.load(open(p))
except Exception:
    sys.exit(0)
providers = cfg.get("audio_providers", [])
changed = False
if "piped" in providers:
    providers = [a for a in providers if a != "piped"]
    changed = True
for extra in ("soundcloud", "bandcamp"):
    if extra not in providers:
        providers.append(extra)
        changed = True
if changed:
    cfg["audio_providers"] = providers
    json.dump(cfg, open(p, "w"), indent=2)
    print("audio_providers:", ", ".join(providers))
else:
    print("Already clean.")
PYEOF
    success "spotdl config curated"
fi

# ── 8. Compile AppleScript ────────────────────────────────────────────────────
info "Compiling Soundloader.app..."

APPLESCRIPT_SOURCE="$SCRIPT_DIR/app/Soundloader.applescript"
APP_DEST="/Applications/Soundloader.app"
TMP_SCRIPT="/tmp/Soundloader_build.applescript"

if [ ! -f "$APPLESCRIPT_SOURCE" ]; then
    error "AppleScript source not found at $APPLESCRIPT_SOURCE"
fi

# Bake the current git commit SHA into the app — no version.txt to maintain.
# The app compares this SHA against GitHub's API at launch to detect updates.
CURRENT_COMMIT="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")"

# Derive GitHub API URL for latest commit on main
REMOTE_ORIGIN="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo "")"
if [[ "$REMOTE_ORIGIN" == git@github.com:* ]]; then
    _GITHUB_PATH="${REMOTE_ORIGIN#git@github.com:}"; _GITHUB_PATH="${_GITHUB_PATH%.git}"
elif [[ "$REMOTE_ORIGIN" == https://github.com/* ]]; then
    _GITHUB_PATH="${REMOTE_ORIGIN#https://github.com/}"; _GITHUB_PATH="${_GITHUB_PATH%.git}"
else
    _GITHUB_PATH=""
fi
if [ -n "$_GITHUB_PATH" ]; then
    COMMITS_URL="https://api.github.com/repos/$_GITHUB_PATH/commits/main"
else
    COMMITS_URL=""
fi
success "Commit: ${CURRENT_COMMIT:0:7} (remote check: ${COMMITS_URL:-disabled})"

# Inject all compile-time values into the script
sed \
    -e "s|__SPOTDL_PATH__|$SPOTDL_PATH|g" \
    -e "s|__YTDLP_PATH__|$YTDLP_PATH|g" \
    -e "s|__REPO_PATH__|$SCRIPT_DIR|g" \
    -e "s|__CURRENT_COMMIT__|$CURRENT_COMMIT|g" \
    -e "s|__COMMITS_URL__|$COMMITS_URL|g" \
    "$APPLESCRIPT_SOURCE" > "$TMP_SCRIPT"

# Remove old app if present
if [ -d "$APP_DEST" ]; then
    rm -rf "$APP_DEST"
fi

osacompile -o "$APP_DEST" "$TMP_SCRIPT"
rm -f "$TMP_SCRIPT"

# Apply custom icon (replaces the default Script Editor applet icon)
# osacompile ships a compiled Assets.car that macOS prefers over applet.icns
# at runtime — including for the icon shown in `display dialog` / `display alert`.
# Removing it forces the loader to fall back to our applet.icns.
ICON_SRC="$SCRIPT_DIR/assets/soundloader.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APP_DEST/Contents/Resources/applet.icns"
    rm -f "$APP_DEST/Contents/Resources/Assets.car"
    rm -f "$APP_DEST/Contents/Resources/applet.rsrc"
    touch "$APP_DEST"
    # Bust the icon services cache so the new icon shows up immediately
    # (otherwise the Dock/Finder/dialog code keeps the old icon until logout)
    rm -rf "$HOME/Library/Caches/com.apple.iconservices.store" 2>/dev/null || true
    killall Dock 2>/dev/null || true
    killall Finder 2>/dev/null || true
fi

# Remove quarantine flag (app was built locally, shouldn't be quarantined,
# but being explicit prevents Gatekeeper dialogs on older macOS)
find "$APP_DEST" -exec xattr -c {} \; 2>/dev/null || true

success "App installed to $APP_DEST"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗"
echo "║   Setup complete!                                ║"
echo "╚══════════════════════════════════════════════════╝${RESET}"
echo ""
echo "  Open 'Soundloader' from /Applications or Spotlight."
echo ""
echo "  YouTube  → works immediately, no setup needed."
echo "  Spotify  → the app will guide you through credentials on first use."
echo "             See docs/spotify-setup.md for a step-by-step guide."
echo ""
