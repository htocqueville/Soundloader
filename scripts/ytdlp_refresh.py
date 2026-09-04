#!/usr/bin/env python3
"""
ytdlp_refresh.py — keep yt-dlp current everywhere Soundloader uses it.

Why: YouTube changes its player / streaming rules every few weeks and yt-dlp
ships a fix within days. An outdated yt-dlp is the one failure that breaks
*every* track at once: spotdl raises "YT-DLP download error" on each song
(Sept 2026: extraction worked, the media request itself came back HTTP 403),
and direct YouTube / SoundCloud runs fail the same way inside ytdlp_retry.sh.
No retry can work around that — the fix is always "update yt-dlp", so the
app does it automatically instead of waiting for someone to notice.

Two copies matter:
  • the `yt_dlp` module inside spotdl's pipx venv — what spotdl actually
    downloads with. This script is meant to run on that venv's interpreter
    (`…/pipx/venvs/spotdl/bin/python3`), so `sys.executable -m pip` targets
    exactly that copy. setup.sh only ever refreshed the Homebrew binary,
    which spotdl never touches — that is how the venv copy went stale.
  • the Homebrew `yt-dlp` binary — used by the SoundCloud and YouTube
    handlers of the app.

Flow: one small request to PyPI for the latest version, then upgrade only
the copies that are behind. Throttled to once per --max-age-hours through a
stamp file, because the app calls it before every download; --force bypasses
the throttle (spotify_download.py uses it before its first retry, setup.sh
at install time). It never blocks a download: every failure is caught and
reported as a one-line warning, and the exit code is always 0.
"""
import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

PYPI_URL = "https://pypi.org/pypi/yt-dlp/json"
STAMP = Path.home() / ".soundloader" / "ytdlp_refresh.stamp"
TAG = "[yt-dlp]"


def _vtuple(version: str):
    """'2026.08.19' / '2026.8.19' → (2026, 8, 19); None when unparsable."""
    nums = re.findall(r"\d+", version or "")
    return tuple(int(n) for n in nums) if nums else None


def _behind(current: str, latest: str) -> bool:
    cur, new = _vtuple(current), _vtuple(latest)
    return bool(new) and (not cur or cur < new)


def _run(cmd, timeout, env=None):
    return subprocess.run(cmd, capture_output=True, text=True,
                          timeout=timeout, env=env)


def _last_line(proc) -> str:
    text = (proc.stderr or proc.stdout or "").strip()
    return text.splitlines()[-1] if text else f"exit {proc.returncode}"


def pypi_latest(timeout: float = 8) -> str:
    with urllib.request.urlopen(PYPI_URL, timeout=timeout) as resp:
        return json.load(resp)["info"]["version"]


# ── spotdl venv module ────────────────────────────────────────────────────────

def venv_version() -> str:
    proc = _run([sys.executable, "-c",
                 "import yt_dlp; print(yt_dlp.version.__version__)"], 60)
    return proc.stdout.strip() if proc.returncode == 0 else ""


def upgrade_venv() -> None:
    proc = _run([sys.executable, "-m", "pip", "install", "--upgrade",
                 "--quiet", "--disable-pip-version-check",
                 "--retries", "1", "--timeout", "20", "yt-dlp"], 300)
    if proc.returncode == 0:
        return
    # pipx may build venvs without pip; its own helper reaches them.
    pipx = shutil.which("pipx")
    if pipx and "No module named pip" in (proc.stderr or ""):
        proc = _run([pipx, "runpip", "spotdl", "install", "--upgrade",
                     "--quiet", "--disable-pip-version-check", "yt-dlp"], 300)
        if proc.returncode == 0:
            return
    raise RuntimeError(_last_line(proc))


def refresh_venv(latest: str) -> bool:
    if importlib.util.find_spec("spotdl") is None:
        print(f"{TAG} not running on spotdl's venv interpreter — "
              f"module copy left untouched")
        return True
    current = venv_version()
    if not _behind(current, latest):
        print(f"{TAG} spotdl venv: {current} (up to date)")
        return True
    print(f"{TAG} spotdl venv: {current or '?'} → {latest}, updating…",
          flush=True)
    try:
        upgrade_venv()
    except Exception as exc:  # noqa: BLE001 — never block a download
        print(f"{TAG} ⚠ venv update failed: {exc}")
        return False
    print(f"{TAG} spotdl venv: now {venv_version() or '?'}")
    return True


# ── Homebrew binary ───────────────────────────────────────────────────────────

def brew_binary():
    """Return (brew, path-to-brew's-yt-dlp or None); (None, None) w/o brew."""
    brew = shutil.which("brew")
    if not brew:
        brew = next((p for p in ("/opt/homebrew/bin/brew", "/usr/local/bin/brew")
                     if os.path.exists(p)), None)
    if not brew:
        return None, None
    proc = _run([brew, "--prefix"], 60)
    prefix = (proc.stdout.strip() if proc.returncode == 0
              else os.path.dirname(os.path.dirname(brew)))
    binary = Path(prefix) / "bin" / "yt-dlp"
    return brew, (binary if binary.exists() else None)


def binary_version(binary: Path) -> str:
    proc = _run([str(binary), "--version"], 60)
    return proc.stdout.strip() if proc.returncode == 0 else ""


def upgrade_brew(brew: str) -> None:
    env = dict(os.environ, HOMEBREW_NO_ENV_HINTS="1",
               HOMEBREW_NO_INSTALL_CLEANUP="1")
    proc = _run([brew, "upgrade", "yt-dlp"], 420, env=env)
    if proc.returncode != 0:
        raise RuntimeError(_last_line(proc))


def refresh_brew(latest: str) -> bool:
    brew, binary = brew_binary()
    if not binary:
        return True  # nothing to refresh (no Homebrew yt-dlp on this Mac)
    current = binary_version(binary)
    if not _behind(current, latest):
        print(f"{TAG} Homebrew binary: {current} (up to date)")
        return True
    print(f"{TAG} Homebrew binary: {current or '?'} → {latest}, updating…",
          flush=True)
    try:
        upgrade_brew(brew)
    except Exception as exc:  # noqa: BLE001
        print(f"{TAG} ⚠ Homebrew update failed: {exc}")
        return False
    now = binary_version(binary)
    if _behind(now, latest):
        print(f"{TAG} Homebrew binary: {now or '?'} (bottle for {latest} not "
              f"published yet — will retry on a later run)")
    else:
        print(f"{TAG} Homebrew binary: now {now}")
    return True


# ── main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--force", action="store_true",
                    help="Check even if a check ran within --max-age-hours")
    ap.add_argument("--max-age-hours", type=float, default=24,
                    help="Throttle interval between checks (default 24)")
    ap.add_argument("--stamp", default=str(STAMP),
                    help=f"Throttle stamp file (default {STAMP})")
    args = ap.parse_args()

    stamp = Path(args.stamp)
    if not args.force and stamp.exists():
        age_h = (time.time() - stamp.stat().st_mtime) / 3600
        if 0 <= age_h < args.max_age_hours:
            print(f"{TAG} last checked {age_h:.1f} h ago — skipping")
            return 0

    try:
        latest = pypi_latest()
    except Exception as exc:  # noqa: BLE001 — offline, PyPI down, DNS…
        print(f"{TAG} PyPI unreachable ({exc.__class__.__name__}) — "
              f"skipping update check")
        return 0

    refresh_venv(latest)
    refresh_brew(latest)

    # Stamp whenever the check itself ran, even if an upgrade failed:
    # a persistent failure must not cost every download a long retry, and
    # spotify_download.py re-runs with --force before retrying anyway.
    try:
        stamp.parent.mkdir(parents=True, exist_ok=True)
        stamp.touch()
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 — belt and braces: never block
        print(f"{TAG} ⚠ refresh skipped: {exc.__class__.__name__}: {exc}")
        sys.exit(0)
