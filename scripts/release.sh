#!/bin/zsh
# SilkyScroll 로컬 원커맨드 릴리즈
# 사용: ./scripts/release.sh 1.0.1
#   - CHANGELOG.md 에 "## [1.0.1]" 섹션이 미리 있어야 함 (릴리즈 노트로 사용)
#   - 전제: Developer ID 인증서 + `SilkyScroll-notarize` 키체인 프로파일
#   - 완료 후 git tag v<ver> + GitHub Release(비공개 레포도 OK) 생성
set -e
cd "$(dirname "$0")/.."

APP_NAME="SilkyScroll"
VERSION="${1:?사용법: $0 <version>  (예: $0 1.0.1)}"
TAG="v${VERSION}"
APP=".build/release/${APP_NAME}.app"
DMG="${APP_NAME}-${VERSION}.dmg"
KEYCHAIN_PROFILE="${APP_NAME}-notarize"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "✗ 버전 형식은 x.y.z"; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "✗ 커밋되지 않은 변경사항 있음"; exit 1; }
git rev-parse "$TAG" &>/dev/null && { echo "✗ 태그 $TAG 이미 존재"; exit 1; }
gh release view "$TAG" &>/dev/null && { echo "✗ Release $TAG 이미 존재"; exit 1; }

NOTES=$(awk "/## \[${VERSION}\]/{found=1; next} found && /^## /{exit} found{print}" CHANGELOG.md)
[[ -z "$NOTES" ]] && { echo "✗ CHANGELOG.md 에 '## [${VERSION}]' 섹션을 먼저 작성하세요"; exit 1; }

DEV_ID_HASH=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)
[[ -z "$DEV_ID_HASH" ]] && { echo "✗ Developer ID Application 인증서 없음"; exit 1; }

echo "→ [$TAG] 빌드"
APP_VERSION="$VERSION" ./build.sh --no-install

echo "→ 서명 (Developer ID + hardened runtime)"
codesign --force --options runtime --sign "$DEV_ID_HASH" "$APP"

echo "→ .app 노타라이즈"
rm -f "${APP_NAME}.zip"
ditto -c -k --keepParent "$APP" "${APP_NAME}.zip"
xcrun notarytool submit "${APP_NAME}.zip" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "${APP_NAME}.zip"

echo "→ DMG 생성 (hdiutil)"
rm -rf /tmp/${APP_NAME}-dmg "$DMG"
mkdir -p "/tmp/${APP_NAME}-dmg"
cp -R "$APP" "/tmp/${APP_NAME}-dmg/"
ln -s /Applications "/tmp/${APP_NAME}-dmg/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "/tmp/${APP_NAME}-dmg" \
  -ov -format UDZO "$DMG"
rm -rf "/tmp/${APP_NAME}-dmg"

echo "→ DMG 서명 + 노타라이즈"
codesign --force --sign "$DEV_ID_HASH" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "→ 검증"
spctl -a -vvv "$APP" | grep -q "Notarized Developer ID" || { echo "✗ .app 게이트키퍼 검증 실패"; exit 1; }
spctl -a -vvv -t open --context context:primary-signature "$DMG" \
  | grep -q "Notarized Developer ID" || { echo "✗ DMG 게이트키퍼 검증 실패"; exit 1; }

echo "→ GitHub Release $TAG 생성"
gh release create "$TAG" "$DMG" \
  --title "${APP_NAME} ${TAG}" --notes "$NOTES"

echo ""
echo "✓ $TAG 릴리즈 완료: $(gh release view "$TAG" --json url -q .url)"
echo "  참고: 태그 푸시로 CI release.yml 이 트리거되지만, 이미 Release가 있으면 자동 스킵됩니다."
