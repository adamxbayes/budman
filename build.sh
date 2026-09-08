#!/bin/bash
# Builds BudsControl.app into ./build. No Xcode project required.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/BudsControl.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  Sources/Protocol.swift Sources/BudsLink.swift Sources/SliderRow.swift Sources/StatusBar.swift Sources/main.swift \
  -framework AppKit -framework IOBluetooth -framework Carbon \
  -o "$APP/Contents/MacOS/BudsControl"

cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature. macOS ties the Bluetooth permission grant to this identity,
# so re-signing with the same (empty) identity keeps the existing grant.
codesign --force --sign - "$APP"

echo "built $APP"
