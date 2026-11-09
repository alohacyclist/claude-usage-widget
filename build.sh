#!/bin/zsh
# Builds a universal "Claude Usage.app" into build/.
#   --install  copy it to ~/Applications and (re)start it
#   --zip      also write build/ClaudeUsage.zip for a release
set -euo pipefail
cd "${0:A:h}"

APP="build/Claude Usage.app"
BIN="$APP/Contents/MacOS/ClaudeUsage"
rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library \
    -target "$arch-apple-macos15.0" \
    Sources/*.swift -o "build/obj/ClaudeUsage-$arch"
done
lipo -create build/obj/ClaudeUsage-arm64 build/obj/ClaudeUsage-x86_64 -output "$BIN"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/ "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$BIN"))"

for arg in "$@"; do
  case "$arg" in
    --zip)
      rm -f build/ClaudeUsage.zip
      ditto -c -k --keepParent "$APP" build/ClaudeUsage.zip
      echo "Wrote build/ClaudeUsage.zip"
      ;;
    --install)
      pkill -x ClaudeUsage || true
      mkdir -p "$HOME/Applications"
      rm -rf "$HOME/Applications/Claude Usage.app"
      cp -R "$APP" "$HOME/Applications/"
      open "$HOME/Applications/Claude Usage.app"
      echo "Installed and started ~/Applications/Claude Usage.app"
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done
