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

echo -e "${BOLD}"
echo "╔══════════════════════════════════╗"
echo "║   Sounddrop — Setup              ║"
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

# ── 5. spotdl (nyekuuu fork — adds --user-auth OAuth for Spotify) ─────────────
info "Checking spotdl..."
SPOTDL_FORK="git+https://github.com/nyekuuu/spotify-downloader.git"
if pipx list 2>/dev/null | grep -q "spotdl"; then
    info "Upgrading spotdl from nyekuuu fork..."
    pipx install --force --python "$PYTHON_FOR_SPOTDL" "$SPOTDL_FORK" \
        || warn "spotdl upgrade failed, keeping existing version"
else
    info "Installing spotdl from nyekuuu fork..."
    pipx install --python "$PYTHON_FOR_SPOTDL" "$SPOTDL_FORK"
fi

# ── 6. yt-dlp (always via brew — pip/system installs use outdated Python) ─────
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

# ── 7b. Patch spotdl: downgrade YouTube Music block from crash to warning ─────
# spotdl raises DownloaderError if YTM is temporarily IP-blocked, even when
# fallback providers are configured. This patch makes it log a warning and
# drop youtube-music from the provider list for that run instead of aborting.
info "Patching spotdl YTM block to graceful fallback..."
ENTRY_POINT="$(find "$PIPX_VENVS/spotdl/lib" -name "entry_point.py" -path "*/spotdl/console/*" 2>/dev/null | head -1)"
if [ -n "$ENTRY_POINT" ]; then
    python3 - "$ENTRY_POINT" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()

old = '            raise DownloaderError(\n                "You are blocked by YouTube Music. "\n                "Please use a VPN, change youtube-music to piped, or use other audio providers"\n            )'

new = ('            logger.warning(\n'
       '                "YouTube Music is currently unavailable (IP block or regional restriction). "\n'
       '                "Falling back to remaining audio providers: %s",\n'
       '                [p for p in downloader_settings["audio_providers"] if p != "youtube-music"],\n'
       '            )\n'
       '            downloader_settings["audio_providers"] = [\n'
       '                p for p in downloader_settings["audio_providers"] if p != "youtube-music"\n'
       '            ]\n'
       '            if not downloader_settings["audio_providers"]:\n'
       '                raise DownloaderError(\n'
       '                    "YouTube Music is blocked and no fallback audio providers are configured. "\n'
       '                    "Add \'youtube\' or \'piped\' to audio_providers in your spotdl config."\n'
       '                )')

if old in src:
    with open(path, 'w') as f:
        f.write(src.replace(old, new))
    print("Patch applied.")
else:
    print("Already patched or source changed — skipping.")
PYEOF
    success "spotdl YTM patch done"
else
    warn "spotdl entry_point.py not found — skipping YTM patch"
fi

# ── 8. Compile AppleScript ────────────────────────────────────────────────────
info "Compiling Sounddrop.app..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLESCRIPT_SOURCE="$SCRIPT_DIR/app/Sounddrop.applescript"
APP_DEST="/Applications/Sounddrop.app"
TMP_SCRIPT="/tmp/Sounddrop_build.applescript"

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
echo "  Open 'Sounddrop' from /Applications or Spotlight."
echo ""
echo "  YouTube  → works immediately, no setup needed."
echo "  Spotify  → the app will guide you through credentials on first use."
echo "             See docs/spotify-setup.md for a step-by-step guide."
echo ""
