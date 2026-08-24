#!/bin/sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
bin="$root/.build/release/ScheduleBarApp"
app="$root/.build/ScheduleBar.app"
plugin="$root/Plugins/schedulebar"
sign_identity="${SCHEDULEBAR_CODESIGN_IDENTITY:--}"

if [ ! -x "$bin" ]; then
  echo "missing $bin — run: make build" >&2
  exit 1
fi

if [ -e "$app" ]; then
  rm -r "$app"
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Plugins"
cp "$bin" "$app/Contents/MacOS/ScheduleBar"
cp -R "$plugin" "$app/Contents/Plugins/schedulebar"
chmod 755 "$app/Contents/Plugins/schedulebar/bin/schedulebar-mcp"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>ScheduleBar</string>
  <key>CFBundleIdentifier</key>
  <string>com.leoakaliu.schedulebar</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>ScheduleBar</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --sign "$sign_identity" "$app/Contents/Plugins/schedulebar/bin/schedulebar-mcp"
/usr/bin/codesign --force --deep --sign "$sign_identity" "$app"
/usr/bin/codesign --verify --deep --strict "$app"

echo "built $app"
