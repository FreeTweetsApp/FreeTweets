#!/bin/bash
# Compiles FreeTweets and packages it into a double-clickable macOS .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="FreeTweets"

echo "▸ Building (release)…"
swift build -c release

BINDIR="$(swift build -c release --show-bin-path)"
BIN="$BINDIR/XFeed"
APP="$APP_NAME.app"

echo "▸ Assembling $APP…"
rm -rf "$APP" "XFeed.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# Copy SwiftPM-generated resource bundles (e.g. the branding logo) so
# `Bundle.module` resolves them from the app's Resources directory at runtime.
for bundle in "$BINDIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    echo "▸ Bundling resources: $(basename "$bundle")"
    cp -R "$bundle" "$APP/Contents/Resources/"
done

# Build AppIcon.icns. freetweetslogo.png is already a finished macOS-style
# icon (rounded square + shadow baked in), so use it at full bleed with no
# extra insetting. Otherwise fall back to a raw logo that needs compositing.
WORK="$(mktemp -d)"
NEEDS_INSET=1
if [ -f "freetweetslogo.png" ]; then
    ICON_SRC="freetweetslogo.png"
    NEEDS_INSET=0
elif [ -f "twitter-app-icon.webp" ]; then
    ICON_SRC="$WORK/icon_src.png"
    sips -s format png "twitter-app-icon.webp" --out "$ICON_SRC" >/dev/null 2>&1
elif [ -f "twitter.png" ]; then
    ICON_SRC="twitter.png"
else
    ICON_SRC=""
fi
if [ -n "$ICON_SRC" ] && [ -f "$ICON_SRC" ]; then
    echo "▸ Generating app icon…"
    ICONSET="$WORK/AppIcon.iconset"
    mkdir -p "$ICONSET"
    if [ "$NEEDS_INSET" = "1" ]; then
        # Inset the full-bleed squircle onto a transparent canvas for proper margins.
        MASTER="$WORK/master.png"
        if swift make_icon.swift "$ICON_SRC" "$MASTER" 2>/dev/null; then
            BASE="$MASTER"
        else
            echo "  ⚠ inset step failed, using raw image"
            BASE="$ICON_SRC"
        fi
    else
        BASE="$ICON_SRC"
    fi
    for size in 16 32 128 256 512; do
        sips -z $size $size          "$BASE" --out "$ICONSET/icon_${size}x${size}.png"      >/dev/null 2>&1
        sips -z $((size*2)) $((size*2)) "$BASE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null \
        && echo "  ✓ AppIcon.icns" || echo "  ⚠ icon generation failed (app still builds)"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>FreeTweets</string>
    <key>CFBundleDisplayName</key>       <string>FreeTweets</string>
    <key>CFBundleIdentifier</key>        <string>com.newcompassmedia.freetweets</string>
    <key>CFBundleExecutable</key>        <string>FreeTweets</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper lets it launch locally.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ Built ./$APP"
echo "  Run with:  open ./$APP"
