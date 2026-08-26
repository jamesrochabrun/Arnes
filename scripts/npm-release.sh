#!/bin/sh
# Generate the npm distribution packages from release binaries.
#
#   scripts/npm-release.sh <version> <dist-dir> <out-dir>
#
# <dist-dir> must hold the release artifacts (arnes-macos-arm64, arnes-macos-x86_64,
# arnes-linux-x86_64, arnes-linux-aarch64). Writes one publishable package dir per
# platform plus the main `arnes` launcher package into <out-dir>. Publishing itself
# happens in the release workflow (platform packages first, `arnes` last).
set -eu

VERSION="${1:?usage: npm-release.sh <version> <dist-dir> <out-dir>}"
DIST="${2:?usage: npm-release.sh <version> <dist-dir> <out-dir>}"
OUT="${3:?usage: npm-release.sh <version> <dist-dir> <out-dir>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

make_platform() {
  artifact="$1" os="$2" cpu="$3"
  name="arnes-$os-$cpu"
  src="$DIST/$artifact"
  [ -f "$src" ] || { echo "npm-release: missing binary $src" >&2; exit 1; }
  mkdir -p "$OUT/$name/bin"
  cp "$src" "$OUT/$name/bin/arnes"
  chmod 755 "$OUT/$name/bin/arnes"
  cat > "$OUT/$name/package.json" <<EOF
{
  "name": "$name",
  "version": "$VERSION",
  "description": "arnes binary for $os $cpu",
  "license": "MIT",
  "repository": { "type": "git", "url": "git+https://github.com/jamesrochabrun/Arnes.git" },
  "os": ["$os"],
  "cpu": ["$cpu"],
  "files": ["bin/arnes"]
}
EOF
}

make_platform arnes-macos-arm64   darwin arm64
make_platform arnes-macos-x86_64  darwin x64
make_platform arnes-linux-x86_64  linux  x64
make_platform arnes-linux-aarch64 linux  arm64

mkdir -p "$OUT/arnes"
cp -R "$REPO_ROOT/npm/arnes/." "$OUT/arnes/"
# Stamp the release version over every 0.0.0 placeholder — the package version and
# the optionalDependencies pins move in lockstep.
sed -i.bak "s/\"0\.0\.0\"/\"$VERSION\"/g" "$OUT/arnes/package.json"
rm -f "$OUT/arnes/package.json.bak"

echo "npm packages for $VERSION written to $OUT"
