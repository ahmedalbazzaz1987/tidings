#!/bin/bash
# Completely removes Tidings from this Mac (same as Settings → Updates → Uninstall).
# Your email stays on your mail servers.
BUNDLE_ID="com.ahmedalbazzaz.tidings"
echo "This will remove Tidings, its settings, caches, downloaded mail and saved passwords."
read -r -p "Continue? [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || exit 0

osascript -e 'tell application "Tidings" to quit' >/dev/null 2>&1
sleep 1
pkill -x Tidings 2>/dev/null

# Keychain items (passwords, sign-in tokens, cache key)
while security delete-generic-password -s "$BUNDLE_ID" >/dev/null 2>&1; do :; done

defaults delete "$BUNDLE_ID" >/dev/null 2>&1
L="$HOME/Library"
rm -rf "$L/Application Support/Tidings" \
       "$L/Caches/$BUNDLE_ID" \
       "$L/Preferences/$BUNDLE_ID.plist" \
       "$L/Saved Application State/$BUNDLE_ID.savedState" \
       "$L/HTTPStorages/$BUNDLE_ID" "$L/HTTPStorages/$BUNDLE_ID.binarycookies" \
       "$L/WebKit/$BUNDLE_ID" \
       "$L/Containers/$BUNDLE_ID" \
       "$L/Application Scripts/$BUNDLE_ID" \
       "$L/Cookies/$BUNDLE_ID.binarycookies" \
       "$(getconf DARWIN_USER_CACHE_DIR)$BUNDLE_ID" \
       "$(getconf DARWIN_USER_TEMP_DIR)$BUNDLE_ID"

rm -rf "/Applications/Tidings.app" "$HOME/Applications/Tidings.app"

# Optional local signing certificate created by setup-signing.sh
security delete-identity -c "Tidings Local Signing" >/dev/null 2>&1 || \
  security delete-certificate -c "Tidings Local Signing" >/dev/null 2>&1

echo "✓ Tidings has been completely removed."
