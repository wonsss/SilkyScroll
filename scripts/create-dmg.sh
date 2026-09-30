#!/bin/zsh
# SilkyScroll DMG 생성 — notarized .app → 설치 UX가 있는 .dmg
# 의존: brew install create-dmg
# 사용: ./scripts/create-dmg.sh [--skip-notarize]
set -e
cd "$(dirname "$0")/.."

APP_NAME="SilkyScroll"
VERSION="${VERSION:-1.0.0}"
APP=".build/release/${APP_NAME}.app"
DMG="${APP_NAME}-${VERSION}.dmg"

if [[ "${1}" != "--skip-notarize" ]]; then
  echo "→ 빌드 + 노타라이즈…"
  ./scripts/notarize.sh
fi

if ! command -v create-dmg &>/dev/null; then
  echo "✗ create-dmg 없음. 설치: brew install create-dmg"; exit 1
fi

echo "→ DMG 생성…"
rm -f "$DMG"
create-dmg \
  --volname "${APP_NAME}" \
  --window-pos 200 120 \
  --window-size 600 380 \
  --icon-size 100 \
  --icon "${APP_NAME}.app" 160 185 \
  --hide-extension "${APP_NAME}.app" \
  --app-drop-link 430 185 \
  --no-internet-enable \
  "$DMG" \
  "$APP"

DEV_ID_HASH=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)
if [[ -n "$DEV_ID_HASH" ]]; then
  codesign --force --sign "$DEV_ID_HASH" "$DMG"
  echo "→ DMG 서명 완료"

  KEYCHAIN_PROFILE="${APP_NAME}-notarize"
  if xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" &>/dev/null; then
    echo "→ DMG 노타라이즈 제출…"
    xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "✓ DMG 노타라이즈 완료: $DMG"
  else
    echo "⚠ Keychain 프로파일 없음. 먼저: ./scripts/notarize.sh --store-credentials"
  fi
fi

echo "✓ $DMG 생성 완료 ($(du -sh "$DMG" | awk '{print $1}'))"
