import AppKit

/// DSH Launcher —— 菜单栏常驻应用（GeminiAppLauncher 模式）
/// LSUIElement（无 Dock 图标、启动台不显示），鲸鱼小图标常驻菜单栏；
/// 左键点击启动/唤起主应用 DSH Desktop；右键菜单提供操作。
///
/// 不提供"登录自启"：SMAppService 仅对 /Applications(或 /Library) 内应用生效，
/// 本应用安装在 ~/Library/Application Support（隐藏启动台），故由主应用
/// 设置页决定何时运行时驻留；由主应用 MenuBarPluginManager 拉起本进程。
///
/// v1 迭代（对齐卡第五轮定稿）：
/// - 三态图标：绿=鲸鱼原样 / 过渡="？"闪烁角标 / 异常="！"角标（StatusIcons）
/// - 自适应健康轮询：稳态 30s，突变后 60s 内 5s，菜单展开强制补测（StatusProbe）
/// - 右键菜单按卡 B1 精简为：启动 DSH Desktop / 一键体检 / 退出
@MainActor
final class LauncherApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let probe = StatusProbe()
    private let visibility = VisibilityMonitor()
    /// 过渡态闪烁节拍器：仅 transitional 期间运行，其余状态自动停表（功耗红线）
    private var blinkTimer: Timer?
    private var blinkOn = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // LSUIElement 保险
        enforceSingleInstance()
        setupStatusItem()
        probe.onChange = { [weak self] state, detail in
            self?.render(state: state, detail: detail)
        }
        // 先亮出红灯语义（后端是否在跑探测一次才知道，未知的瞬间以 down 姿态出现）
        render(state: .down, detail: "正在探测 DSH Desktop 后端…")
        probe.start()

        visibility.start()
        HotKeyCenter.install { [weak self] in
            self?.handleHotKey()
        }
    }

    /// ⌘⇧D 入口：三态矩阵判定（对齐卡卡4）
    private func handleHotKey() {
        let running = !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.deepseek-ai.dsh-desktop")
            .isEmpty
        switch MiniDialogPolicy.evaluate(appRunning: running,
                                         backendState: probe.state,
                                         lastKnownVisible: visibility.lastKnownVisible) {
        case .show:
            probe.refreshNow()   // 弹出前补测，tooltip 与图标即刻反映真实后端态
            MiniDialogPanelController.shared.present()
        case .disabledByVisibleApp:
            break                // 状态 ii：主应用可见即唯一输入面，快捷键静默失效
        }
    }

    /// 单实例守卫：直接重复执行二进制时避免出现两个鲸鱼图标
    private func enforceSingleInstance() {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.deepseek-ai.dsh-launcher")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty { NSApp.terminate(nil) }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = StatusIcons.whaleBase
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    // MARK: - 三态渲染

    private func render(state: BackendState, detail: String) {
        guard let button = statusItem?.button else { return }
        stopBlink()
        switch state {
        case .healthy:
            button.image = StatusIcons.healthy
        case .transitional:
            button.image = StatusIcons.transitional(blinkOn: true)
            startBlink()
        case .down:
            button.image = StatusIcons.exclamation
        }
        button.toolTip = detail
    }

    private func startBlink() {
        blinkOn = true
        let t = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.blinkTimer != nil else { return }
                self.blinkOn.toggle()
                self.statusItem?.button?.image = StatusIcons.transitional(blinkOn: self.blinkOn)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        blinkTimer = t
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
    }

    // MARK: - 交互

    @objc private func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            // 左键三态判定（2026-08-28 用户改定）：应用不可见（未启动/最小化/隐藏）
            // → 弹迷你框；可见 → 维持 v0 行为：启动/激活主应用
            let running = !NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.deepseek-ai.dsh-desktop")
                .isEmpty
            if MiniDialogPolicy.evaluate(appRunning: running,
                                         backendState: probe.state,
                                         lastKnownVisible: visibility.lastKnownVisible) == .show {
                probe.refreshNow()
                MiniDialogPanelController.shared.present()
            } else {
                launchMainApp()
            }
        }
    }

    /// 启动/唤起主应用（已运行则激活）
    @objc private func launchMainApp() {
        let candidates = [
            URL(fileURLWithPath: "/Applications/DSH Desktop.app"),
            URL(fileURLWithPath: "\(NSHomeDirectory())/Applications/DSH Desktop.app"),
            URL(fileURLWithPath: "\(NSHomeDirectory())/Desktop/dsh-macos/build/DSH Desktop.app"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            // 用 open 携带 activate=true 语义：运行中则激活，未运行则启动
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
            return
        }
        let alert = NSAlert()
        alert.messageText = "找不到 DSH Desktop"
        alert.informativeText = "请把 DSH Desktop.app 放到 /Applications 目录后重试。"
        alert.runModal()
    }

    private func showMenu() {
        // 卡 A3：菜单展开瞬间强制补测——此刻先同步刷图标与 tooltip，
        // 菜单本身按定稿不含状态行，所以补测结果只体现在菜单关闭后的图标上。
        probe.refreshNow()

        let menu = NSMenu()
        menu.addItem(withTitle: "启动 DSH Desktop", action: #selector(launchMainApp), keyEquivalent: "")
        menu.addItem(withTitle: "一键体检", action: #selector(openCheckup), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 DSH Launcher", action: #selector(quit), keyEquivalent: "q")
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    /// 一键体检（M2）：弹独立小窗逐行刷出只读检测结果，不干扰主应用任何进程
    @objc private func openCheckup() {
        CheckupWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
// 进程入口即在主线程：assumeIsolated 把启动代码归入主执行域（LauncherApp 为 @MainActor）
MainActor.assumeIsolated {
    let delegate = LauncherApp()
    app.delegate = delegate
}
app.run()
