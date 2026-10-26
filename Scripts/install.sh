#!/bin/bash
# Builds, copies to /Applications, and (re)launches the app.
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/build-app.sh

pkill -x Quicker 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/Quicker.app"
cp -R "build/Quicker.app" "/Applications/Quicker.app"
open "/Applications/Quicker.app"
echo "Installed and launched /Applications/Quicker.app"
