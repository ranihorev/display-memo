#!/bin/bash
set -e

# Ensure Xcode is selected
if [[ $(xcode-select -p) == "/Library/Developer/CommandLineTools" ]]; then
  echo "Switching to full Xcode..."
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
fi

echo "Building DisplayMemo..."

# If CODESIGN_IDENTITY is set, build with signing; otherwise build unsigned (local dev)
if [ -n "$CODESIGN_IDENTITY" ]; then
  echo "Building with code signing identity: $CODESIGN_IDENTITY"
  xcodebuild -scheme DisplayMemo \
    -configuration Release \
    -derivedDataPath .build \
    -arch arm64 -arch x86_64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="$CODESIGN_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="${APPLE_TEAM_ID:-}" \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS=--timestamp \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build
else
  echo "Building without code signing (local dev)"
  xcodebuild -scheme DisplayMemo \
    -configuration Release \
    -derivedDataPath .build \
    -arch arm64 -arch x86_64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build
fi

mkdir -p dist
rm -rf dist/DisplayMemo.app
cp -R .build/Build/Products/Release/DisplayMemo.app dist/

echo ""
echo "Build complete: dist/DisplayMemo.app"
