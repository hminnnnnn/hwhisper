#!/usr/bin/env bash
# Packages dist/Hwhisper.app into a distributable disk image at
# dist/hwhisper-<version>.dmg using hdiutil (ships with macOS — no
# create-dmg / Homebrew dependency, so this runs on a CLT-only host).
#
# The image is NOT notarized (that needs a paid Apple Developer ID — see
# README "Install"). So the DMG includes a plain-text first-launch note
# telling the user how to clear the Gatekeeper quarantine once.
#
# Usage: bash scripts/make-dmg.sh   (run scripts/make-app.sh first)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Hwhisper"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/$APP_NAME.app"

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: $APP_PATH not found — run 'bash scripts/make-app.sh' first." >&2
    exit 1
fi

# Version comes from the built app's Info.plist so the DMG name always
# matches the binary it contains.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "dev")"
DMG_PATH="$DIST_DIR/hwhisper-$VERSION.dmg"

echo "==> Staging DMG contents for hwhisper $VERSION"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP_PATH" "$STAGING/"
# /Applications symlink so the user can drag-install from the mounted image.
ln -s /Applications "$STAGING/Applications"

# First-launch instructions travel inside the image (KO + EN).
cat > "$STAGING/먼저 읽어주세요 - READ ME FIRST.txt" <<'NOTE'
hwhisper — 첫 실행 안내 / First launch

[한국어]
1) Hwhisper.app 을 Applications 폴더로 드래그하세요.
2) 이 앱은 유료 Apple 인증서로 공증되지 않은 오픈소스 빌드라, 처음엔
   macOS가 실행을 막습니다. 아래 명령을 터미널에서 한 번 실행하면 됩니다:

       xattr -dr com.apple.quarantine /Applications/Hwhisper.app

   또는: 앱 실행 시도 → 시스템 설정 > 개인정보 보호 및 보안 하단의
   "확인 없이 열기" 클릭.
3) 처음 실행하면 온보딩 안내가 뜹니다. 마이크·손쉬운 사용 권한을 허용하세요.

자세한 내용은 저장소의 README.md 를 참고하세요.

[English]
1) Drag Hwhisper.app into the Applications folder.
2) This is an open-source build not notarized with a paid Apple cert, so
   macOS blocks it the first time. Run this once in Terminal:

       xattr -dr com.apple.quarantine /Applications/Hwhisper.app

   Or: try to open it → System Settings > Privacy & Security → "Open Anyway".
3) A setup wizard appears on first launch — grant Microphone and
   Accessibility permissions.

More: see README.en.md in the repository.
NOTE

echo "==> Building $DMG_PATH"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "hwhisper $VERSION" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

echo "==> Done: $DMG_PATH"
echo "    $(du -h "$DMG_PATH" | cut -f1) · not notarized (see README 'Install' for the one-time first-launch step)"
