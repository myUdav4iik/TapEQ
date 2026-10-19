#!/usr/bin/env bash
# Builds TapEQ and packages it as build/TapEQ.app (ad-hoc signed).
# A real .app bundle is needed so macOS attributes the audio-capture
# permission to TapEQ itself instead of the terminal that launched it.
set -euo pipefail

cd "$(dirname "$0")"

swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"

app="build/TapEQ.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/TapEQ" "$app/Contents/MacOS/TapEQ"
cp Resources/Info.plist "$app/Contents/Info.plist"

# Prefer a real signing identity: macOS keys the audio-capture permission to the
# signature, and an ad-hoc signature changes on every build (re-prompting each time).
identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')"
fi
if [[ -n "$identity" ]]; then
    codesign --force --sign "$identity" "$app"
    echo "Signed with: $identity"
else
    codesign --force --sign - "$app"
    echo "Signed ad-hoc (set SIGN_IDENTITY to keep permissions across rebuilds)"
fi

echo "Built $app"
