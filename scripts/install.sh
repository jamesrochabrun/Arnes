#!/bin/sh
# Build and install arnes to a PATH directory (default: /opt/homebrew/bin).
#
# The remove + copy + ad-hoc re-sign dance matters on Apple Silicon: overwriting
# a signed binary in place corrupts the kernel's signature cache and the next
# launch dies with "zsh: killed".
set -e

PREFIX="${1:-/opt/homebrew/bin}"
cd "$(dirname "$0")/.."

swift build -c release
rm -f "$PREFIX/arnes"
cp .build/release/arnes "$PREFIX/arnes"
codesign -f -s - "$PREFIX/arnes"
echo "installed $("$PREFIX/arnes" --version 2>/dev/null || echo arnes) → $PREFIX/arnes"
