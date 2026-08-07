#!/bin/bash
# ytdlp_retry.sh — re-run a yt-dlp command until it exits 0 or the attempt
# budget is exhausted.
#
# yt-dlp exits non-zero when any item in the run failed (even with
# --ignore-errors), and transient failures usually succeed on a plain re-run.
# A temporary --download-archive is appended so retry attempts skip the items
# that already succeeded within this run; the archive is deleted afterwards,
# so cross-run behaviour (--no-overwrites etc.) is unchanged.
#
# Usage: ytdlp_retry.sh MAX_ATTEMPTS /path/to/yt-dlp [yt-dlp args...]

MAX="$1"; shift

ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/soundloader-archive.XXXXXX")"
trap 'rm -f "$ARCHIVE"' EXIT

attempt=1
while true; do
    "$@" --download-archive "$ARCHIVE"
    rc=$?
    [ "$rc" -eq 0 ] && exit 0
    # Don't retry on user interrupt (130) or bad usage (2).
    [ "$rc" -eq 130 ] || [ "$rc" -eq 2 ] && exit "$rc"
    [ "$attempt" -ge "$MAX" ] && exit "$rc"
    attempt=$((attempt + 1))
    echo ""
    echo "⟳ Some items failed (exit $rc) — retry $attempt/$MAX in 5s…"
    sleep 5
done
