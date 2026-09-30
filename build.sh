#!/bin/bash
set -e

APP_NAME="SilkyScroll"
BUNDLE_ID="io.github.wonsss.silkyscroll"
APP_VERSION="${APP_VERSION:-1.0.0}"
BINARY_PATH=".build/release/$APP_NAME"
APP_BUNDLE=".build/release/$APP_NAME.app"

echo "🔨 SilkyScroll 빌드 중..."
swift build -c release 2>&1

echo "✅ 빌드 성공!"

# .app 번들 조립
echo "📦 .app 번들 생성 중..."
CONTENTS="$APP_BUNDLE/Contents"
rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY_PATH" "$CONTENTS/MacOS/$APP_NAME"

# Info.plist
cat > "$CONTENTS/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>SilkyScroll</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleVersion</key><string>$APP_VERSION</string>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# 아이콘 처리
if [ -f "AppIcon.icns" ]; then
    echo "🎨 AppIcon.icns 적용 중..."
    cp "AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
elif [ -f "make_icns.sh" ]; then
    echo "🎨 아이콘 자동 생성 중..."
    bash make_icns.sh
    [ -f "AppIcon.icns" ] && cp "AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

echo "✅ $APP_BUNDLE 생성 완료!"
echo ""

# --no-install 플래그: CI/노타라이즈 스크립트에서 대화형 설치 건너뜀
if [[ "${1}" == "--no-install" ]]; then
    echo "📍 번들 위치: $APP_BUNDLE"
    echo "🖱️  SilkyScroll 빌드 완료!"
    exit 0
fi

# 설치 선택
echo "설치 방법을 선택하세요:"
echo "  [1] /Applications 에 설치 (추천)"
echo "  [2] 설치 안 함"
read -p "선택 (1/2, 기본값 2): " -n 1 -r CHOICE
echo

if [[ "$CHOICE" == "1" ]]; then
    sudo cp -R "$APP_BUNDLE" /Applications/
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f /Applications/SilkyScroll.app 2>/dev/null || true
    echo "✅ /Applications/SilkyScroll.app 설치 완료"
    echo "   실행: open /Applications/SilkyScroll.app"
else
    echo "📍 실행: open $APP_BUNDLE"
fi

echo ""
echo "🖱️  SilkyScroll 준비 완료!"
