#!/bin/bash
# AppIcon.icns 생성 스크립트
# 사용법: ./make_icns.sh [source_image.png]
#   - source_image.png 생략 시 SF Symbol 기반 기본 아이콘 자동 생성

set -e

SOURCE_PNG="${1:-}"
OUTPUT_ICNS="AppIcon.icns"
ICONSET_DIR="AppIcon.iconset"

# ── 소스 이미지가 없으면 Swift로 SF Symbol 아이콘 자동 생성 ──────────────
if [ -z "$SOURCE_PNG" ] || [ ! -f "$SOURCE_PNG" ]; then
    echo "🎨 SF Symbol 기반 기본 아이콘 생성 중..."

    swift - <<'SWIFT'
import AppKit

let canvasSize = CGSize(width: 1024, height: 1024)
let image = NSImage(size: canvasSize, flipped: false) { rect in

    // ── 1. macOS 앱 아이콘 둥근 사각형 클리핑 ──────────────────────────
    let roundRect = NSBezierPath(
        roundedRect: rect,
        xRadius: 224, yRadius: 224   // macOS 표준 비율
    )
    roundRect.addClip()

    // ── 2. 배경: 딥 블랙 그라디언트 ──────────────────────────────────
    let bg = NSGradient(
        colors: [
            NSColor(red: 0.14, green: 0.14, blue: 0.14, alpha: 1.0),  // 약간 밝은 검정
            NSColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1.0)   // 거의 순수 검정
        ],
        atLocations: [0.0, 1.0],
        colorSpace: .deviceRGB
    )!
    bg.draw(in: rect, angle: 135)

    // ── 3. 상단 미묘한 하이라이트 (유리 느낌) ─────────────────────────
    let highlightRect = NSRect(x: 0, y: canvasSize.height * 0.5,
                               width: canvasSize.width, height: canvasSize.height * 0.5)
    NSColor.white.withAlphaComponent(0.06).setFill()
    highlightRect.fill()

    // ── 4. 마우스 SF Symbol (중앙, 흰색) ──────────────────────────────
    let symbolNames = ["computermouse.fill", "computermouse", "cursorarrow"]
    for name in symbolNames {
        let config = NSImage.SymbolConfiguration(pointSize: 500, weight: .light)
        guard let raw = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { continue }

        // 흰색으로 tint
        let symSize = raw.size
        let tinted = NSImage(size: symSize, flipped: false) { r in
            NSColor.white.setFill()
            NSBezierPath(rect: r).fill()
            raw.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1.0)
            return true
        }

        let origin = NSPoint(
            x: (canvasSize.width  - symSize.width)  / 2,
            y: (canvasSize.height - symSize.height) / 2
        )
        tinted.draw(in: NSRect(origin: origin, size: symSize),
                    from: .zero, operation: .sourceOver, fraction: 0.92)
        break
    }

    return true
}

// PNG로 저장
if let tiffData = image.tiffRepresentation,
   let bitmapRep = NSBitmapImageRep(data: tiffData),
   let pngData = bitmapRep.representation(using: .png, properties: [:]) {
    let url = URL(fileURLWithPath: "AppIconSource.png")
    try! pngData.write(to: url)
    print("✅ AppIconSource.png 생성 완료 (1024×1024)")
} else {
    print("❌ 이미지 생성 실패")
    exit(1)
}
SWIFT

    SOURCE_PNG="AppIconSource.png"
fi

echo "📐 iconset 생성 중: $SOURCE_PNG → $OUTPUT_ICNS"

# ── iconset 폴더 생성 ─────────────────────────────────────────────────────
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# 필요한 모든 해상도 생성
declare -a SIZES=(16 32 64 128 256 512 1024)
for SIZE in "${SIZES[@]}"; do
    # 1x
    sips -z $SIZE $SIZE "$SOURCE_PNG" \
        --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}.png" > /dev/null 2>&1

    # 2x (다음 단계 크기의 @2x)
    HALF=$((SIZE / 2))
    if [ $HALF -ge 8 ]; then
        sips -z $SIZE $SIZE "$SOURCE_PNG" \
            --out "$ICONSET_DIR/icon_${HALF}x${HALF}@2x.png" > /dev/null 2>&1
    fi
done

# iconutil 표준 파일명으로 재정리
rm -rf "${ICONSET_DIR}_clean"
mkdir -p "${ICONSET_DIR}_clean"
cp "$ICONSET_DIR/icon_16x16.png"    "${ICONSET_DIR}_clean/icon_16x16.png"
cp "$ICONSET_DIR/icon_32x32.png"    "${ICONSET_DIR}_clean/icon_16x16@2x.png"
cp "$ICONSET_DIR/icon_32x32.png"    "${ICONSET_DIR}_clean/icon_32x32.png"
cp "$ICONSET_DIR/icon_64x64.png"    "${ICONSET_DIR}_clean/icon_32x32@2x.png"
cp "$ICONSET_DIR/icon_128x128.png"  "${ICONSET_DIR}_clean/icon_128x128.png"
cp "$ICONSET_DIR/icon_256x256.png"  "${ICONSET_DIR}_clean/icon_128x128@2x.png"
cp "$ICONSET_DIR/icon_256x256.png"  "${ICONSET_DIR}_clean/icon_256x256.png"
cp "$ICONSET_DIR/icon_512x512.png"  "${ICONSET_DIR}_clean/icon_256x256@2x.png"
cp "$ICONSET_DIR/icon_512x512.png"  "${ICONSET_DIR}_clean/icon_512x512.png"
cp "$ICONSET_DIR/icon_1024x1024.png" "${ICONSET_DIR}_clean/icon_512x512@2x.png"

# ── iconutil로 .icns 변환 ─────────────────────────────────────────────────
rm -rf "$ICONSET_DIR"
mv "${ICONSET_DIR}_clean" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"

# 정리
rm -rf "$ICONSET_DIR"

echo "✅ $OUTPUT_ICNS 생성 완료!"
echo "   이 파일을 build.sh에서 .app 번들에 자동으로 복사합니다."
