#!/bin/zsh
# Builds MorningContext.app from the Swift package and (optionally) installs it.
#   ./build.sh            → build/MorningContext.app
#   ./build.sh --install  → also copies to /Applications and launches it
# Version: $VERSION (e.g. 1.2.0), else the latest git tag (v1.2.0 → 1.2.0), else 0.0.0-dev.
# Build number: $BUILD_NUMBER, else the git commit count.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift toolchain not found. Install Xcode Command Line Tools:  xcode-select --install" >&2
  exit 1
fi

echo "▸ Compiling (release)…"
swift build -c release 2>&1 | grep -v "^\[" || true
BIN=".build/release/MorningContext"
[[ -x "$BIN" ]] || { echo "Build failed — see errors above." >&2; exit 1; }

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0-dev}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

APP="build/MorningContext.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MorningContext"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Morning Context</string>
  <key>CFBundleDisplayName</key>       <string>Morning Context</string>
  <key>CFBundleIdentifier</key>        <string>io.github.blackrose-blackhat.morningcontext</string>
  <key>CFBundleExecutable</key>        <string>MorningContext</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key>           <string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>LSUIElement</key>               <true/>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key>    <string>io.github.blackrose-blackhat.morningcontext</string>
    <key>CFBundleURLSchemes</key> <array><string>morningcontext</string></array>
  </dict></array>
  <key>NSMicrophoneUsageDescription</key>          <string>Morning Context listens when you talk to it, so you can ask about your day.</string>
  <key>NSSpeechRecognitionUsageDescription</key>   <string>Morning Context turns what you say into text, on this Mac, to answer your questions.</string>
  <key>NSHumanReadableCopyright</key>  <string>Copyright © 2026 Morning Context contributors. MIT License.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS runs it and SMAppService (launch at login) works.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "▸ Built $APP (version $VERSION, build $BUILD_NUMBER)"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x MorningContext 2>/dev/null || true
  for _ in {1..50}; do pgrep -x MorningContext >/dev/null || break; sleep 0.1; done   # let it quit before relaunching
  rm -rf "/Applications/MorningContext.app"
  cp -R "$APP" /Applications/
  echo "▸ Installed to /Applications/MorningContext.app — launching"
  open "/Applications/MorningContext.app"
  echo "▸ Look for the sunrise icon in your menu bar. Turn on “Launch at login” in Settings…"
fi
