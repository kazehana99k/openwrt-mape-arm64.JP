#!/bin/sh
# Build the release tarball for openwrt-mape-arm64.
#
# Output: build/openwrt-mape-arm64.tar.gz
#
# This tarball contains the deployable package files with paths preserved
# (e.g. lib/netifd/proto/mape.sh, usr/bin/mape-calc, ...). On the target
# router it extracts directly into /:
#
#   tar -C / -xzf openwrt-mape-arm64.tar.gz
#
# Usage:
#   tools/build-release.sh                 # build tarball only
#   tools/build-release.sh --upload v0.1.0 # build + upload to GitHub release
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

OUT_DIR="build"
TARBALL="$OUT_DIR/openwrt-mape-arm64.tar.gz"

mkdir -p "$OUT_DIR"
rm -f "$TARBALL"

# Build the tarball. Files are stored relative to / so a `tar -C / -x` on
# the router puts everything in the right place.
tar -C package/mape/files -czf "$TARBALL" .

echo "Built: $TARBALL"
echo "Size:  $(du -h "$TARBALL" | cut -f1)"
echo "Files inside:"
tar -tzf "$TARBALL" | sed 's/^/  /'

if [ "$1" = "--upload" ]; then
    TAG="${2:-$(git describe --tags --abbrev=0)}"
    [ -n "$TAG" ] || { echo "ERR: --upload requires a tag (or one must exist)" >&2; exit 1; }
    echo ""
    echo "Uploading $TARBALL and install.sh to release $TAG..."
    gh release upload "$TAG" "$TARBALL" install.sh --clobber
    echo "Done. Visit: https://github.com/kazehana99k/openwrt-mape-arm64.JP/releases/tag/$TAG"
fi
