#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
APP_DIR="$SCRIPT_DIR/build/Filer.app"
DMG_PATH="$SCRIPT_DIR/build/Filer.dmg"
VOLUME_NAME="Filer"
STAGING_DIR="$(mktemp -d "${TMPDIR%/}/filer-dmg.XXXXXX")"

cleanup() {
  rm -rf "$STAGING_DIR"
}

trap cleanup EXIT INT TERM

"$SCRIPT_DIR/build-app.zsh" >/dev/null

ditto "$APP_DIR" "$STAGING_DIR/Filer.app"
ln -s /Applications "$STAGING_DIR/Applications"

cat > "$STAGING_DIR/How to Open.txt" <<'EOF'
Filer

1. Drag "Filer.app" into Applications.
2. Open Filer from Applications.
3. Click the F status bar icon or press Ctrl + Option + Cmd + F.
4. Enter a file name (file is the default).
5. Paste text into the editor and choose the desired file extension from the dropdown (file.md is the default).
6. Click the copy button or press Command + Return.
7. Paste the resulting file into Finder, a chat, or a file upload field.

The app always replaces the same file:
the macOS temporary directory's Filer/<name>.<extension>. The name resets to
file and the extension to .md each time the panel opens.
EOF

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov "$DMG_PATH" >/dev/null

echo "$DMG_PATH"
