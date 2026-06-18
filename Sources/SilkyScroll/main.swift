// SilkyScroll for macOS
// 일반 마우스의 discrete 스크롤을 부드러운 continuous 스크롤로 변환
// Usage: sudo ./SilkyScroll (접근성 권한 필요)

import Foundation
import CoreGraphics
import AppKit
import os.lock
import ServiceManagement

// MARK: - Configuration
struct ScrollConfig {
    var scrollSpeed: Double = 3.0        // 스크롤 배율 (1.0 ~ 10.0)
    var smoothness: Double = 0.85        // 감속 계수 (0.0 ~ 0.99, 높을수록 부드러움)
    var scrollAcceleration: Double = 1.3 // 가속 배율
    var framesPerSecond: Double = 120.0  // 애니메이션 FPS
    var minimumVelocity: Double = 0.5    // 이 속도 이하면 스크롤 중지
    var enabled: Bool = true

    // lock 안에서 읽어야 하는 핫패스 전용 스냅샷
    struct HotPath {
        let enabled: Bool
        let speedMultiplier: Double
        let smoothness: Double
        let minimumVelocity: Double
    }
    var hotPath: HotPath {
        HotPath(
            enabled: enabled,
            speedMultiplier: scrollSpeed * scrollAcceleration,
            smoothness: smoothness,
            minimumVelocity: minimumVelocity
        )
    }

    // MARK: Persistence
    private enum Keys {
        static let scrollSpeed    = "config.scrollSpeed"
        static let smoothness     = "config.smoothness"
        static let enabled        = "config.enabled"
        // scrollAcceleration, framesPerSecond, minimumVelocity는 고급 값이므로 현재는 저장하지 않음
    }

    /// UserDefaults에 저장된 값이 있으면 복원, 없으면 기본값 사용
    static func load() -> ScrollConfig {
        var c = ScrollConfig()
        let ud = UserDefaults.standard
        if ud.object(forKey: Keys.scrollSpeed) != nil {
            c.scrollSpeed = ud.double(forKey: Keys.scrollSpeed)
        }
        if ud.object(forKey: Keys.smoothness) != nil {
            c.smoothness = ud.double(forKey: Keys.smoothness)
        }
        if ud.object(forKey: Keys.enabled) != nil {
            c.enabled = ud.bool(forKey: Keys.enabled)
        }
        return c
    }

    /// 변경된 설정을 UserDefaults에 즉시 저장
    func save() {
        let ud = UserDefaults.standard
        ud.set(scrollSpeed, forKey: Keys.scrollSpeed)
        ud.set(smoothness,  forKey: Keys.smoothness)
        ud.set(enabled,     forKey: Keys.enabled)
    }
}

// MARK: - Smooth Scroll Engine
class SilkyScrollEngine {
    static let shared = SilkyScrollEngine()
    
    var config = ScrollConfig.load()
    
    private var velocityY: Double = 0.0
    private var velocityX: Double = 0.0
    private var displayLink: CVDisplayLink?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isAnimating = false
    // NSLock 대신 os_unfair_lock 사용 — 커널 진입 없는 가장 가벼운 뮤텍스
    private var lock = os_unfair_lock()
    // lock으로 보호되는 핫패스 config 스냅샷 — HID/DisplayLink 스레드에서 읽음
    private var hotPathConfig: ScrollConfig.HotPath = ScrollConfig.load().hotPath

    // 메뉴바 관련
    private var statusItem: NSStatusItem?
    private var enabledMenuItem: NSMenuItem?
    private var launchAtLoginMenuItem: NSMenuItem?
    private var hideMenuBarMenuItem: NSMenuItem?
    
    private init() {}
    
    // MARK: - Setup
    func start() {
        print("🖱️ SilkyScroll 시작 중...")
        
        // /Applications 이동 권장 — 런루프가 안정화된 후 알림 표시
        DispatchQueue.main.async { [weak self] in
            self?.suggestMoveToApplicationsIfNeeded()
        }
        
        // 접근성 권한 확인
        guard checkAccessibilityPermission() else {
            print("❌ 접근성 권한이 필요합니다.")
            print("   시스템 설정 > 개인정보 보호 및 보안 > 접근성 에서 이 앱을 허용해주세요.")
            requestAccessibilityPermission()
            return   // 메뉴바 + 폴링은 requestAccessibilityPermission() 안에서 처리
        }
        
        print("✅ 접근성 권한 확인됨")
        
        // Event Tap 설정
        setupEventTap()
        
        // Display Link 설정 (화면 주사율에 동기화된 애니메이션)
        setupDisplayLink()
        
        // 메뉴바 아이콘 설정 (권한 있을 때 바로 표시)
        setupMenuBar()
        
        print("✅ SilkyScroll이 활성화되었습니다!")
        print("   스크롤 속도: \(config.scrollSpeed)x")
        print("   부드러움: \(config.smoothness)")
        print("")
        print("   메뉴바 아이콘으로 설정을 변경할 수 있습니다.")
        print("   종료하려면 메뉴바에서 'Quit'을 선택하세요.")
    }
    
    // MARK: - Move to Applications
    
    private func suggestMoveToApplicationsIfNeeded() {
        // 번들이 없으면 커맨드라인 실행 → 스킵
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }

        let bundlePath = Bundle.main.bundlePath

        // 이미 /Applications 또는 ~/Applications 안에 있으면 스킵
        let fm = FileManager.default
        let systemApps = "/Applications"
        let userApps = (fm.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent("Applications")

        if bundlePath.hasPrefix(systemApps) || bundlePath.hasPrefix(userApps) {
            return
        }

        // 이미 사용자가 "묻지 않기"를 선택했으면 스킵
        let skipKey = "SilkyScroll.skipMoveToApplications"
        if UserDefaults.standard.bool(forKey: skipKey) { return }

        let alert = NSAlert()
        alert.messageText = "SilkyScroll을 Applications 폴더로 이동할까요?"
        alert.informativeText = """
            현재 앱이 Downloads나 다른 임시 위치에서 실행 중입니다.

            Applications 폴더로 이동하면:
            • 로그인 시 자동 실행이 올바르게 동작합니다.
            • Launchpad에서 바로 찾을 수 있습니다.
            • 접근성 권한이 재요청되지 않습니다.
            """
        alert.addButton(withTitle: "Applications로 이동")
        alert.addButton(withTitle: "나중에")
        alert.addButton(withTitle: "다시 묻지 않기")
        alert.alertStyle = .informational
        if let icon = NSImage(named: NSImage.applicationIconName) {
            alert.icon = icon
        }

        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            moveToApplications(from: bundlePath)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: skipKey)
            print("ℹ️  Applications 이동 제안 비활성화")
        default:
            break
        }
    }

    private func moveToApplications(from sourcePath: String) {
        guard sourcePath.hasSuffix(".app"), !sourcePath.contains("..") else { return }
        let fm = FileManager.default
        let appName = (sourcePath as NSString).lastPathComponent
        let destPath = "/Applications/\(appName)"

        // 대상에 이미 같은 이름의 앱이 있으면 교체 여부 확인
        if fm.fileExists(atPath: destPath) {
            let confirm = NSAlert()
            confirm.messageText = "기존 SilkyScroll을 교체할까요?"
            confirm.informativeText = "\(destPath)\n에 이미 앱이 존재합니다. 교체하면 기존 앱은 삭제됩니다."
            confirm.addButton(withTitle: "교체")
            confirm.addButton(withTitle: "취소")
            confirm.alertStyle = .warning
            guard confirm.runModal() == .alertFirstButtonReturn else { return }

            do {
                try fm.removeItem(atPath: destPath)
            } catch {
                showMoveError(error, dest: destPath)
                return
            }
        }

        do {
            try fm.moveItem(atPath: sourcePath, toPath: destPath)
            print("✅ 앱을 \(destPath) 로 이동했습니다.")

            // 이동 성공 → 새 위치에서 앱 재실행 후 현재 프로세스 종료
            // 0.3초 딜레이: open 프로세스가 fork되기 전에 현재 프로세스가 종료되지 않도록 보장
            let task = Process()
            task.launchPath = "/usr/bin/open"
            task.arguments = [destPath]
            try task.run()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.terminate(nil)
            }
        } catch {
            showMoveError(error, dest: destPath)
        }
    }

    private func showMoveError(_ error: Error, dest: String) {
        print("❌ 이동 실패: \(error.localizedDescription)")
        let errAlert = NSAlert()
        errAlert.messageText = "이동에 실패했습니다"
        errAlert.informativeText = """
            \(dest) 로 이동하지 못했습니다.
            
            앱을 수동으로 Applications 폴더에 복사해주세요.
            오류: \(error.localizedDescription)
            """
        errAlert.alertStyle = .warning
        errAlert.runModal()
    }

    // MARK: - Accessibility
    private func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    
    private func requestAccessibilityPermission() {
        // prompt: true → 시스템이 접근성 설정 창을 자동으로 열어줌
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        print("\n⏳ 접근성 권한 대기 중...")
        print("   시스템 설정 > 개인정보 보호 및 보안 > 접근성 에서 SilkyScroll을 허용해주세요.")

        // 메뉴바 먼저 표시 — 사용자가 앱이 살아있다는 걸 알 수 있도록
        setupMenuBar()

        // 0.5초마다 권한 획득 여부를 폴링 — 허용되면 자동으로 엔진 시작
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let checkOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
            guard AXIsProcessTrustedWithOptions(checkOptions) else { return }

            // 권한 획득 — 엔진 자동 시작
            timer.invalidate()
            print("✅ 접근성 권한 획득됨 — 엔진 시작")
            self.setupEventTap()
            self.setupDisplayLink()
        }
    }
    
    // MARK: - Event Tap
    private func setupEventTap() {
        // 스크롤 이벤트를 가로채는 이벤트 탭 생성
        let eventMask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue)

        // callback은 반드시 @convention(c) 전역 함수여야 함
        // userInfo로 self를 전달하여 인스턴스 메서드에 위임
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: scrollEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("❌ Event Tap 생성 실패. 접근성 권한을 확인해주세요.")
            exit(1)
        }
        
        self.eventTap = tap
        
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        
        print("✅ Event Tap 설정 완료")
    }

    // 실제 콜백 처리 로직 — private으로 캡슐화
    // 전역 C 콜백 scrollEventCallback이 userInfo를 통해 이 메서드에 위임
    fileprivate func handleEventTapCallback(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 이벤트 탭이 비활성화되면 다시 활성화
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .scrollWheel else {
            return Unmanaged.passUnretained(event)
        }

        if let modifiedEvent = handleScrollEvent(event) {
            return Unmanaged.passUnretained(modifiedEvent)
        }

        return nil
    }
    
    // MARK: - Display Link (VSync Animation)
    private func setupDisplayLink() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        
        guard let displayLink = link else {
            print("⚠️ DisplayLink 생성 실패, Timer fallback 사용")
            setupTimerFallback()
            return
        }
        
        self.displayLink = displayLink
        
        CVDisplayLinkSetOutputCallback(displayLink, { (_, _, _, _, _, userInfo) -> CVReturn in
            guard let userInfo = userInfo else { return kCVReturnSuccess }
            let engine = Unmanaged<SilkyScrollEngine>.fromOpaque(userInfo).takeUnretainedValue()
            engine.animationTick()
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
        
        print("✅ DisplayLink 설정 완료")
    }
    
    private func setupTimerFallback() {
        // DisplayLink 실패 시 Timer 기반 폴백
        // Timer는 isAnimating 상태일 때만 tick이 의미 있으므로 animationTick 내부에서 자체 제어
        let interval = 1.0 / config.framesPerSecond
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, self.isAnimating else { return }
            self.animationTick()
        }
    }
    
    // MARK: - Scroll Event Handler
    func handleScrollEvent(_ event: CGEvent) -> CGEvent? {
        // hotPathConfig는 lock 안에서 읽음 — 메인 스레드의 config 쓰기와 레이스 없음
        os_unfair_lock_lock(&lock)
        let cfg = hotPathConfig
        os_unfair_lock_unlock(&lock)

        guard cfg.enabled else { return event }

        // 트랙패드 제스처 감지:
        // scrollWheelEventScrollPhase != 0  → 트랙패드 스와이프 (began/changed/ended/cancelled)
        // scrollWheelEventMomentumPhase != 0 → 트랙패드 모멘텀 스크롤 (손가락 뗀 후 관성)
        // 두 경우 모두 원본 이벤트를 그대로 통과시켜 시스템 기본 동작 유지
        let scrollPhase    = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentumPhase  = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        if scrollPhase != 0 || momentumPhase != 0 {
            return event
        }

        let deltaY = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        let deltaX = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)

        if abs(deltaY) < 1.0 && abs(deltaX) < 1.0 {
            return event
        }

        os_unfair_lock_lock(&lock)

        if deltaY != 0 {
            if (velocityY > 0 && deltaY > 0) || (velocityY < 0 && deltaY < 0) {
                velocityY += deltaY * cfg.speedMultiplier
            } else {
                velocityY = deltaY * cfg.speedMultiplier
            }
        }

        if deltaX != 0 {
            if (velocityX > 0 && deltaX > 0) || (velocityX < 0 && deltaX < 0) {
                velocityX += deltaX * cfg.speedMultiplier
            } else {
                velocityX = deltaX * cfg.speedMultiplier
            }
        }

        if !isAnimating {
            isAnimating = true
            if let dl = displayLink {
                CVDisplayLinkStart(dl)
            }
        }

        os_unfair_lock_unlock(&lock)

        return nil
    }

    // MARK: - Animation Tick
    func animationTick() {
        os_unfair_lock_lock(&lock)

        let cfg = hotPathConfig
        let currentVY = velocityY
        let currentVX = velocityX

        velocityY *= cfg.smoothness
        velocityX *= cfg.smoothness

        if abs(velocityY) < cfg.minimumVelocity && abs(velocityX) < cfg.minimumVelocity {
            velocityY = 0
            velocityX = 0
            isAnimating = false
            if let dl = displayLink {
                CVDisplayLinkStop(dl)
            }
            os_unfair_lock_unlock(&lock)
            return
        }

        os_unfair_lock_unlock(&lock)

        // CGEvent.post는 메인 스레드에서만 안전 — DisplayLink 콜백은 별도 스레드이므로 dispatch
        DispatchQueue.main.async { [weak self] in
            self?.postSilkyScrollEvent(deltaY: currentVY, deltaX: currentVX)
        }
    }
    
    private func postSilkyScrollEvent(deltaY: Double, deltaX: Double) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        
        // pixel 단위로 부드러운 스크롤 값 설정
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: deltaY)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: deltaX)
        
        // continuous 스크롤로 표시 (부드러운 스크롤)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        
        // cgSessionEventTap으로 발송 — cghidEventTap으로 보내면 자신의 탭이 다시 수신해 무한루프 발생
        event.post(tap: .cgSessionEventTap)
    }
    
    // MARK: - Menu Bar
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.title = "🖱️"
        }
        
        let menu = NSMenu()
        
        // 제목
        let titleItem = NSMenuItem(title: "SilkyScroll", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 활성화 토글
        let enableItem = NSMenuItem(
            title: "Enabled",
            action: #selector(toggleEnabled),
            keyEquivalent: "e"
        )
        enableItem.target = self
        enableItem.state = config.enabled ? .on : .off
        self.enabledMenuItem = enableItem
        menu.addItem(enableItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 스크롤 속도 서브메뉴
        let speedMenu = NSMenu()
        for speed in [1.0, 2.0, 3.0, 4.0, 5.0, 7.0, 10.0] {
            let item = NSMenuItem(
                title: "\(speed)x",
                action: #selector(setSpeed(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = Int(speed * 10)
            item.state = (config.scrollSpeed == speed) ? .on : .off
            speedMenu.addItem(item)
        }
        let speedItem = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        speedItem.submenu = speedMenu
        menu.addItem(speedItem)
        
        // 부드러움 서브메뉴
        let smoothMenu = NSMenu()
        for (label, value) in [("Low", 0.70), ("Medium", 0.80), ("High", 0.85), ("Very High", 0.90), ("Ultra", 0.95)] {
            let item = NSMenuItem(
                title: label,
                action: #selector(setSmoothness(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = Int(value * 100)
            item.state = (Int(config.smoothness * 100) == Int(value * 100)) ? .on : .off
            smoothMenu.addItem(item)
        }
        let smoothItem = NSMenuItem(title: "Smoothness", action: nil, keyEquivalent: "")
        smoothItem.submenu = smoothMenu
        menu.addItem(smoothItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 로그인 시 자동 실행
        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = isLaunchAtLoginEnabled ? .on : .off
        self.launchAtLoginMenuItem = launchItem
        menu.addItem(launchItem)
        
        // 메뉴바 아이콘 숨기기
        let hideItem = NSMenuItem(
            title: "Hide Menu Bar Icon",
            action: #selector(toggleMenuBarIcon),
            keyEquivalent: ""
        )
        hideItem.target = self
        self.hideMenuBarMenuItem = hideItem
        menu.addItem(hideItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 종료
        let quitItem = NSMenuItem(
            title: "Quit SilkyScroll",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    @objc private func toggleEnabled() {
        config.enabled.toggle()
        syncHotPathConfig()
        enabledMenuItem?.state = config.enabled ? .on : .off

        if !config.enabled {
            os_unfair_lock_lock(&lock)
            velocityY = 0
            velocityX = 0
            isAnimating = false
            if let dl = displayLink {
                CVDisplayLinkStop(dl)
            }
            os_unfair_lock_unlock(&lock)
        }

        print(config.enabled ? "✅ SilkyScroll 활성화" : "⏸️ SilkyScroll 비활성화")
    }
    
    @objc private func setSpeed(_ sender: NSMenuItem) {
        let speed = Double(sender.tag) / 10.0
        config.scrollSpeed = speed
        syncHotPathConfig()
        
        // 메뉴 상태 업데이트
        sender.menu?.items.forEach { $0.state = .off }
        sender.state = .on
        
        print("🔧 스크롤 속도: \(speed)x")
    }
    
    @objc private func setSmoothness(_ sender: NSMenuItem) {
        let smoothness = Double(sender.tag) / 100.0
        config.smoothness = smoothness
        syncHotPathConfig()
        
        sender.menu?.items.forEach { $0.state = .off }
        sender.state = .on
        
        print("🔧 부드러움: \(smoothness)")
    }

    /// config 변경 후 반드시 호출 — lock 안에서 hotPathConfig를 원자적으로 갱신하고 UserDefaults에 저장
    private func syncHotPathConfig() {
        let snapshot = config.hotPath
        os_unfair_lock_lock(&lock)
        hotPathConfig = snapshot
        os_unfair_lock_unlock(&lock)
        config.save()
    }
    
    // MARK: - Launch at Login

    /// SMAppService를 이용해 현재 로그인 시 자동 실행 등록 여부를 반환 (macOS 13+)
    private var isLaunchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else {
            print("⚠️ Launch at Login은 macOS 13 이상에서만 지원됩니다.")
            return
        }
        do {
            if isLaunchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
                launchAtLoginMenuItem?.state = .off
                print("🔧 로그인 시 자동 실행 해제")
            } else {
                try SMAppService.mainApp.register()
                launchAtLoginMenuItem?.state = .on
                print("🔧 로그인 시 자동 실행 등록")
            }
        } catch {
            print("❌ Launch at Login 변경 실패: \(error.localizedDescription)")
        }
    }

    // MARK: - Hide Menu Bar Icon

    // AppDelegate에서 접근하므로 internal
    var isMenuBarIconHidden = false
    /// 설정 패널 (메뉴바 아이콘이 숨겨진 동안 앱 재실행 시 표시)
    private var settingsPanel: NSPanel?

    @objc private func toggleMenuBarIcon() {
        if isMenuBarIconHidden {
            statusItem?.isVisible = true
            isMenuBarIconHidden = false
            hideMenuBarMenuItem?.title = "Hide Menu Bar Icon"
            print("👁️ 메뉴바 아이콘 표시")
        } else {
            let alert = NSAlert()
            alert.messageText = "메뉴바 아이콘 숨기기"
            alert.informativeText = """
                메뉴바 아이콘이 숨겨집니다.
                SilkyScroll은 백그라운드에서 계속 동작합니다.

                다시 설정하려면 런치패드에서 앱 아이콘을 클릭하세요.
                """
            alert.addButton(withTitle: "숨기기")
            alert.addButton(withTitle: "취소")
            alert.alertStyle = .informational
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            statusItem?.isVisible = false
            isMenuBarIconHidden = true
            hideMenuBarMenuItem?.title = "Show Menu Bar Icon"
            print("🙈 메뉴바 아이콘 숨김 (런치패드에서 앱 클릭 시 설정창 표시)")
        }
    }

    // MARK: - Settings Panel

    /// 메뉴바 아이콘이 숨겨진 상태에서 앱을 다시 열었을 때 호출
    func showSettingsPanel() {
        // 이미 열려 있으면 앞으로 가져오기만 함
        if let panel = settingsPanel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 380),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "SilkyScroll 설정"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.center()

        // contentView는 panel이 자동으로 생성한 것을 재사용 — 직접 frame을 계산하면 타이틀바 높이가 중복 포함됨
        guard let contentView = panel.contentView else { return }

        var yOffset = contentView.bounds.height - 20
        let leftMargin: CGFloat = 20
        let labelWidth: CGFloat = 260

        func addLabel(_ text: String, bold: Bool = false) {
            yOffset -= 24
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: leftMargin, y: yOffset, width: labelWidth, height: 20)
            if bold { label.font = .boldSystemFont(ofSize: 13) }
            contentView.addSubview(label)
        }

        func addSeparator() {
            yOffset -= 8
            let sep = NSBox(frame: NSRect(x: leftMargin, y: yOffset, width: labelWidth, height: 1))
            sep.boxType = .separator
            contentView.addSubview(sep)
            yOffset -= 4
        }

        // ── Enabled 토글 ──
        addSeparator()
        yOffset -= 28
        let enableSwitch = NSButton(checkboxWithTitle: "Enabled", target: self, action: #selector(toggleEnabled))
        enableSwitch.frame = NSRect(x: leftMargin, y: yOffset, width: labelWidth, height: 22)
        enableSwitch.state = config.enabled ? .on : .off
        contentView.addSubview(enableSwitch)

        addSeparator()

        // ── Speed ──
        addLabel("Speed", bold: true)
        let speeds: [Double] = [1, 2, 3, 4, 5, 7, 10]
        let speedSeg = NSSegmentedControl(
            labels: speeds.map { "\(Int($0))x" },
            trackingMode: .selectOne,
            target: self,
            action: #selector(segmentedSpeedChanged(_:))
        )
        speedSeg.frame = NSRect(x: leftMargin, y: yOffset - 28, width: labelWidth, height: 24)
        if let idx = speeds.firstIndex(of: config.scrollSpeed) {
            speedSeg.selectedSegment = idx
        }
        yOffset -= 32
        contentView.addSubview(speedSeg)

        addSeparator()

        // ── Smoothness ──
        addLabel("Smoothness", bold: true)
        let smoothValues: [(String, Double)] = [
            ("Low", 0.70), ("Med", 0.80), ("High", 0.85), ("V.High", 0.90), ("Ultra", 0.95)
        ]
        let smoothSeg = NSSegmentedControl(
            labels: smoothValues.map(\.0),
            trackingMode: .selectOne,
            target: self,
            action: #selector(segmentedSmoothnessChanged(_:))
        )
        smoothSeg.frame = NSRect(x: leftMargin, y: yOffset - 28, width: labelWidth, height: 24)
        if let idx = smoothValues.firstIndex(where: { Int($0.1 * 100) == Int(config.smoothness * 100) }) {
            smoothSeg.selectedSegment = idx
        }
        yOffset -= 32
        contentView.addSubview(smoothSeg)

        addSeparator()

        // ── Launch at Login ──
        yOffset -= 28
        let loginSwitch = NSButton(checkboxWithTitle: "Launch at Login", target: self, action: #selector(toggleLaunchAtLogin))
        loginSwitch.frame = NSRect(x: leftMargin, y: yOffset, width: labelWidth, height: 22)
        if #available(macOS 13.0, *) {
            loginSwitch.state = isLaunchAtLoginEnabled ? .on : .off
        } else {
            loginSwitch.isEnabled = false
        }
        contentView.addSubview(loginSwitch)

        // ── Show Menu Bar Icon ──
        yOffset -= 30
        let showMenuBarBtn = NSButton(title: "Show Menu Bar Icon", target: self, action: #selector(toggleMenuBarIcon))
        showMenuBarBtn.frame = NSRect(x: leftMargin, y: yOffset, width: labelWidth, height: 22)
        showMenuBarBtn.bezelStyle = .rounded
        contentView.addSubview(showMenuBarBtn)

        addSeparator()

        // ── Quit ──
        yOffset -= 32
        let quitBtn = NSButton(title: "Quit SilkyScroll", target: self, action: #selector(quit))
        quitBtn.frame = NSRect(x: leftMargin, y: yOffset, width: labelWidth, height: 22)
        quitBtn.bezelStyle = .rounded
        quitBtn.contentTintColor = .systemRed
        contentView.addSubview(quitBtn)

        self.settingsPanel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // NSSegmentedControl 핸들러 — 메뉴 항목과 동일한 로직 재사용
    @objc private func segmentedSpeedChanged(_ sender: NSSegmentedControl) {
        let speeds: [Double] = [1, 2, 3, 4, 5, 7, 10]
        let speed = speeds[sender.selectedSegment]
        config.scrollSpeed = speed
        syncHotPathConfig()
        // 메뉴바 서브메뉴 체크마크도 동기화
        if let speedMenu = statusItem?.menu?.items.first(where: { $0.title == "Speed" })?.submenu {
            speedMenu.items.forEach { $0.state = (Double($0.tag) / 10.0 == speed) ? .on : .off }
        }
        print("🔧 스크롤 속도: \(speed)x")
    }

    @objc private func segmentedSmoothnessChanged(_ sender: NSSegmentedControl) {
        let smoothValues: [Double] = [0.70, 0.80, 0.85, 0.90, 0.95]
        let smoothness = smoothValues[sender.selectedSegment]
        config.smoothness = smoothness
        syncHotPathConfig()
        if let smoothMenu = statusItem?.menu?.items.first(where: { $0.title == "Smoothness" })?.submenu {
            smoothMenu.items.forEach { $0.state = (Int($0.tag) == Int(smoothness * 100)) ? .on : .off }
        }
        print("🔧 부드러움: \(smoothness)")
    }
    
    @objc private func quit() {
        // 정리
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let dl = displayLink {
            CVDisplayLinkStop(dl)
        }
        
        print("👋 SilkyScroll 종료")
        NSApp.terminate(nil)
    }
    
    func cleanup() {
        if let dl = displayLink {
            CVDisplayLinkStop(dl)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }
}

// MARK: - C Callback (반드시 전역 함수여야 @convention(c) 함수 포인터로 변환 가능)
// 로직은 모두 engine.handleEventTapCallback에 위임
private func scrollEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<SilkyScrollEngine>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return engine.handleEventTapCallback(type: type, event: event)
}


class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        SilkyScrollEngine.shared.start()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        SilkyScrollEngine.shared.cleanup()
    }

    /// 런치패드 또는 Finder에서 앱 아이콘을 클릭하면 호출됨
    /// 메뉴바 아이콘이 숨겨진 상태일 때만 설정 패널을 띄운다
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard SilkyScrollEngine.shared.isMenuBarIconHidden else { return false }
        SilkyScrollEngine.shared.showSettingsPanel()
        return false // 기본 동작(윈도우 복원) 억제
    }
}

// MARK: - Entry Point
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // 메뉴바 전용 앱 (Dock 아이콘 없음)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
