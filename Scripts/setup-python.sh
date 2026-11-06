#!/usr/bin/env bash
#
# setup-python.sh — fetch Python.xcframework from BeeWare's
# Python-Apple-support release and drop it next to this package.
#
# Terrarium links against this xcframework but doesn't commit it to the
# repo (it's a ~112 MB binary blob). Run once per checkout.

set -euo pipefail

# 3.13-b13 is Python 3.13.11, the build the headers in Sources/CPython and
# the bundled stdlib and lib-dynload modules come from.
PYTHON_SUPPORT_VERSION="${PYTHON_SUPPORT_VERSION:-3.13-b13}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRARIUM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$TERRARIUM_DIR/Python.xcframework"

if [ -d "$TARGET" ]; then
    echo "setup-python: $TARGET already exists. Remove it manually if you want to reinstall."
    exit 0
fi

echo "setup-python: target=$TARGET"
echo "setup-python: version=$PYTHON_SUPPORT_VERSION"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE="$TMP_DIR/python-ios-support.tar.gz"
URL="https://github.com/beeware/Python-Apple-support/releases/download/${PYTHON_SUPPORT_VERSION}/Python-${PYTHON_SUPPORT_VERSION%-*}-iOS-support.${PYTHON_SUPPORT_VERSION#*-}.tar.gz"

echo "setup-python: downloading $URL"
curl -sL --fail -o "$ARCHIVE" "$URL"

echo "setup-python: extracting"
tar -xzf "$ARCHIVE" -C "$TMP_DIR"

# BeeWare's tarball contains a `Python.xcframework` directory at its
# root. Move it next to the package.
if [ -d "$TMP_DIR/Python.xcframework" ]; then
    mv "$TMP_DIR/Python.xcframework" "$TARGET"
else
    echo "setup-python: ERROR: archive did not contain Python.xcframework. Layout was:"
    ls "$TMP_DIR"
    exit 1
fi

# BeeWare's tarball no longer ships the build helpers the app's
# "Wrap Python Extensions" build phase sources (utils.sh wraps raw .so
# files into signable .frameworks). Install our vendored copies.
mkdir -p "$TARGET/build"
cp "$SCRIPT_DIR/python-build-support/"* "$TARGET/build/"

echo "setup-python: done. $(du -sh "$TARGET" | cut -f1) at $TARGET"
echo
echo "Next steps:"
echo "  • Add $TERRARIUM_DIR to your app as a local Swift package"
echo "    (Xcode: File → Add Package Dependencies → Add Local…)."
echo "  • Nothing else to copy: the package links Python.xcframework and"
echo "    bundles its Python resources, and Pyodide loads from jsDelivr."
