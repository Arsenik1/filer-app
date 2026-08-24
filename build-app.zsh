#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SOURCE_FILE="$SCRIPT_DIR/app/FilerApp.swift"
APP_DIR="$SCRIPT_DIR/build/Filer.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
TARGET_TRIPLE="arm64-apple-macos26.0"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

swiftc "$SOURCE_FILE" \
  -target "$TARGET_TRIPLE" \
  -Xlinker -no_adhoc_codesign \
  -framework AppKit \
  -framework Carbon \
  -framework Foundation \
  -o "$MACOS_DIR/Filer"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Filer</string>
  <key>CFBundleIdentifier</key>
  <string>local.filer.app</string>
  <key>CFBundleName</key>
  <string>Filer</string>
  <key>CFBundleDisplayName</key>
  <string>Filer</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
</dict>
</plist>
PLIST

chmod +x "$MACOS_DIR/Filer"
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

echo "$APP_DIR"
