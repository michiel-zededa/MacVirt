#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Packs build/MacVirt.app into dist/MacVirt-<version>-arm64.dmg (+ .sha256).
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION=${VERSION:-0.0.0-dev}
NAME=MacVirt-$VERSION-arm64
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p dist
cp -R build/MacVirt.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "dist/$NAME.dmg"
hdiutil create -quiet -volname "MacVirt $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "dist/$NAME.dmg"
( cd dist && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256" )
echo "==> dist/$NAME.dmg ($(du -h "dist/$NAME.dmg" | cut -f1))"
