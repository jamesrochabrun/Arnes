#!/bin/sh
# Build arnes (release) and install it over the binary on PATH.
#
# The replacement goes through a temp file + `mv` on purpose: `cp` over an existing
# Mach-O keeps the inode, which invalidates macOS's cached code-signature and every
# later launch dies with SIGKILL (exit 137). `mv` gives the destination a fresh inode.
#
# Prints a one-line receipt (version · git sha · time · path) and refuses to finish
# unless the *installed* binary actually launches — so "did the install take?" is
# never a guess.
set -e
cd "$(dirname "$0")/.."

swift build -c release --product arnes >/dev/null

dest="$(command -v arnes || true)"
[ -n "$dest" ] || dest=/opt/homebrew/bin/arnes

tmp="$dest.new.$$"
cp .build/release/arnes "$tmp"
chmod 755 "$tmp"
mv -f "$tmp" "$dest"

version="$("$dest" --version)" # launches the installed copy — a broken install fails here
sha="$(git rev-parse --short HEAD 2>/dev/null || echo 'no-git')"
dirty=""
[ -z "$(git status --porcelain 2>/dev/null)" ] || dirty="+local-changes"
echo "installed arnes $version · $sha$dirty · $(date '+%Y-%m-%d %H:%M:%S') → $dest"
