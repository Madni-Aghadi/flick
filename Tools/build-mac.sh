#!/bin/zsh
# Builds Flick.app for the Mac into ./build. Pass --install to copy it to /Applications and open it.
# Uses Xcode (signed with your team, so permissions survive rebuilds) when its license is accepted,
# otherwise falls back to SwiftPM + an ad-hoc signed bundle.
set -e
cd "${0:A:h}/.."
mkdir -p build

if xcrun --sdk macosx --show-sdk-version >/dev/null 2>&1; then
  echo "building with Xcode"
  xcodegen generate -q
  xcodebuild -project Flick.xcodeproj -scheme FlickMac -configuration Release -allowProvisioningUpdates \
    -derivedDataPath build/dd build -quiet
  rm -rf build/Flick.app
  cp -R build/dd/Build/Products/Release/Flick.app build/Flick.app
else
  echo "Xcode license not accepted: SwiftPM fallback (ad-hoc signed)"
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  swift build -c release --product FlickMac
  PREFIX=$(grep -h "^FLICK_BUNDLE_PREFIX" Config/Flick.xcconfig Config/Local.xcconfig 2>/dev/null | tail -1 | sed 's/.*= *//')
  APP=build/Flick.app
  rm -rf $APP && mkdir -p $APP/Contents/{MacOS,Resources}
  cp .build/release/FlickMac $APP/Contents/MacOS/Flick
  ICONSET=build/AppIcon.iconset && rm -rf $ICONSET && mkdir -p $ICONSET
  for f in Mac/App/Assets.xcassets/AppIcon.appiconset/mac-*.png; do
    n=${f:t}; n=${n#mac-}; base=${n%%@*}; scale=${n#*@}; scale=${scale%x.png}
    [[ $scale == 1 ]] && cp $f $ICONSET/icon_${base}x${base}.png || cp $f $ICONSET/icon_${base}x${base}@2x.png
  done
  iconutil -c icns $ICONSET -o $APP/Contents/Resources/AppIcon.icns
  cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>${PREFIX}.flick.mac</string>
  <key>CFBundleName</key><string>Flick</string>
  <key>CFBundleDisplayName</key><string>Flick</string>
  <key>CFBundleExecutable</key><string>Flick</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Flick listens for your paired iPhone.</string>
  <key>NSBonjourServices</key><array><string>_flick._tcp</string><string>_flickpair._tcp</string></array>
</dict></plist>
PLIST
  codesign --force --deep -s - $APP
fi
echo "built build/Flick.app"

if [[ "$1" == "--install" ]]; then
  pkill -x Flick 2>/dev/null || true
  pkill -x Flick 2>/dev/null || true
  rm -rf /Applications/Flick.app /Applications/Flick.app
  cp -R build/Flick.app /Applications/Flick.app
  open /Applications/Flick.app
  echo "installed /Applications/Flick.app"
fi
