import AppKit

/// 迷你框三态判定策略（对齐卡卡4 三态矩阵，修订 P2-6）：
/// - 应用未在跑                     → 弹迷你框（状态 i；含"进程残留但后端已死"的变体）
/// - 应用在跑且可见                 → 快捷键/左键走"激活主应用"
/// - 应用在跑但最小化（或信号未知）→ 状态 iii / 保守失效
@MainActor
enum MiniDialogPolicy {
    enum Decision { case show, disabledByVisibleApp }

    static func evaluate(appRunning: Bool,
                         backendState: BackendState,
                         lastKnownVisible: Bool?) -> Decision {
        guard appRunning else { return .show }
        if backendState == .down && lastKnownVisible != true { return .show }
        switch lastKnownVisible {
        case .some(false): return .show                // 最小化/隐藏
        default: return .disabledByVisibleApp           // 可见或未知，一律保守
        }
    }
}

/// 后端拉起器（对齐卡卡4：Launcher 代为 spawn，与主应用 spawn 方式一致）。
@MainActor
enum BackendSpawner {
    static func ensureRunning() async -> Bool {
        if await probeOnce() { return true }
        return await spawnAndAwaitHealthy()
    }

    private static func probeOnce() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:3080/api/desktop/status") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["ok"] as? Bool == true else { return false }
            return true
        } catch {
            return false
        }
    }

    private static func locateBinJS() -> String? {
        let root = NSHomeDirectory() + "/.npm/_npx"
        var best: (path: String, mtime: Date)?
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
        let fm = FileManager.default
        for entry in entries {
            let bin = root + "/" + entry + "/node_modules/@deepseek-ai/dsh/lib/bin.js"
            guard fm.fileExists(atPath: bin),
                  let attrs = try? fm.attributesOfItem(atPath: bin),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if best == nil || mtime > best!.mtime { best = (bin, mtime) }
        }
        return best?.path
    }

    private static var nodePath: String? {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func spawnAndAwaitHealthy() async -> Bool {
        if await probeOnce() { return true }
        guard let node = nodePath, let binJS = locateBinJS() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [binJS, "--profile", "web", "--no-open", "--port", "3080"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("[dsh-launcher] 后端拉起失败: \(error.localizedDescription)")
            return false
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if await probeOnce() { return true }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return false
    }
}

// MARK: - 迷你对话框（Gemini 式单行胶囊，2026-08-29 R2 重设计）

/// borderless 面板默认不可成为 key window——不重写 canBecomeKey 文字框拿不到焦点。
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct ModelOption {
    var providerID: String
    var providerName: String
    var modelID: String
    var displayName: String
    var detail: String
}

/// 单行胶囊 [+ | 输入区(自适应换行撑高) | 模型chip | ↑]：
/// - "+"弹工作区菜单（不使用项目/已选文件夹/添加工作区…访达）
/// - 输入多行时胶囊向上生长（Gemini 式），控件保持垂直居中
/// - 失去 key 焦点即收起（点击外部/切应用的标准消散方式）；Esc 亦可
@MainActor
final class MiniDialogPanelController: NSObject, NSTextViewDelegate {
    static let shared = MiniDialogPanelController()

    // 几何（单一坐标系：所有子视图都以面板内容视图为参照，杜绝再错位）
    private enum Metrics {
        static let panelWidth: CGFloat = 640
        static let basePillHeight: CGFloat = 54       // 单行时胶囊高
        static let maxPillHeight: CGFloat = 150       // 多行生长上限
        static let hintHeight: CGFloat = 20           // 胶囊下方提示行区
        static let plusX: CGFloat = 12
        static let inputX: CGFloat = 54
        static let sendSize: CGFloat = 32
        static let modelChipWidth: CGFloat = 104
    }

    private var panel: KeyablePanel?
    private var pillView: NSView!
    private var inputScrollView: NSScrollView?
    private var plusButton: NSButton?
    private var modelChip: NSButton?
    private var textView: PillTextView?
    private var sendButton: NSButton?
    private var hintLabel: NSTextField?
    private var monitors: [Any] = []
    private var resignKeyObserver: NSObjectProtocol?
    private var sending = false
    /// 收起动画中抑制 resignKey 二次触发
    private var dismissing = false
    /// 菜单/工作区选择器跟踪期间抑制"失 key 即收"。计数器式（R7）：菜单跟踪与
    /// 访达面板会嵌套，布尔置位会被外层提前清零造成踩踏
    private var menuInteraction = 0
    private weak var openMenu: NSMenu?

    // 选择状态
    private var projectPath: String?
    private var selectedModel: ModelOption?
    private var selectedReasoning: String?
    private var modelOptions: [ModelOption] = []
    private struct ReasoningOption { let id: String; let name: String }
    private var reasoningOptions: [ReasoningOption] = []
    private var defaultReasoning: String?
    private var defaultProviderID: String?
    private var defaultModelID: String?
    private var defaultModelLabel: String = "默认模型"

    private struct SendError: Error { let message: String }
    private struct SessionResponse: Decodable {
        let ok: Bool
        let sessionId: String?
        let warning: String?
        let error: String?
    }

    // MARK: - 展示与收起

    func present() {
        if panel == nil { buildPanel() }
        dismissing = false
        resetForNewDraft()
        positionAtBottomCenter()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeFirstResponder(textView)
        installMonitorsIfNeeded()
        Task { @MainActor in await refreshModelChoices() }
    }

    func dismiss() {
        guard panel?.isVisible == true else { return }
        dismissing = true
        panel?.orderOut(nil)
        removeMonitorsIfNeeded()
    }

    private func positionAtBottomCenter() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        relayout()   // 先按当前内容定高，再定位
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.minY + 28))
    }

    private func resetForNewDraft() {
        projectPath = nil
        selectedModel = nil
        selectedReasoning = nil
        modelChip?.title = defaultModelLabel
        hintLabel?.stringValue = ""
        hintLabel?.textColor = .secondaryLabelColor
        hintLabel?.isHidden = true
        textView?.string = ""
        sending = false
        updateSendEnabled()
    }

    // MARK: - 构建

    private func buildPanel() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth,
                                height: Metrics.basePillHeight + Metrics.hintHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: panel.frame)
        content.wantsLayer = true

        // 胶囊体：实心深色（与 DSH 首页输入卡同调，不发灰）
        let pill = NSView(frame: NSRect(x: 0, y: Metrics.hintHeight,
                                        width: Metrics.panelWidth, height: Metrics.basePillHeight))
        pill.wantsLayer = true
        // 深浅色自适应（R4）：暗色=深灰卡；浅色=白卡。面板存续期短，不做换肤监听
        pill.layer?.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.115, alpha: 0.97)
                : NSColor.white.withAlphaComponent(0.97)
        }.cgColor
        pill.layer?.cornerCurve = .continuous
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.10)
                : NSColor.black.withAlphaComponent(0.08)
        }.cgColor
        pill.layer?.masksToBounds = true         // 裁掉超高文本；圆角干净
        content.addSubview(pill)
        pillView = pill

        // "+"：工作区菜单（选择工作区 / 添加工作区…访达）
        let plus = NSButton(frame: NSRect(x: Metrics.plusX, y: 0, width: 30, height: 30))
        plus.isBordered = false
        plus.title = "+"
        plus.contentTintColor = .secondaryLabelColor
        plus.font = NSFont.systemFont(ofSize: 17, weight: .regular)
        plus.target = self
        plus.action = #selector(plusTapped(_:))
        pill.addSubview(plus)
        plusButton = plus

        // 输入区（自适应换行；回车发送 ⇧回车换行）。必须嵌 NSScrollView：
        // 裸 NSTextView 的插入点超出可视区不会自动滚动（R5"按↓光标消失"根因）
        let input = PillTextView(frame: NSRect(x: 0, y: 0, width: inputWidth(), height: 24))
        input.font = NSFont.systemFont(ofSize: 14)   // 审查 P1-3：默认打字字体实为 Helvetica 12
        input.placeholder = "尽管问，开始工作…"
        input.drawsBackground = false            // 真机 R2：深色矩形根因
        input.textContainerInset = NSSize(width: 1, height: 3)   // 14pt 字行高≈18，上下各 3 → 光标垂直对称
        input.textContainer?.lineFragmentPadding = 1
        input.minSize = NSSize(width: 0, height: 24)
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]
        input.delegate = self
        input.onSend = { [weak self] in self?.sendTapped() }
        let inputScroll = NSScrollView()
        inputScroll.drawsBackground = false
        inputScroll.hasVerticalScroller = false
        inputScroll.hasHorizontalScroller = false
        inputScroll.autohidesScrollers = true
        inputScroll.documentView = input
        pill.addSubview(inputScroll)
        inputScrollView = inputScroll
        textView = input

        // 模型 chip（富选择菜单）
        let model = NSButton(title: defaultModelLabel, target: nil, action: nil)
        model.isBordered = false
        model.controlSize = .small
        model.font = NSFont.systemFont(ofSize: 12)
        model.contentTintColor = .secondaryLabelColor
        model.lineBreakMode = .byTruncatingTail
        model.target = self
        model.action = #selector(modelChipTapped(_:))
        pill.addSubview(model)
        modelChip = model

        // 发送（蓝色圆钮，随输入启用）
        let send = NSButton(frame: NSRect(x: 0, y: 0, width: Metrics.sendSize, height: Metrics.sendSize))
        send.isBordered = false
        send.image = NSImage(systemSymbolName: "arrow.up",
                             accessibilityDescription: "发送")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        send.imageScaling = .scaleProportionallyDown
        send.contentTintColor = .white
        send.wantsLayer = true
        send.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        send.layer?.cornerRadius = Metrics.sendSize / 2
        send.target = self
        send.action = #selector(sendTapped)
        send.isEnabled = false
        pill.addSubview(send)
        sendButton = send

        // 提示行（悬浮胶囊下方）
        let hint = NSTextField(labelWithString: "")
        hint.frame = NSRect(x: 14, y: 2, width: Metrics.panelWidth - 28, height: 16)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingMiddle
        content.addSubview(hint)
        hintLabel = hint

        panel.contentView = content
        self.panel = panel
        relayout()
    }

    private func inputWidth() -> CGFloat {
        Metrics.panelWidth - Metrics.inputX - 14 - Metrics.modelChipWidth - 10 - Metrics.sendSize - 14
    }

    /// 按输入行数重排：胶囊向上生长，控件保持垂直居中（R2 修错位：全部子视图
    /// 以 pill 为参照居中排布，输入框高度即内容高度）。
    func relayout() {
        guard let panel, let pillView, let textView, let inputScrollView else { return }

        // 展开态输入区通栏（R6）：单行宽 412 / 通栏宽 600
        let expandedInputX: CGFloat = 20
        let expandedInputW = Metrics.panelWidth - 40

        // 迟滞判定（R7 修正 R6 的振荡）：以"当前态自己的宽度"测量——
        // 单行态在 412 宽下超一行 → 展开；展开态在 600 宽下回落一行 → 收回。
        // 412 比 600 更早换行，两个阈值天然错开，不会抖动。
        let currentlyExpanded = pillView.frame.height > Metrics.basePillHeight + 1
        let measureW = currentlyExpanded ? expandedInputW : inputWidth()
        if textView.frame.width != measureW { textView.frame.size.width = measureW }

        // 内容高度：usedRect 为纯文本高（含多行行距）；+6 = 上下 inset(3×2)
        let usedH = textView.contentSize().height
        let lineH: CGFloat = 18                              // 14pt 系统字行高（测得）
        let textH = max(lineH, ceil(usedH)) + 6
        let expanded = usedH > lineH

        let topPad: CGFloat = 12
        let controlRowCenterFromBottom: CGFloat = 22
        let controlRowTop: CGFloat = 44
        let pillHeight = expanded ? min(Metrics.maxPillHeight, topPad + textH + controlRowTop)
                                  : Metrics.basePillHeight

        let hintVisible = (hintLabel?.stringValue.isEmpty == false)
        // 圆角对齐 Gemini：单行=全胶囊，展开=固定 24
        pillView.layer?.cornerRadius = expanded ? 24 : pillHeight / 2

        // 底边锚定向上生长（setContentSize 顶边固定语义补偿）
        let oldFrame = panel.frame
        let panelH = pillHeight + (hintVisible ? Metrics.hintHeight : 0)
        if abs(oldFrame.height - panelH) > 0.5 {
            panel.setContentSize(NSSize(width: Metrics.panelWidth, height: panelH))
            panel.setFrameOrigin(NSPoint(x: oldFrame.origin.x, y: oldFrame.minY))
        }
        let pillY: CGFloat = hintVisible ? Metrics.hintHeight : 0
        pillView.frame = NSRect(x: 0, y: pillY, width: Metrics.panelWidth, height: pillHeight)

        // 控件行：单行=胶囊垂直中心；展开=距底 22
        let controlY = expanded ? controlRowCenterFromBottom : pillHeight / 2
        plusButton?.frame = NSRect(x: Metrics.plusX, y: controlY - 15, width: 30, height: 30)
        sendButton?.frame = NSRect(x: Metrics.panelWidth - 14 - Metrics.sendSize,
                                   y: controlY - Metrics.sendSize / 2,
                                   width: Metrics.sendSize, height: Metrics.sendSize)
        let modelW = Metrics.modelChipWidth
        modelChip?.frame = NSRect(x: Metrics.panelWidth - 14 - Metrics.sendSize - 10 - modelW,
                                  y: controlY - 12, width: modelW, height: 24)

        // 输入视口：单行=行高带（居中）；展开=通栏 [控件行上方44, 顶部12] 区间
        if expanded {
            let viewportH = pillHeight - topPad - controlRowTop
            inputScrollView.frame = NSRect(x: expandedInputX, y: controlRowTop,
                                           width: expandedInputW, height: max(24, viewportH))
            textView.frame = NSRect(x: 0, y: 0, width: expandedInputW,
                                    height: max(textH, max(24, viewportH)))
        } else {
            let singleH = max(24, textH)                     // 行盒超 24（emoji 等）也能撑开
            inputScrollView.frame = NSRect(x: Metrics.inputX, y: controlY - singleH / 2,
                                           width: measureW, height: singleH)
            textView.frame = NSRect(x: 0, y: 0, width: measureW, height: singleH)
        }
    }

    func textDidChange(_ notification: Notification) {
        updateSendEnabled()
        relayout()
    }

    // MARK: - 数据刷新（模型清单与思考强度档位）

    private struct OptionsResponse: Decodable {
        struct Provider: Decodable { let id: String; let name: String?; let models: [ModelRow]? }
        struct ModelRow: Decodable { let id: String; let name: String?; let description: String? }
        struct DefaultModel: Decodable { let provider: String?; let model: String? }
        struct ReasoningEffort: Decodable { let id: String; let name: String }
        struct ReasoningResponse: Decodable { let efforts: [ReasoningEffort]?; let defaultEffort: String? }
        let providers: [Provider]?
        let defaultModel: DefaultModel?
    }

    private func refreshModelChoices() async {
        guard let url = URL(string: "http://127.0.0.1:3080/api/mini/options") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let decoded = try? JSONDecoder().decode(OptionsResponse.self, from: data) else { return }
            var options: [ModelOption] = []
            for provider in decoded.providers ?? [] {
                let providerName = provider.name ?? provider.id
                for row in provider.models ?? [] {
                    options.append(ModelOption(providerID: provider.id, providerName: providerName,
                                               modelID: row.id, displayName: row.name ?? row.id,
                                               detail: row.description ?? providerName))
                }
            }
            modelOptions = options
            if let def = decoded.defaultModel, let p = def.provider, let m = def.model {
                defaultModelLabel = "默认 · \(displayName(provider: p, model: m))"
                defaultProviderID = p
                defaultModelID = m
            } else {
                defaultModelLabel = "默认模型"
                defaultProviderID = nil
                defaultModelID = nil
            }
            if selectedModel == nil {
                modelChip?.title = defaultModelLabel
                await refreshReasoning(provider: defaultProviderID, model: defaultModelID)
            }
        } catch { /* 后端不在：保持占位标题 */ }
    }

    private func refreshReasoning(provider: String?, model: String?) async {
        guard let provider, let model else {
            reasoningOptions = []; defaultReasoning = nil; return
        }
        var components = URLComponents(string: "http://127.0.0.1:3080/api/mini/reasoning")!
        components.queryItems = [URLQueryItem(name: "provider", value: provider),
                                 URLQueryItem(name: "model", value: model)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let decoded = try? JSONDecoder().decode(OptionsResponse.ReasoningResponse.self, from: data) else { return }
            reasoningOptions = (decoded.efforts ?? []).map { ReasoningOption(id: $0.id, name: $0.name) }
            defaultReasoning = decoded.defaultEffort
        } catch {
            reasoningOptions = []; defaultReasoning = nil
        }
    }

    private func displayName(provider: String, model: String) -> String {
        modelOptions.first { $0.providerID == provider && $0.modelID == model }?.displayName ?? model
    }

    // MARK: - 菜单

    /// 可点击菜单行：NSMenuItem 挂自定义视图后 action 不再自动派发（R3 根因），
    /// 用整行透明按钮接管点击，动作仍走原 selector；菜单收起由 closeMenu 统一处理。
    private func menuRow(title: String, detail: String?, checked: Bool,
                         action: Selector?, identifier: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let rowH: CGFloat = detail == nil ? 24 : 38
        let row = MenuRowView(frame: NSRect(x: 0, y: 0, width: 260, height: rowH))

        let check = NSTextField(labelWithString: checked ? "✓" : "")
        check.frame = NSRect(x: 8, y: detail == nil ? 4 : 11, width: 16, height: 16)
        check.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        row.addSubview(check)
        let name = NSTextField(labelWithString: title)
        name.font = NSFont.systemFont(ofSize: 13, weight: action == nil ? .regular : .medium)
        name.textColor = action == nil ? .secondaryLabelColor : .labelColor
        name.frame = NSRect(x: 26, y: detail == nil ? 4 : 19, width: 226, height: 16)
        row.addSubview(name)
        if let detail {
            let sub = NSTextField(labelWithString: detail)
            sub.font = NSFont.systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            sub.frame = NSRect(x: 26, y: 3, width: 226, height: 14)
            row.addSubview(sub)
        }
        // 整行透明按钮：只在其上时才加；分区标题保持不可点
        if let action {
            let button = NSButton(frame: row.bounds)
            button.isBordered = false
            button.title = ""
            button.target = self
            button.action = action
            button.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
            button.autoresizingMask = [.width, .height]
            row.addSubview(button)
        }
        item.view = row
        return item
    }

    private func closeMenu() {
        openMenu?.cancelTracking()
        openMenu = nil
    }

    /// "+"：工作区菜单（选择工作区 / 添加工作区…访达）
    @objc private func plusTapped(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(menuRow(title: "选择工作区", detail: nil, checked: false, action: nil))
        menu.addItem(menuRow(title: "不使用项目", detail: nil,
                             checked: projectPath == nil, action: #selector(useNoProject)))
        if let path = projectPath {
            menu.addItem(menuRow(title: (path as NSString).lastPathComponent,
                                 detail: path, checked: true, action: nil))
        }
        menu.addItem(menuRow(title: "添加工作区…", detail: "打开访达选择文件夹",
                             checked: false, action: #selector(pickProjectFolder)))
        presentMenu(menu, anchoredTo: sender)
    }

    /// 弹菜单的统一入口：跟踪期间抑制失 key 收起（popUp 阻塞返回后恢复）
    private func presentMenu(_ menu: NSMenu, anchoredTo sender: NSButton) {
        openMenu = menu
        menuInteraction += 1
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.frame.height + 6), in: sender)
        menuInteraction -= 1
        openMenu = nil
        // 行点击后 key 的恢复是异步的（R6：同步检查会误杀"添加工作区"流程）——
        // 延迟一拍再判：应用还活跃就恢复焦点；只有真点到别的应用才收起
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel?.isVisible == true, self.menuInteraction == 0 else { return }
            if !NSApp.isActive {
                self.dismiss()
            } else if self.panel?.isKeyWindow == false {
                self.panel?.makeKeyAndOrderFront(nil)
                self.panel?.makeFirstResponder(self.textView)
            }
        }
    }

    @objc private func useNoProject() {
        closeMenu()
        projectPath = nil
    }

    @objc private func pickProjectFolder() {
        closeMenu()
        // R5：beginSheetModal 挂 borderless 非激活面板会被系统静默拒绝 → 改独立窗口式
        // begin{}，并显式激活本 app（accessory 应用不激活则面板无响应）。
        // R7：+1 计数防 presentMenu 返回路径提前清守卫
        menuInteraction += 1
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.prompt = "添加工作区"
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuInteraction -= 1
                if response == .OK, let url = picker.urls.first {
                    self.projectPath = url.path
                }
                // 选完把焦点还给输入区；但用户已切走应用时不强顶面板（审查 P2-3）
                if self.panel?.isVisible == true, NSApp.isActive {
                    self.panel?.makeKeyAndOrderFront(nil)
                    self.panel?.makeFirstResponder(self.textView)
                }
            }
        }
    }

    @objc private func modelChipTapped(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(menuRow(title: defaultModelLabel, detail: "由 DSH 宿主默认模型决定",
                             checked: selectedModel == nil, action: #selector(useDefaultModel)))
        var lastProvider = ""
        for option in modelOptions {
            if option.providerName != lastProvider, lastProvider.isEmpty == false {
                menu.addItem(.separator())
            }
            lastProvider = option.providerName
            let checked = selectedModel?.modelID == option.modelID
                && selectedModel?.providerID == option.providerID
            menu.addItem(menuRow(title: option.displayName, detail: option.detail,
                                 checked: checked, action: #selector(pickModelRow(_:)),
                                 identifier: option.providerID + "|" + option.modelID))
        }
        if reasoningOptions.isEmpty == false {
            menu.addItem(.separator())
            menu.addItem(menuRow(title: "思考强度", detail: "仅对本次新会话生效",
                                 checked: false, action: nil))
            for option in reasoningOptions {
                let checked = selectedReasoning == option.id
                    || (selectedReasoning == nil && option.id == defaultReasoning)
                let item = menuRow(title: option.name, detail: nil,
                                   checked: checked, action: nil)
                item.representedObject = option.id
                let button = (item.view as! NSView).subviews.compactMap { $0 as? NSButton }.first
                button?.target = self
                button?.action = #selector(pickReasoning(_:))
                button?.identifier = NSUserInterfaceItemIdentifier(option.id)
                menu.addItem(item)
            }
        }
        presentMenu(menu, anchoredTo: sender)
    }

    @objc private func useDefaultModel() {
        selectedModel = nil
        selectedReasoning = nil
        modelChip?.title = defaultModelLabel
        Task { @MainActor in
            await self.refreshReasoning(provider: self.defaultProviderID, model: self.defaultModelID)
        }
    }

    @objc private func pickModelRow(_ sender: NSButton) {
        closeMenu()
        // 按钮 identifier 携带 "providerID|modelID"（自定义视图菜单项无 representedObject 通道）
        guard let key = sender.identifier?.rawValue,
              let option = modelOptions.first(where: { $0.providerID + "|" + $0.modelID == key }) else { return }
        selectedModel = option
        selectedReasoning = nil                 // 档位按路由私有，切模型后重取
        modelChip?.title = option.displayName
        Task { @MainActor in
            await self.refreshReasoning(provider: option.providerID, model: option.modelID)
        }
    }

    @objc private func pickReasoning(_ sender: NSButton) {
        closeMenu()
        guard let id = sender.identifier?.rawValue else { return }
        selectedReasoning = id
    }

    // MARK: - 发送链路

    private func updateSendEnabled() {
        sendButton?.isEnabled = (textView?.string.isEmpty == false) && !sending
    }

    @objc private func sendTapped() {
        guard !sending else { return }
        let text = (textView?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return }

        sending = true
        updateSendEnabled()
        showHint("正在准备后端…", error: false)

        Task { @MainActor in
            do {
                _ = try await self.sendPipeline(
                    text: text, cwd: self.projectPath,
                    provider: self.selectedModel?.providerID,
                    model: self.selectedModel?.modelID,
                    reasoning: self.selectedReasoning)
                // R2 行为修正：先收起迷你框，再唤起主应用——面板不再残留
                self.dismiss()
                try await self.openMainAppForTransition()
            } catch let error as SendError {
                self.showHint(error.message, error: true)
                self.sending = false
                self.updateSendEnabled()
            } catch {
                self.showHint("出错了：\(error.localizedDescription)", error: true)
                self.sending = false
                self.updateSendEnabled()
            }
        }
    }

    private func sendPipeline(text: String, cwd: String?, provider: String?, model: String?, reasoning: String?) async throws -> String {
        guard await BackendSpawner.ensureRunning() else {
            throw SendError(message: "Node 或后端缓存未就绪：请先从 DSH Desktop 正常启动一次后端。")
        }
        var body: [String: Any] = ["text": text]
        if let cwd { body["cwd"] = cwd }
        if let provider { body["provider"] = provider }
        if let model { body["model"] = model }
        if let reasoning { body["reasoning"] = reasoning }

        guard let url = URL(string: "http://127.0.0.1:3080/api/mini/session.new") else {
            throw SendError(message: "内部 URL 构造失败")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let decoded = try? JSONDecoder().decode(SessionResponse.self, from: data),
              let statusCode = (response as? HTTPURLResponse)?.statusCode else {
            throw SendError(message: "后端响应无法解析")
        }
        guard statusCode == 200, decoded.ok, let sessionId = decoded.sessionId else {
            throw SendError(message: decoded.error ?? "HTTP \(statusCode)")
        }
        if let focusURL = URL(string: "http://127.0.0.1:3080/api/mini/focus") {
            var focusRequest = URLRequest(url: focusURL)
            focusRequest.httpMethod = "POST"
            focusRequest.timeoutInterval = 5
            focusRequest.cachePolicy = .reloadIgnoringLocalCacheData
            focusRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            focusRequest.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": sessionId])
            _ = try? await URLSession.shared.data(for: focusRequest)
        }
        return sessionId
    }

    private func openMainAppForTransition() async throws {
        let candidates = [
            URL(fileURLWithPath: "/Applications/DSH Desktop.app"),
            URL(fileURLWithPath: "\(NSHomeDirectory())/Applications/DSH Desktop.app"),
        ]
        guard let appURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw SendError(message: "找不到 DSH Desktop.app")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    }

    private func showHint(_ text: String, error: Bool) {
        hintLabel?.stringValue = text
        hintLabel?.textColor = error ? .systemOrange : .secondaryLabelColor
        hintLabel?.isHidden = text.isEmpty     // 空提示彻底隐藏（R3：残留引号根因）
    }

    // MARK: - 消散（R2 修正：失 key 即收 + Esc 兜底）

    private func installMonitorsIfNeeded() {
        guard monitors.isEmpty else { return }
        // 标准 Excel：点击外部/切换应用 → 面板失 key → 收起（菜单跟踪期间不触发）
        if let panel {
            // selector 式：通知投递线程同步回调，守卫时序不依赖主队列排空（审查 P2-2）
            NotificationCenter.default.addObserver(self,
                selector: #selector(panelDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification, object: panel)
        }
        // Esc 兜底（resignKey 不覆盖按键场景）
        let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isVisible == true, event.keyCode == 53,
                  self.menuInteraction == 0, NSApp.modalWindow == nil else { return event }
            self.dismiss()
            return nil
        }
        if let key { monitors.append(key) }
    }

    @objc private func panelDidResignKey(_ note: Notification) {
        guard dismissing == false, menuInteraction == 0, panel?.isVisible == true else { return }
        dismiss()
    }

    private func removeMonitorsIfNeeded() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
        NotificationCenter.default.removeObserver(self,
            name: NSWindow.didResignKeyNotification, object: nil)
    }
}

/// 菜单行视图：hover 高亮（R4：菜单能点但无悬浮反馈），深浅色自适应
private final class MenuRowView: NSView {
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        wantsLayer = true
        layer?.backgroundColor = hoverColor.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    private var hoverColor: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.08)
                : NSColor.black.withAlphaComponent(0.06)
        }
    }
}

/// 自适应输入框：换行即撑高（回调重排），无修饰回车发送
private final class PillTextView: NSTextView {
    var placeholder: String = "" { didSet { needsDisplay = true } }
    var onSend: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty && window?.firstResponder !== self {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            (placeholder as NSString).draw(
                at: NSPoint(x: textContainerOrigin.x + 2, y: textContainerOrigin.y + 3),
                withAttributes: attrs
            )
        }
    }

    override var acceptsFirstResponder: Bool { true }

    /// 内容实际高度（供胶囊生长计算）
    func contentSize() -> CGRect {
        guard let layoutManager, let textContainer else {
            return CGRect(x: 0, y: 0, width: frame.width, height: 22)
        }
        // NSLayoutManager 惰性布局：不 ensureLayout 时 usedRect 是旧值
        // （R7：打满一行要再打 20+ 字符才碰巧触发展开的根因）
        layoutManager.ensureLayout(for: textContainer)
        return layoutManager.usedRect(for: textContainer)
    }

    override func insertNewline(_ sender: Any?) {
        if !NSEvent.modifierFlags.contains(.shift) {
            onSend?()
            return
        }
        super.insertNewline(sender)
    }
}
