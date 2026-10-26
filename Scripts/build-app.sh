#!/bin/bash
# Builds Quicker.app into ./build (release). Usage: Scripts/build-app.sh
# Set CODESIGN_IDENTITY to a certificate name to sign with it; default is ad-hoc ("-").
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Quicker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/Quicker" "$APP/Contents/MacOS/Quicker"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="${CODESIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
    # An ad-hoc signature pins the designated requirement to this exact build (its cdhash), so macOS
    # forgets the Accessibility permission after every rebuild. Pin it to the bundle identifier instead.
    codesign --force --sign - --identifier com.pavlohuk.Quicker \
        -r='designated => identifier "com.pavlohuk.Quicker"' "$APP"
else
    codesign --force --sign "$IDENTITY" --identifier com.pavlohuk.Quicker "$APP"
fi
echo "Built $APP"
