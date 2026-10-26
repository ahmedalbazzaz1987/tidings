#!/bin/bash
# Builds Tidings.app using only the Xcode Command Line Tools (no Xcode project needed).
#
#   ./build.sh              build for this Mac        → build/Tidings.app
#   ./build.sh --universal  Apple Silicon + Intel
#   ./build.sh --release    universal + zip for GitHub → build/Tidings-<version>.zip
#   ./build.sh --install    build and copy to /Applications
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(tr -d '[:space:]' < VERSION)"
BUNDLE_ID="com.ahmedalbazzaz.tidings"
MIN_MACOS="13.0"
APP="build/Tidings.app"
UNIVERSAL=0; RELEASE=0; INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --release) RELEASE=1; UNIVERSAL=1 ;;
    --install) INSTALL=1 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Install the Command Line Tools with:  xcode-select --install"
  exit 1
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"

# Recent SDKs implement @State and friends as macros. A bare swiftc needs the
# macro plugin paths that Xcode normally passes (same fix as Purge).
SWIFTC_BIN="$(xcrun -f swiftc)"
TOOLCHAIN="$(dirname "$(dirname "$(dirname "$SWIFTC_BIN")")")"
PLUGIN_SERVER="$TOOLCHAIN/usr/bin/swift-plugin-server"
PLUGIN_FLAGS=()
for d in "$TOOLCHAIN/usr/lib/swift/host/plugins" "$TOOLCHAIN/usr/local/lib/swift/host/plugins"; do
  [ -d "$d" ] && PLUGIN_FLAGS+=(-plugin-path "$d")
done
if [ -x "$PLUGIN_SERVER" ]; then
  for d in "$SDK/usr/lib/swift/host/plugins" "$SDK/usr/local/lib/swift/host/plugins"; do
    [ -d "$d" ] && PLUGIN_FLAGS+=(-external-plugin-path "$d#$PLUGIN_SERVER")
  done
fi
if ! ls "$TOOLCHAIN"/usr/lib/swift/host/plugins/*SwiftUIMacros* >/dev/null 2>&1 \
   && ! ls "$SDK"/usr/lib/swift/host/plugins/*SwiftUIMacros* >/dev/null 2>&1; then
  FOUND="$(find "$TOOLCHAIN" "$SDK" -maxdepth 8 -name '*SwiftUIMacros*' 2>/dev/null | head -1 || true)"
  if [ -n "$FOUND" ]; then
    DIR="$(dirname "$FOUND")"
    if [ -x "$PLUGIN_SERVER" ]; then PLUGIN_FLAGS+=(-external-plugin-path "$DIR#$PLUGIN_SERVER"); else PLUGIN_FLAGS+=(-plugin-path "$DIR"); fi
  fi
fi
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find Sources -name '*.swift' | sort)

echo "▸ Building Tidings $VERSION"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

compile() {
  local arch="$1"
  xcrun swiftc \
    -target "${arch}-apple-macos${MIN_MACOS}" \
    -sdk "$SDK" \
    -swift-version 5 \
    -O -whole-module-optimization \
    -parse-as-library \
    ${PLUGIN_FLAGS[@]+"${PLUGIN_FLAGS[@]}"} \
    -module-name Tidings \
    -lsqlite3 \
    -o "build/obj/Tidings-${arch}" \
    "${SOURCES[@]}"
}

if [ "$UNIVERSAL" = 1 ]; then
  compile arm64
  compile x86_64
  lipo -create build/obj/Tidings-arm64 build/obj/Tidings-x86_64 -output "$APP/Contents/MacOS/Tidings"
else
  ARCH="$(uname -m)"
  compile "$ARCH"
  cp "build/obj/Tidings-${ARCH}" "$APP/Contents/MacOS/Tidings"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tidings</string>
  <key>CFBundleDisplayName</key><string>Tidings</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>Tidings</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Ahmed Albazzaz</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Email Address</string>
      <key>CFBundleURLSchemes</key><array><string>mailto</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

if [ -d Resources/AppIcon.iconset ]; then
  iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Sign: use the optional local certificate (see setup-signing.sh) so Keychain
# access survives updates; otherwise fall back to an ad-hoc signature.
IDENTITY="Tidings Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep --timestamp=none --sign "$IDENTITY" "$APP"
  echo "▸ Signed with \"$IDENTITY\""
else
  codesign --force --deep --sign - "$APP"
  echo "▸ Signed ad-hoc (run ./setup-signing.sh once to avoid Keychain prompts after updates)"
fi

SIZE="$(du -sh "$APP" | cut -f1)"
echo "✓ Built $APP ($SIZE)"

if [ "$RELEASE" = 1 ]; then
  ZIP="build/Tidings-${VERSION}.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
  echo "✓ Release archive: $ZIP"
fi

if [ "$INSTALL" = 1 ]; then
  osascript -e 'tell application "Tidings" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf /Applications/Tidings.app
  cp -R "$APP" /Applications/
  echo "✓ Installed to /Applications/Tidings.app"
  open /Applications/Tidings.app
fi
