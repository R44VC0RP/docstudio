#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$HOME/Applications/Dock Studio.app}"
if [[ -e "$APP" ]]; then
  ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)
  [[ "$ID" == "com.vogel.dockstudio" ]] || { echo "Refusing to overwrite an unrelated app: $APP" >&2; exit 1; }
fi
mkdir -p "$ROOT/.build/DockStudio.iconset"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -O "$ROOT/main.swift" "$ROOT"/Sources/*.swift -o "$ROOT/.build/DockStudio"
"$ROOT/.build/DockStudio" --export-icon "$ROOT/.build/icon.png"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$ROOT/.build/icon.png" --out "$ROOT/.build/DockStudio.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" "$ROOT/.build/icon.png" --out "$ROOT/.build/DockStudio.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
iconutil -c icns "$ROOT/.build/DockStudio.iconset" -o "$APP/Contents/Resources/DockStudio.icns"
cp "$ROOT/.build/DockStudio" "$APP/Contents/MacOS/DockStudio"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
SIGNING_FLAGS=(--force --sign "$SIGNING_IDENTITY" --identifier com.vogel.dockstudio)
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SIGNING_FLAGS+=(--options runtime --timestamp)
fi
codesign "${SIGNING_FLAGS[@]}" "$APP"
printf 'Built %s\n' "$APP"
