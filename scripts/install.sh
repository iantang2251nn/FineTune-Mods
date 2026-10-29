#!/bin/bash
# Installs (or updates) FineTune-Mods from the latest GitHub release into /Applications and opens it.
# Usage: curl -fsSL https://raw.githubusercontent.com/iantang2251nn/FineTune-Mods/main/scripts/install.sh | bash
#
# The app is ad-hoc signed, not notarized. Files fetched with curl aren't quarantined, so macOS
# opens it without the "Apple could not verify" dialog; the quarantine flag is cleared anyway in
# case something added it.
set -euo pipefail

DMG_URL="https://github.com/iantang2251nn/FineTune-Mods/releases/latest/download/FineTune-Mods.dmg"
APP="/Applications/FineTune.app"

IFS=. read -r major minor _ <<< "$(sw_vers -productVersion)"
if (( major < 15 || (major == 15 && ${minor:-0} < 4) )); then
    echo "FineTune needs macOS 15.4 or later (this Mac has $(sw_vers -productVersion))." >&2
    exit 1
fi
if [ ! -w /Applications ]; then
    echo "This account can't write to /Applications. Sign in as an administrator and try again." >&2
    exit 1
fi

WORK="$(mktemp -d)"
MOUNT="$WORK/mount"
cleanup() {
    hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "Downloading FineTune-Mods..."
curl -fL --progress-bar "$DMG_URL" -o "$WORK/FineTune-Mods.dmg"

echo "Installing to /Applications..."
mkdir "$MOUNT"
hdiutil attach "$WORK/FineTune-Mods.dmg" -nobrowse -readonly -mountpoint "$MOUNT" -quiet
pkill -x FineTune 2>/dev/null || true
rm -rf "$APP"
ditto "$MOUNT/FineTune.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "Done. Opening FineTune - look for its icon in the menu bar."
echo "When macOS asks, allow FineTune to record system audio; that's how it controls each app's volume."
open "$APP"
