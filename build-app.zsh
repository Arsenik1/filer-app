#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
APP_DIR="$SCRIPT_DIR/build/Filer.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_SOURCE="$SCRIPT_DIR/app/Resources/AppIcon.svg"
TARGET_TRIPLE="arm64-apple-macos26.0"
SWIFT_FLAGS=()

if [[ "${FILER_DEBUG:-0}" == "1" ]]; then
  SWIFT_FLAGS=(-D FILER_DEBUG)
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

swiftc "$SCRIPT_DIR"/app/*.swift \
  -target "$TARGET_TRIPLE" \
  -Xlinker -no_adhoc_codesign \
  -framework AppKit \
  -framework Carbon \
  -framework Foundation \
  -framework ImageIO \
  "${SWIFT_FLAGS[@]}" \
  -o "$MACOS_DIR/Filer"

ICON_STAGING_DIR="$(mktemp -d "${TMPDIR%/}/filer-icon.XXXXXX")"
trap 'rm -rf "$ICON_STAGING_DIR"' EXIT
ICONSET_DIR="$ICON_STAGING_DIR/AppIcon.iconset"
ICON_PNG="$ICON_STAGING_DIR/AppIcon.png"
mkdir -p "$ICONSET_DIR"

sips -s format png "$ICON_SOURCE" --out "$ICON_PNG" >/dev/null
for size in 16 32 128 256 512; do
  double_size=$((size * 2))
  icon_name="icon_${size}x${size}"
  sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET_DIR/$icon_name.png" >/dev/null
  sips -z "$double_size" "$double_size" "$ICON_PNG" \
    --out "$ICONSET_DIR/$icon_name@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"

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
  <key>CFBundleIconFile</key>
  <string>AppIcon.icns</string>
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
