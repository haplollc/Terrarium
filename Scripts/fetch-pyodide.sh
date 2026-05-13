#!/usr/bin/env bash
#
# Fetch the Pyodide core runtime into Resources/pyodide-runtime/.
# Run from anywhere; paths are resolved relative to the script.
#
# We bundle pyodide-core (~6 MB), NOT the full pyodide distribution (408 MB).
# Individual packages (numpy, pandas, matplotlib, …) are downloaded by
# Pyodide's micropip from the CDN on first `import`, then cached in the
# device's IndexedDB-backed persistent filesystem.

set -euo pipefail

PYODIDE_VERSION="${PYODIDE_VERSION:-0.29.4}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRARIUM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="$TERRARIUM_DIR/Resources/pyodide-runtime"

echo "fetch-pyodide: target=$TARGET_DIR"
echo "fetch-pyodide: version=$PYODIDE_VERSION"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE="$TMP_DIR/pyodide-core.tar.bz2"
URL="https://github.com/pyodide/pyodide/releases/download/${PYODIDE_VERSION}/pyodide-core-${PYODIDE_VERSION}.tar.bz2"

echo "fetch-pyodide: downloading $URL"
curl -sL --fail -o "$ARCHIVE" "$URL"

echo "fetch-pyodide: extracting"
tar -xjf "$ARCHIVE" -C "$TMP_DIR"

# The archive expands into TMP_DIR/pyodide/ — move that into the target.
mkdir -p "$TARGET_DIR"
rm -rf "$TARGET_DIR"/*
mv "$TMP_DIR/pyodide/"* "$TARGET_DIR/"

echo "fetch-pyodide: wrote $(find "$TARGET_DIR" -type f | wc -l | tr -d ' ') files, $(du -sh "$TARGET_DIR" | cut -f1) total"
echo
echo "Next step:"
echo "  Add Packages/Kuzco/Resources/pyodide-runtime/ to the Xcode app's"
echo "  Resources build phase as a folder reference (blue folder icon)."
echo "  It will be bundled alongside python-stdlib/ and site-packages/."
