#!/bin/bash
set -e

# Ensure Xcode is selected
if [[ $(xcode-select -p) == "/Library/Developer/CommandLineTools" ]]; then
  echo "Switching to full Xcode..."
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
fi

echo "Building DisplayMemo..."

xcodebuild -scheme DisplayMemo \
  -configuration Release \
  -derivedDataPath .build \
  -arch arm64 -arch x86_64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

mkdir -p dist
rm -rf dist/DisplayMemo.app
cp -R .build/Build/Products/Release/DisplayMemo.app dist/

echo ""
echo "Build complete: dist/DisplayMemo.app"
