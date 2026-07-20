#!/usr/bin/env bash
# Bundles the SwiftPM-built HwhisperMac executable into dist/Hwhisper.app.
#
# The build host only has the Command Line Tools (no full Xcode / xcodebuild),
# so `swift build -c release` produces a bare Mach-O executable rather than an
# .app bundle. This script hand-assembles the minimal bundle structure macOS
# needs to run it as a menu-bar-only (LSUIElement) app: Info.plist,
# PkgInfo, the executable, and any SwiftPM resource bundles (KeyboardShortcuts
# ships a resource bundle for the Recorder UI's localization).
#
# Usage: bash scripts/make-app.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Hwhisper"
BUNDLE_ID="com.hminn.hwhisper"
BUNDLE_VERSION="0.2.4"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Building $APP_NAME (release)"
swift build -c release --product HwhisperMac

BIN_PATH="$(swift build -c release --show-bin-path)"
EXECUTABLE_SRC="$BIN_PATH/HwhisperMac"

if [[ ! -f "$EXECUTABLE_SRC" ]]; then
    echo "error: built executable not found at $EXECUTABLE_SRC" >&2
    exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$EXECUTABLE_SRC" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$BUNDLE_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUNDLE_VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>hwhisper는 음성을 텍스트로 받아쓰기 위해 마이크 입력이 필요합니다. 녹음된 오디오는 기기 밖으로 전송되지 않습니다.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

# Brand app icon (see scripts/render-app-icon.swift — regenerate with
# `swift scripts/render-app-icon.swift assets` after design changes).
ICON_SRC="$ROOT_DIR/assets/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$RESOURCES_DIR/AppIcon.icns"
else
    echo "warning: $ICON_SRC not found — app will show the generic icon" >&2
fi

printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

# KeyboardShortcuts ships a resource bundle (Recorder UI localization). Copy
# it into Contents/Resources if the release build produced one, so the
# Settings window's shortcut recorder is properly localized at runtime.
KS_BUNDLE="$BIN_PATH/KeyboardShortcuts_KeyboardShortcuts.bundle"
if [[ -d "$KS_BUNDLE" ]]; then
    echo "==> Copying KeyboardShortcuts resource bundle"
    cp -R "$KS_BUNDLE" "$RESOURCES_DIR/"
else
    echo "warning: KeyboardShortcuts resource bundle not found at $KS_BUNDLE (Recorder UI may fall back to unlocalized text)" >&2
fi

# The KeyboardShortcuts SwiftPM resource bundle ships some files read-only
# (0444). They survive into the .dmg, and on the user's machine
# `xattr -dr com.apple.quarantine` then fails with EACCES on exactly those
# files (removing an extended attribute needs write permission). Give the
# owner write access so the documented one-line first-launch command works
# without sudo. Done BEFORE codesign so the signature covers final state.
chmod -R u+w "$APP_DIR"

echo "==> Code signing"
# Prefer a stable "hwhisper-dev" self-signed identity (see
# scripts/make-signing-cert.sh) over ad-hoc signing. Ad-hoc signatures are
# derived from the binary's own hash, so every rebuild looks like a brand
# new program to macOS's TCC subsystem — this is what resets granted
# Microphone/Accessibility permissions on every rebuild. A stable identity
# keeps the signature (and therefore the TCC grant) constant across builds.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "hwhisper-dev"; then
    echo "==> Signing with stable identity: hwhisper-dev"
    codesign --force --deep --sign "hwhisper-dev" "$APP_DIR"
else
    echo "==> No 'hwhisper-dev' codesigning identity found — falling back to ad-hoc signing."
    echo "    Ad-hoc signing resets macOS's Microphone/Accessibility permission grants on"
    echo "    every rebuild. Run 'bash scripts/make-signing-cert.sh' once (see README.md)"
    echo "    to create a stable identity and avoid this."
    codesign --force --deep --sign - "$APP_DIR"
fi

echo "==> Done: $APP_DIR"
echo ""
echo "Run it with:      open \"$APP_DIR\""
echo "Or install it:    cp -R \"$APP_DIR\" /Applications/"
