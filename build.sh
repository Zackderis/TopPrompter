#!/bin/zsh
# Builds TopPrompter.app next to this script.
set -e
cd "${0:A:h}"
APP=TopPrompter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
for ARCH in arm64 x86_64; do swiftc -O -swift-version 5 -target $ARCH-apple-macos14.0 main.swift Follower.swift Voice.swift Phone.swift -o "${TMPDIR:-/tmp}/TopPrompter-$ARCH" -framework Cocoa -framework Carbon -framework AVFoundation -framework Speech -framework CoreAudio -framework AudioToolbox -framework Network -framework CoreImage -framework Security; done
lipo -create "${TMPDIR:-/tmp}/TopPrompter-arm64" "${TMPDIR:-/tmp}/TopPrompter-x86_64" -output "$APP/Contents/MacOS/TopPrompter"
mkdir -p "$APP/Contents/Resources"
WAKE=$(base64 -i wake.mp4 | tr -d '\n')
sed "s|__WAKE_VIDEO__|$WAKE|" phone.html > "$APP/Contents/Resources/phone.html"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TopPrompter</string>
  <key>CFBundleExecutable</key><string>TopPrompter</string>
  <key>CFBundleIdentifier</key><string>local.toolkit.TopPrompter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>TopPrompter shows your script on your iPhone over your local network.</string>
  <key>NSMicrophoneUsageDescription</key><string>TopPrompter listens to your voice so it can scroll while you talk and follow your place in the script.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>TopPrompter recognises your words on this Mac to keep your place in the script.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $PWD/$APP"
