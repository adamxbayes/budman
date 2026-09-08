#!/bin/bash
# Builds BudsControl.app (menu bar app + Control Center extension) into ./build.
#
# The Xcode project is generated from project.yml with xcodegen when it is
# installed (brew install xcodegen); otherwise the committed project is used.
set -euo pipefail
cd "$(dirname "$0")"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --quiet
fi

xcodebuild -project BudsControl.xcodeproj \
  -scheme BudsControl \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  -quiet \
  build

rm -rf build/BudsControl.app
cp -R build/DerivedData/Build/Products/Release/BudsControl.app build/BudsControl.app
echo "built build/BudsControl.app"
