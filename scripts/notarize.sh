#!/bin/zsh
# SilkyScroll 노타라이즈 — Developer ID Application 인증서 + Apple Developer 계정 필요
# 최초 1회: ./scripts/notarize.sh --store-credentials   (이후) ./scripts/notarize.sh
set -e
cd "$(dirname "$0")/.."

APP_NAME="SilkyScroll"
APP="${APP_NAME}.app"
KEYCHAIN_PROFILE="${APP_NAME}-notarize"
TEAM_ID="${TEAM_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep 'Developer ID Application' | head -1 | grep -oE '\([A-Z0-9]{10}\)' | tr -d '()')}"

store_credentials() {
  [[ -z "$TEAM_ID" ]] && { echo "✗ Team ID 감지 실패 — TEAM_ID=XXXX 로 지정"; exit 1; }
  echo "로컬 Keychain 에 자격증명 저장. Apple ID + 앱암호(appleid.apple.com > 보안) 입력."
  xcrun notarytool store-credentials "$KEYCHAIN_PROFILE" --team-id "$TEAM_ID"
}

notarize() {
  DEV_ID_HASH=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)
  [[ -z "$DEV_ID_HASH" ]] && { echo "✗ Developer ID Application 인증서 없음"; exit 1; }

  echo "→ 빌드 중…"
  ./build.sh --no-install

  echo "→ 서명 중…"
  codesign --force --options runtime --sign "$DEV_ID_HASH" ".build/release/$APP"

  rm -f "${APP_NAME}.zip" "${APP_NAME}-notarized.zip"
  ditto -c -k --keepParent ".build/release/$APP" "${APP_NAME}.zip"
  echo "→ 노타라이즈 제출 (1~5분)…"
  xcrun notarytool submit "${APP_NAME}.zip" --keychain-profile "$KEYCHAIN_PROFILE" --wait
  xcrun stapler staple ".build/release/$APP"
  rm -f "${APP_NAME}.zip"
  ditto -c -k --keepParent ".build/release/$APP" "${APP_NAME}-notarized.zip"
  echo "✓ ${APP_NAME}-notarized.zip — GitHub Release 에 첨부"
  spctl -a -vvv ".build/release/$APP" 2>&1 | head -3
}

case "${1}" in
  --store-credentials) store_credentials ;;
  "") notarize ;;
  *) echo "Usage: $0 [--store-credentials]"; exit 1 ;;
esac
