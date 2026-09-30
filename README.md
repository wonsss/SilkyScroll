# SilkyScroll for macOS

[![build](https://github.com/wonsss/SilkyScroll/actions/workflows/build.yml/badge.svg)](https://github.com/wonsss/SilkyScroll/actions/workflows/build.yml)

macOS에서 일반 마우스의 끊기는 스크롤을 부드러운 연속 스크롤로 변환하는 네이티브 Swift 메뉴바 앱입니다.

## 작동 원리

macOS는 Magic Mouse/트랙패드에는 부드러운 `continuous` 스크롤을 제공하지만, 일반 마우스에는 `discrete` (줄 단위) 스크롤만 제공합니다. SilkyScroll은:

1. **`CGEventTap`** 으로 시스템 레벨에서 스크롤 이벤트를 가로챔
2. 끊기는 discrete 스크롤을 차단하고
3. **exponential decay** 보간으로 부드러운 continuous pixel 스크롤로 변환
4. **CVDisplayLink** (화면 주사율 동기화)로 프레임마다 부드럽게 전달

트랙패드/Magic Mouse의 스크롤은 자동으로 감지하여 그대로 통과시킵니다.

## 다운로드 & 설치

**[Releases 페이지](https://github.com/wonsss/SilkyScroll/releases)** 에서 최신 `SilkyScroll-x.y.z.dmg`를 다운로드하세요.

DMG를 열고 `SilkyScroll.app`을 `/Applications` 폴더로 드래그하세요. 릴리즈는 Apple Developer ID 서명 + 노타라이즈되어 있어 Gatekeeper 경고 없이 바로 실행됩니다.

## 빌드 (소스에서)

### 요구사항

- macOS 12+ (Monterey 이상)
- Xcode Command Line Tools (`xcode-select --install`)

### 빌드

```bash
chmod +x build.sh
./build.sh
```

빌드 후 `/Applications` 설치 여부를 선택할 수 있습니다.

#### 커스텀 아이콘

직접 만든 1024×1024 PNG를 아이콘으로 사용하려면:

```bash
chmod +x make_icns.sh
bash make_icns.sh MyIcon.png   # AppIcon.icns 생성
./build.sh                     # 빌드 시 자동으로 적용됨
```

## 사용법

실행하면 메뉴바에 🖱️ 아이콘이 나타납니다:

| 메뉴 항목 | 설명 |
|-----------|------|
| **Enabled** | 스무스 스크롤 켜기/끄기 |
| **Speed** | 스크롤 속도 배율 (1x ~ 10x) |
| **Smoothness** | 감속 부드러움 (Low ~ Ultra) |
| **Launch at Login** | 로그인 시 자동 실행 (macOS 13+) |
| **Hide Menu Bar Icon** | 메뉴바 아이콘 숨기기 |
| **Quit** | 앱 종료 |

### 추천 설정

| 사용 환경 | Speed | Smoothness |
|-----------|-------|------------|
| 일반 사용 | 3.0x | High |
| 웹 브라우징 | 4.0x | Very High |
| 코딩/에디터 | 2.0x | Medium |
| 긴 문서 읽기 | 5.0x | Ultra |

## 접근성 권한 설정 (필수)

처음 실행 시 **접근성 권한** 팝업이 나타납니다:

1. `시스템 설정` → `개인정보 보호 및 보안` → `접근성`
2. SilkyScroll을 허용 목록에 추가
3. 앱이 자동으로 재시작됩니다

> 접근성 권한 없이는 스크롤 이벤트를 가로챌 수 없습니다.

## 아키텍처

```
┌─────────────────────┐
│   일반 마우스 스크롤   │  ← discrete 이벤트 (줄 단위)
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│    CGEventTap       │  ← 시스템 레벨 이벤트 가로채기
│  (discrete 감지)     │     continuous(트랙패드)는 통과
└──────────┬──────────┘
           │ 원본 차단 + velocity 누적
           ▼
┌─────────────────────┐
│   Animation Engine   │  ← exponential decay 보간
│  (CVDisplayLink)     │     매 프레임 velocity *= smoothness
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ CGEvent(continuous)  │  ← pixel 단위 부드러운 스크롤 생성
│   post to system     │
└─────────────────────┘
```

## 트러블슈팅

### "Event Tap 생성 실패"
접근성 권한이 없습니다. 시스템 설정에서 허용해주세요.

### 스크롤이 너무 빠르거나 느림
메뉴바에서 Speed를 조절하세요.

### 관성이 너무 길거나 짧음
Smoothness를 조절하세요. Low(0.70)로 하면 빨리 멈추고, Ultra(0.95)로 하면 오래 미끄러집니다.

### 트랙패드 스크롤도 영향 받음
정상적으로는 트랙패드/Magic Mouse의 continuous 스크롤은 자동 감지하여 무시합니다. 문제가 있다면 [이슈를 남겨주세요](https://github.com/wonsss/SilkyScroll/issues).

## License

MIT License — 자유롭게 사용, 수정, 배포 가능합니다. 자세한 내용은 [LICENSE](LICENSE)를 참고하세요.
