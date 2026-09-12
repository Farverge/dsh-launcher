import AppKit

/// 一键体检窗口（对齐卡卡2 定稿规格 + alpha 时代扩展）：
/// - 独立小窗，可拖动，非模态——主应用/后端照常使用，体检只读
/// - 深色 #1E1E1E 底，Menlo 13pt；标题灰白 / 通过绿 #4CAF50 / 告警黄 / 失败红
/// - 结果"逐行即时刷出"（用户拍板的像素风格进度）：每完成一项检测立刻滚出
///   一行 `[✓|!|✗] 名称 数值`，按真实检测结果推进，不做预渲染假进度
/// - 检查维度（全只读）：系统 / Node / 应用签名 / 端口身份 / 后端通道形态
///   （稳定通道 200=健康 · alpha 认证链 401+文案=健康）/ 桥接接口 / norm 协议层
///   （dsh-plugin-norm caps 路由，免认证）/ profile 工作区装配（alpha.3 白屏坑）/
///   mini-dialog 版本 / npx 副本 / 缓存体量
/// - 报告头「版本方框」：检测流开跑前先盘点前端（dsh-macos）/ 后端 dsh / 已装家族插件
///   的版本（box-drawing 字符；右侧竖线像素级闭合，两列表头「项目/本地版本号」，版本号
///   右对齐 + `·` 点线导引；逐项 fail-soft，取不到的行整行不显示，一项都取不到则整个方框
///   不显示）。有独立发布仓的家族插件并发拉 GitHub latest release 做轻量 semver 比对：
///   落后 → 该行黄色 + 行尾「（可更新）」；无法判定（无 release/超时/失败）→ 正常白灰
///   不误报。插件运行错误（norm caps 探针失败 / mini-dialog 检查 ✗）在检测流出结论后
///   回填刷新为红色行
/// - 动作按钮（体检完成后按结果出现，用户点按才执行，绝不在体检过程中自动执行）：
///   释放 npm 缓存（`npm cache clean --force`）、打开 npx 目录（Finder）、一键更新插件
///   （逐个执行放行的安装命令，完成后自动重新体检）、重新体检
/// - 安全红线：体检全只读；动作仅限白名单（npm cache clean / NSWorkspace.open /
///   `dsh plugin --profile web add https://github.com/iiiiiei/dsh-plugin-norm` 仅此一条
///   命令形态），绝不自动删目录、绝不杀任何既有进程（超时强杀仅针对我们自起的短命命令进程）
final class CheckupWindowController {
    static let shared = CheckupWindowController()

    private var window: NSWindow?
    private var textView: NSTextView?
    private var rerunButton: NSButton?
    private var cleanCacheButton: NSButton?
    private var openNpxButton: NSButton?
    private var updatePluginsButton: NSButton?
    /// 体检代次：点「重新体检」时自增；上一轮流线回来发现代次不符即静默退出，
    /// 防止两轮流交错刷屏
    private var checkupGeneration = 0

    // 终端配色（卡2 定稿）
    private let bgColor = NSColor(red: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0, alpha: 1)
    private let passColor = NSColor(red: 0x4C / 255.0, green: 0xAF / 255.0, blue: 0x50 / 255.0, alpha: 1)
    private let warnColor = NSColor(red: 0xFF / 255.0, green: 0xC1 / 255.0, blue: 0x07 / 255.0, alpha: 1)
    private let failColor = NSColor(red: 0xE5 / 255.0, green: 0x53 / 255.0, blue: 0x5A / 255.0, alpha: 1)
    private let titleColor = NSColor(white: 0.85, alpha: 1)

    /// 汇总报告（复制给 agent 时可直接粘贴）
    private var reportLines: [String] = []

    /// 版本方框可回填行的屏幕区间（按行身份索引；回填改色一次后即清除）
    private var boxRowRanges: [BoxRowKind: NSRange] = [:]
    /// 本轮体检判定「落后」的插件名（驱动「一键更新插件」按钮的出现）
    private var outdatedPluginNames: [String] = []

    func show() {
        if window == nil { buildWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        runCheckup()
    }

    // MARK: - 突体与输出

    private func buildWindow() {
        // 底部按钮行最多 6 枚（3 动作 + 重新体检/复制报告/关闭），窗口加宽到 768 保证不挤压
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 768, height: 400),
            styleMask: [.titled, .closable, .resizable],   // 真机反馈：字号加大＋窗口可拉伸
            backing: .buffered,
            defer: false
        )
        win.title = "DSH Launcher · 一键体检"
        win.backgroundColor = bgColor
        win.isMovableByWindowBackground = true
        // 不再悬浮置顶（与确认窗同款取舍）：早期设计是"浮在主应用之上对照读数"，
        // 但动作按钮会把工作交接给 Finder/终端，置顶恰好挡住交接目标。
        // makeKeyAndOrderFront 仍保证打开时到最前，此后遵循常规窗口层级。
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 748, height: 320)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 752, height: 350))
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        let scroll = NSScrollView(frame: NSRect(x: 6, y: 40, width: 756, height: 352))
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        // 底部按钮行（从右往左）：[关闭][复制报告][重新体检] ← 动作按钮区（动态） ← 弹性空隙
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        closeButton.frame = NSRect(x: 658, y: 8, width: 104, height: 26)
        closeButton.autoresizingMask = [.minXMargin]
        let copyButton = NSButton(title: "复制报告", target: self, action: #selector(copyReport))
        copyButton.bezelStyle = .rounded
        copyButton.frame = NSRect(x: 546, y: 8, width: 104, height: 26)
        copyButton.autoresizingMask = [.minXMargin]
        let rerunButton = NSButton(title: "重新体检", target: self, action: #selector(rerunCheckup))
        rerunButton.bezelStyle = .rounded
        rerunButton.toolTip = "清空报告并重新体检"
        rerunButton.frame = NSRect(x: 434, y: 8, width: 104, height: 26)
        rerunButton.autoresizingMask = [.minXMargin]
        let cleanCacheButton = NSButton(title: "释放 npm 缓存", target: self, action: #selector(cleanNpmCache))
        cleanCacheButton.bezelStyle = .rounded
        cleanCacheButton.toolTip = "执行 npm cache clean --force（只清 _cacache，不动 _npx 副本目录）"
        cleanCacheButton.frame = NSRect(x: 174, y: 8, width: 124, height: 26)
        cleanCacheButton.autoresizingMask = [.minXMargin]
        cleanCacheButton.isHidden = true   // 体检完成后按结果出现
        let openNpxButton = NSButton(title: "打开 npx 目录", target: self, action: #selector(openNpxDir))
        openNpxButton.bezelStyle = .rounded
        openNpxButton.toolTip = "在 Finder 中打开 ~/.npm/_npx"
        openNpxButton.frame = NSRect(x: 48, y: 8, width: 118, height: 26)
        openNpxButton.autoresizingMask = [.minXMargin]
        openNpxButton.isHidden = true      // 体检完成后按结果出现
        let updatePluginsButton = NSButton(title: "一键更新插件", target: self, action: #selector(updateOutdatedPlugins))
        updatePluginsButton.bezelStyle = .rounded
        updatePluginsButton.toolTip = "对检测到落后的家族插件逐个执行放行的安装命令（dsh plugin --profile web add <GitHub 仓库>），完成后自动重新体检"
        updatePluginsButton.frame = NSRect(x: 44, y: 8, width: 124, height: 26)
        updatePluginsButton.autoresizingMask = [.minXMargin]
        updatePluginsButton.isHidden = true   // 版本方框检出「落后且有放行安装命令」的插件时出现

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 768, height: 400))
        content.addSubview(scroll)
        content.addSubview(closeButton)
        content.addSubview(copyButton)
        content.addSubview(rerunButton)
        content.addSubview(cleanCacheButton)
        content.addSubview(openNpxButton)
        content.addSubview(updatePluginsButton)
        win.contentView = content

        self.window = win
        self.textView = textView
        self.rerunButton = rerunButton
        self.cleanCacheButton = cleanCacheButton
        self.openNpxButton = openNpxButton
        self.updatePluginsButton = updatePluginsButton
    }

    private func append(line: NSAttributedString) {
        guard let textView else { return }
        if textView.string.isEmpty {
            textView.textStorage?.append(line)
        } else {
            textView.textStorage?.append(NSAttributedString(string: "\n"))
            textView.textStorage?.append(line)
        }
        textView.scrollRangeToVisible(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    private func attributed(_ text: String, color: NSColor,
                            style: NSParagraphStyle? = nil) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            // 真机反馈：11pt 看不清，加大到 13pt
            .font: NSFont(name: "Menlo", size: 13)
                ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: color,
        ]
        if let style { attributes[.paragraphStyle] = style }
        return NSAttributedString(string: text, attributes: attributes)
    }

    @objc private func closeWindow() { window?.orderOut(nil) }

    @objc private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reportLines.joined(separator: "\n"), forType: .string)
    }

    // MARK: - 体检流水线（只读）

    private struct Result {
        let mark: String      // ✓ / ! / ✗
        let name: String
        let value: String
        let color: NSColor
        var advice: String? = nil
    }

    /// 检测行三列对齐（2026-09-12 用户定稿）：标记 / 名称 / 冒号各占一列，全部左
    /// 制表位绝对定位——标记 ✓!✗ 宽度不一、名称长短不齐都不再牵动冒号位置。
    /// 列宽按全部检查名静态测算；改名/加项时同步维护 checkNameList。
    private static let checkNameList = [
        "操作系统", "Node", "应用签名", "端口身份", "后端通道", "桥接接口",
        "norm 协议", "mini 对话框", "profile 装配", "npx 副本", "缓存体量",
    ]
    private static let resultMarkStopPx: CGFloat =
        max(pixelWidth("[✓]"), pixelWidth("[!]"), pixelWidth("[✗]")) + pixelWidth(" ")
    private static let resultColonStopPx: CGFloat =
        resultMarkStopPx + (checkNameList.map { pixelWidth($0) }.max() ?? 0) + pixelWidth(" ")
    private static let resultListStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.tabStops = [
            NSTextTab(textAlignment: .left, location: resultMarkStopPx, options: [:]),
            NSTextTab(textAlignment: .left, location: resultColonStopPx, options: [:]),
        ]
        return style
    }()

    /// 后端通道形态（根路径探测结论）。alpha 认证链形态属健康：根路径 401 + 固定文案。
    private enum ChannelForm {
        case stable       // 稳定通道：根路径 200
        case alphaAuth    // alpha 认证链：根路径 401 + `dsh web authentication required`
        case notReady     // 在线但路由未就绪（404）
        case unknown      // 其他状态码 / 超时 / 连接异常
    }

    private func runCheckup() {
        checkupGeneration += 1
        let generation = checkupGeneration
        reportLines.removeAll()
        boxRowRanges.removeAll()
        outdatedPluginNames = []
        cleanCacheButton?.isHidden = true
        openNpxButton?.isHidden = true
        updatePluginsButton?.isHidden = true
        cleanCacheButton?.isEnabled = true
        openNpxButton?.isEnabled = true
        updatePluginsButton?.isEnabled = true
        guard let textView else { return }
        textView.string = ""
        append(line: attributed("── DSH Launcher 体检 ──", color: titleColor))

        Task { @MainActor in
            // 报告头·版本方框：先于检测流取数并渲染（本地只读为主，逐项 fail-soft，
            // 失败绝不影响后续体检）。方框行同步进 reportLines，复制报告时一并带上。
            // 落后检测（GitHub，2s 超时）在方框渲染时已出结论（黄色+（可更新））；
            // 插件运行错误等检测流出结论后回填刷新为红色（markBoxRowFailed）。
            let box = await Self.buildVersionBox()
            guard generation == self.checkupGeneration else { return }
            if let box {
                self.appendVersionBox(box)
                self.outdatedPluginNames = box.outdatedNames

            }
            var advices: [String] = []
            for await result in Self.checkAll() {
                guard generation == self.checkupGeneration else { return }
                // 名称去掉旧式对齐尾随空格，三列交给制表位
                let name = result.name.trimmingCharacters(in: .whitespaces)
                self.append(line: self.attributed(
                    "[\(result.mark)]\t\(name)\t：\(result.value)",
                    color: result.color, style: Self.resultListStyle))
                // 纯文本行无制表位语义：名字补空格近似到冒号列
                var plainName = name
                while Self.pixelWidth("[\(result.mark)] \(plainName)") < Self.resultColonStopPx {
                    plainName += " "
                }
                self.reportLines.append("[\(result.mark)] \(plainName)：\(result.value)")
                if let kind = Self.boxErrorKind(for: result) { self.markBoxRowFailed(kind) }
                if let advice = result.advice { advices.append(advice) }
            }
            guard generation == self.checkupGeneration else { return }
            self.append(line: self.attributed("── 建议 ──", color: self.titleColor))
            if advices.isEmpty {
                self.append(line: self.attributed("一切正常。", color: self.passColor))
                self.reportLines.append("advice: none")
            } else {
                for a in advices {
                    self.append(line: self.attributed("· \(a)", color: self.warnColor))
                    self.reportLines.append("advice: \(a)")
                }
            }
            self.append(line: self.attributed("── 完 ──", color: self.titleColor))
            self.refreshActionButtons(advices: advices)
            // 【边框校准】真机 textView 右制表位落位带 ±1/3 格量化残差（随填充
            // 尾端浮动；离线同引擎复刻不出）。放在全文落定之后——后续无追加、
            // 无重排，校准结果稳定。读实际 │┐┘ 落位，按行右移停靠位对齐到最大列
            // （只右移永保整段富余），循环至收敛（上限 3 拍）
            self.calibrateBoxBorders()
        }
    }

    /// 逐项检测流：每项真实执行完才 yield 一条，窗口即刻滚出该行。
    /// 顺序：端口身份 → 后端通道 → 桥接接口 → norm 协议 → mini-dialog → profile 装配
    /// → npx 副本 → 缓存体量。后端未监听时跳过所有需要后端的项（避免重复报错刷屏），
    /// 纯本地只读项（mini-dialog / profile / npx / 缓存）照常检查。
    private nonisolated static func checkAll() -> AsyncStream<Result> {
        AsyncStream { continuation in
            Task { @MainActor in
                continuation.yield(CheckupWindowController.checkMacOS())
                continuation.yield(await CheckupWindowController.checkNode())
                continuation.yield(await CheckupWindowController.checkAppSignature())
                let port = await CheckupWindowController.checkPortIdentity()
                continuation.yield(port)
                if port.mark == "✓" {
                    // 后端在线：通道形态感知 → 桥接 → norm → 插件 → profile
                    let channel = await CheckupWindowController.checkBackendChannel()
                    continuation.yield(channel.result)
                    let bridge = await CheckupWindowController.checkBridgeEndpoint(channel: channel.form)
                    continuation.yield(bridge.result)
                    continuation.yield(await CheckupWindowController.checkNormCaps())
                    continuation.yield(await CheckupWindowController.checkMiniDialog())
                    continuation.yield(await CheckupWindowController.checkProfileWorkspace(
                        backendOnline: true, backendVersion: bridge.version))
                } else {
                    // 后端未运行：跳过需要后端的项（灰色跳过行，不重复刷红）
                    continuation.yield(CheckupWindowController.skip(name: "后端通道 ", reason: "后端未运行"))
                    continuation.yield(CheckupWindowController.skip(name: "桥接接口 ", reason: "后端未运行"))
                    continuation.yield(CheckupWindowController.skip(name: "norm 协议 ", reason: "后端未运行"))
                    // 以下为纯本地只读项，不需要后端
                    continuation.yield(await CheckupWindowController.checkMiniDialog())
                    continuation.yield(await CheckupWindowController.checkProfileWorkspace(
                        backendOnline: false, backendVersion: nil))
                }
                continuation.yield(await CheckupWindowController.checkNPXCopies())
                continuation.yield(await CheckupWindowController.checkCacheBulk())
                continuation.finish()
            }
        }
    }

    // MARK: 各项检测实现

    private static func checkMacOS() -> Result {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let text = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        return Result(mark: "✓", name: "操作系统 ", value: text, color: .init(white: 0.78, alpha: 1))
    }

    /// 跑一条只读命令并拿合并输出（stdout+stderr 同管——注意 codesign -dv 这类工具把
    /// 报文写在 stderr！）。超时强杀仅针对我们自起的短命进程，不属于"杀进程"范畴。
    private static func runCapture(_ launchPath: String, _ args: [String], timeout: TimeInterval = 4) async -> String? {
        let outcome = await runProcess(launchPath, args, timeout: timeout)
        return outcome.ran ? outcome.text : nil
    }

    /// 跑一条命令：返回（是否成功启动、退出是否成功、合并输出/错误描述）。
    /// 成功判定 = 进程真的跑起来 且 退出码为 0 且未超时。
    private static func runProcess(_ launchPath: String, _ args: [String], timeout: TimeInterval)
        async -> (ran: Bool, ok: Bool, text: String?) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = args
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe   // 合并流：stderr 类工具（codesign -dv）的报文在这里
                do {
                    try process.run()
                    let deadline = Date().addingTimeInterval(timeout)
                    while process.isRunning && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.02)
                    }
                    if process.isRunning {
                        process.terminate()
                        // 宽限 1 秒；仍不退则 SIGKILL，保证管道写端必然关闭、下面的读不会永久阻塞
                        let graceDeadline = Date().addingTimeInterval(1)
                        while process.isRunning && Date() < graceDeadline {
                            Thread.sleep(forTimeInterval: 0.02)
                        }
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let out = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let ok = process.terminationStatus == 0
                    cont.resume(returning: (true, ok, (out?.isEmpty == false) ? out : nil))
                } catch {
                    cont.resume(returning: (false, false, error.localizedDescription))
                }
            }
        }
    }

    private static func checkNode() async -> Result {
        for nodePath in ["/opt/homebrew/bin/node", "/usr/local/bin/node"] {
            guard FileManager.default.fileExists(atPath: nodePath) else { continue }
            if let version = await runCapture(nodePath, ["--version"]) {
                return Result(mark: "✓", name: "Node      ", value: "\(version) · \(nodePath)",
                              color: nodeGreen)
            }
        }
        return Result(mark: "✗", name: "Node      ", value: "未找到（/opt/homebrew/bin、/usr/local/bin 都没有）",
                      color: nodeRed,
                      advice: "缺少 Node.js。DSH 后端依赖它——运行安装命令可自动补齐环境。")
    }

    /// 主应用路径候选（与 launcher 启动逻辑同源；找不到就跳过该项而非报错）
    private static var mainAppURL: URL? {
        [
            URL(fileURLWithPath: "/Applications/DSH Desktop.app"),
            URL(fileURLWithPath: "\(NSHomeDirectory())/Applications/DSH Desktop.app"),
        ].first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func checkAppSignature() async -> Result {
        guard let app = mainAppURL,
              FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign") else {
            return Result(mark: "!", name: "应用签名 ", value: "主应用不存在，跳过", color: warnColor)
        }
        // -dv 输出 Signature=adhoc / TeamIdentifier 等，全部只读
        let output = await runCapture("/usr/bin/codesign", ["-dv", app.path])
        guard let output else {
            return Result(mark: "✗", name: "应用签名 ", value: "codesign 校验失败", color: nodeRed,
                          advice: "应用签名无法读取，建议重新走一遍安装命令。")
        }
        let line = output.components(separatedBy: CharacterSet.newlines)
            .first { $0.contains("Signature=") }?
            .trimmingCharacters(in: CharacterSet.whitespaces) ?? "?"
        if line.contains("adhoc") {
            return Result(mark: "!", name: "应用签名 ", value: "ad-hoc（\(line)）", color: warnColor,
                          advice: "当前为 ad-hoc 固定签名：本机够用，他机首次打开需右键 → 打开绕过 Gatekeeper。")
        }
        return Result(mark: "✓", name: "应用签名 ", value: line, color: nodeGreen)
    }

    /// 端口身份：谁在监听 3080（lsof 只读查询，输入即本机回环端口）
    private static func checkPortIdentity() async -> Result {
        guard let lsof = firstExecutable(["/usr/sbin/lsof", "/usr/bin/lsof"]) else {
            return Result(mark: "!", name: "端口身份 ", value: "系统无 lsof，跳过", color: warnColor)
        }
        let output = await runCapture(lsof, ["-iTCP:3080", "-sTCP:LISTEN", "-P", "-n"])
        guard let output, !output.isEmpty else {
            return Result(mark: "✗", name: "端口身份 ", value: "127.0.0.1:3080 无监听进程（后端未运行）",
                          color: nodeRed,
                          advice: "后端没在跑。迷你框发送时会代为拉起；手动启动请开 DSH Desktop 设置页。")
        }
        let secondLine = output.components(separatedBy: CharacterSet.newlines).dropFirst().first ?? output
        return Result(mark: "✓", name: "端口身份 ", value: "127.0.0.1:3080 ← \(secondLine)", color: nodeGreen)
    }

    /// 后端通道：GET 根路径读状态码 + body 前缀，感知认证链/通道形态。
    /// 稳定通道 200 = 健康；alpha 认证链 401 + `dsh web authentication required` = 健康；
    /// 404 = 在线但路由未就绪（刚启动）；其余与端口身份建议呼应。
    private static func checkBackendChannel() async -> (result: Result, form: ChannelForm) {
        guard let url = URL(string: "http://127.0.0.1:3080/") else {
            return (Result(mark: "✗", name: "后端通道 ", value: "URL 构造失败", color: nodeRed), .unknown)
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            request.cachePolicy = .reloadIgnoringLocalCacheData   // 形态判定绝不吃本地缓存
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let bodyPrefix = String(data: data.prefix(2048), encoding: .utf8)?.lowercased() ?? ""
            if code == 200 {
                return (Result(mark: "✓", name: "后端通道 ", value: "在线 · 稳定通道形态", color: nodeGreen), .stable)
            }
            if code == 401, bodyPrefix.contains("dsh web authentication required") {
                return (Result(mark: "✓", name: "后端通道 ",
                               value: "在线 · alpha 认证链形态 · 健康", color: nodeGreen), .alphaAuth)
            }
            if code == 404 {
                return (Result(mark: "!", name: "后端通道 ",
                               value: "在线但路由未就绪 · 后端刚启动？稍后重测", color: warnColor), .notReady)
            }
            return (Result(mark: "!", name: "后端通道 ", value: "根路径 HTTP \(code) · 形态未知", color: warnColor,
                           advice: "端口有监听但通道形态无法识别，请与上方「端口身份」对照确认监听者；稍后可点「重新体检」。"),
                    .unknown)
        } catch {
            return (Result(mark: "!", name: "后端通道 ",
                           value: "根路径探测失败（\(error.localizedDescription)）", color: warnColor,
                           advice: "端口有监听但根路径无响应，请与上方「端口身份」对照确认监听者；迷你框发送时会代为拉起后端。"),
                    .unknown)
        }
    }

    /// 桥接接口：桌面桥插件的健康报文校验（与 StatusProbe 同一数据源，双确认）。
    /// version 随结果传出，供「profile 装配」的修复命令取后端版本。
    /// alpha 认证链形态下桥接口若被认证链拦下（非 200），属预期内形态，不再误导为插件故障。
    private static func checkBridgeEndpoint(channel: ChannelForm) async -> (result: Result, version: String?) {
        guard let url = URL(string: "http://127.0.0.1:3080/api/desktop/status") else {
            return (Result(mark: "✗", name: "桥接接口 ", value: "URL 构造失败", color: nodeRed), nil)
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            request.cachePolicy = .reloadIgnoringLocalCacheData   // 状态判定绝不吃本地缓存
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["ok"] as? Bool == true else {
                if channel == .alphaAuth {
                    return (Result(mark: "!", name: "桥接接口 ",
                                   value: "HTTP \(code) · alpha 认证链形态下受保护（预期内）", color: warnColor), nil)
                }
                return (Result(mark: "!", name: "桥接接口 ", value: "有响应但报文异常（HTTP \(code)）", color: warnColor,
                               advice: "桥接插件的 status 报文不符合预期，可能插件未装配——重装命令可修复。"), nil)
            }
            let version = obj["version"] as? String
            let pid = obj["pid"] as? Int ?? 0
            return (Result(mark: "✓", name: "桥接接口 ",
                           value: "ok · dsh v\(version ?? "?") · pid \(pid)",
                           color: nodeGreen),
                    (version?.isEmpty == false && version != "?") ? version : nil)
        } catch {
            return (Result(mark: "✗", name: "桥接接口 ",
                           value: "不可达（\(error.localizedDescription)）", color: nodeRed), nil)
        }
    }

    /// norm 协议层：dsh-plugin-norm 是家族漂移屏蔽层，caps 路由免认证。
    /// 200 → 报 norm 版本 / 探测计数 / 降级清单；404 或连接失败 → 未部署（跳转通道降级）。
    private static func checkNormCaps() async -> Result {
        guard let url = URL(string: "http://127.0.0.1:3080/api/dsh-plugin-norm/caps") else {
            return Result(mark: "✗", name: "norm 协议 ", value: "URL 构造失败", color: nodeRed)
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            request.cachePolicy = .reloadIgnoringLocalCacheData
            // 【后端刚重启的未就绪窗口】norm 插件的路由注册晚于端口监听——此刻探测
            // 会拿到 401（认证栅栏先于插件路由生效），与"真的没部署"无法区分。
            // 短间隔重试（最多 5 次、累计 ~6s）后仍非 200/401 才下结论：
            // 200=已部署；401=认证链在而 caps 路由未注册（真·未部署或加载失败）。
            var code = 0
            var data = Data()
            for attempt in 0..<5 {
                if let (chunk, resp) = try? await URLSession.shared.data(for: request) {
                    data = chunk
                    code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                } else {
                    code = 0
                }
                if code == 200 || code == 401 { break }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
            guard code == 200 else {
                let text = code == 401
                    ? "norm 未加载（HTTP 401；会话跳转通道降级；部署方法见 wiki）"
                    : "异常（HTTP \(code)；部署方法见 wiki）"
                return Result(mark: "!", name: "norm 协议 ", value: text, color: warnColor)
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return Result(mark: "!", name: "norm 协议 ", value: "caps 报文非 JSON（版本过旧？）", color: warnColor)
            }
            let version = obj["norm"] as? String ?? "?"
            let degradedRaw = obj["degraded"] as? [Any] ?? []
            let host = (obj["caps"] as? [String: Any])?["host"] as? [String: Any]
            // probes 是字典（{"ctx.agents": {ok:…}, …}）：ok 数 / 总数
            let probesDict = host?["probes"] as? [String: Any]
            let probeTotal = probesDict?.count ?? 0
            let probeOk = probesDict?.values.filter {
                ($0 as? [String: Any])?["ok"] as? Bool == true
            }.count ?? 0
            let probeText = probeTotal > 0 ? "探测 \(probeOk)/\(probeTotal)" : "探测 ?/4"
            if degradedRaw.isEmpty {
                return Result(mark: "✓", name: "norm 协议 ",
                              value: "norm \(version) · \(probeText) · 降级无", color: nodeGreen)
            }
            let labels = degradedRaw.map { item -> String in
                if let s = item as? String { return s }
                if let d = item as? [String: Any] {
                    return (d["name"] as? String) ?? (d["plugin"] as? String) ?? (d["reason"] as? String) ?? "?"
                }
                return "?"
            }
            return Result(mark: "!", name: "norm 协议 ",
                          value: "norm \(version) · \(probeText) · 降级 \(labels.joined(separator: "、"))",
                          color: warnColor)
        } catch {
            return Result(mark: "!", name: "norm 协议 ",
                          value: "未部署（连接失败；会话跳转通道降级；部署方法见 wiki）", color: warnColor)
        }
    }

    /// mini-dialog 版本：读 package.json。≥0.2.0 focus 走 norm；旧版自带 WS 通道建议升级。
    /// 部署位以内外层区分：内层 web/node_modules 是设计部署位；只在旧外层
    /// profiles/node_modules 探到包 = 双树异常（壳旧版铺错位），单独警示而非当版本报。
    private static func checkMiniDialog() async -> Result {
        let innerPkg = NSHomeDirectory() + "/.dsh/profiles/web/node_modules/dsh-mini-dialog/package.json"
        let outerPkg = NSHomeDirectory() + "/.dsh/profiles/node_modules/dsh-mini-dialog/package.json"
        // 读部署副本的 version（packageVersion 统一 fail-soft：缺失/损坏返回 nil）
        // 内层缺席而外层在场：报外层陈旧副本的存在，提示迁移而非假装已安装
        if let outer = packageVersion(at: outerPkg), packageVersion(at: innerPkg) == nil {
            return Result(mark: "!", name: "mini 对话框",
                          value: "\(outer) 在外层旧树 · imports 有解析到旧模块风险 · 重跑 launcher 一键安装迁至内层",
                          color: warnColor)
        }
        guard let version = packageVersion(at: innerPkg) else {
            return Result(mark: "!", name: "mini 对话框", value: "未安装 · launcher 一键安装可补", color: warnColor)
        }
        guard let semver = parseVersion(version) else {
            return Result(mark: "!", name: "mini 对话框",
                          value: "\(version) · 版本无法解析，建议升级 0.2.0+", color: warnColor)
        }
        if semver >= (0, 2, 0) {
            return Result(mark: "✓", name: "mini 对话框", value: "\(version) · focus 走 norm", color: nodeGreen)
        }
        return Result(mark: "!", name: "mini 对话框",
                      value: "\(version) · 旧版自带 WS 通道 · 建议升级 0.2.0+ 并部署 norm", color: warnColor)
    }

    /// profile 工作区装配（alpha.3 白屏坑）：0.1.2-alpha 起 GUI 装配在 pnpm 工作区
    /// `~/.dsh/profiles/web/`，缺失则 GUI 白屏。后端在线缺失直接红；离线缺失给黄色预警。
    private static func checkProfileWorkspace(backendOnline: Bool, backendVersion: String?) async -> Result {
        let webAppRoot = NSHomeDirectory() + "/.dsh/profiles/web/node_modules/@deepseek-ai/dsh-web-app"
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: webAppRoot, isDirectory: &isDir), isDir.boolValue {
            return Result(mark: "✓", name: "profile 装配", value: "已装配 · GUI 可启动", color: nodeGreen)
        }
        let version = backendVersion ?? "<后端版本>"
        var fix = "修复：cd ~/.dsh/profiles/web && pnpm add "
                  + "@deepseek-ai/dsh-base@\(version) @deepseek-ai/dsh-web-app@\(version)"
        if backendVersion == nil { fix += "（后端版本待在线后重测获取）" }
        if backendOnline {
            return Result(mark: "✗", name: "profile 装配", value: "未装配 · GUI 将白屏", color: nodeRed, advice: fix)
        }
        return Result(mark: "!", name: "profile 装配",
                      value: "未装配 · 后端未运行 · GUI 启动前需装配，否则白屏", color: warnColor, advice: fix)
    }

    /// npx 副本数：数 ~/.npm/_npx 下装着 @deepseek-ai/dsh 的缓存目录个数。
    /// 多副本不算故障（resolveCommand 六级兜底正是为此设计），只占磁盘——
    /// `npm cache clean` 清的是 _cacache、不碰 _npx，所以建议只指向两个动作按钮，绝不暗示"收敛"。
    private static func checkNPXCopies() async -> Result {
        let npxRoot = NSHomeDirectory() + "/.npm/_npx"
        var copies = 0
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: npxRoot) {
            for entry in entries {
                let probe = npxRoot + "/" + entry + "/node_modules/@deepseek-ai/dsh"
                if FileManager.default.fileExists(atPath: probe) { copies += 1 }
            }
        }
        // profile 装配探测：alpha 起 pnpm 工作区路径 profiles/web/... 为主，
        // 旧布局 profiles/node_modules/... 保留识别，任一存在即"profile 内有安装版"
        let profileDeployed =
            FileManager.default.fileExists(
                atPath: NSHomeDirectory() + "/.dsh/profiles/web/node_modules/@deepseek-ai/dsh")
            || FileManager.default.fileExists(
                atPath: NSHomeDirectory() + "/.dsh/profiles/node_modules/@deepseek-ai/dsh")
        if copies == 0 {
            if profileDeployed {
                return Result(mark: "✓", name: "npx 副本  ",
                              value: "npx 缓存 0 份 · profile 内有安装版 · 干净", color: nodeGreen)
            }
            return Result(mark: "✗", name: "npx 副本  ", value: "未发现 @deepseek-ai/dsh 缓存", color: nodeRed,
                          advice: "后端尚未经 npx 安装过；第一次启动主应用会自动完成。")
        }
        let profileNote = profileDeployed ? " · profile 内另有安装版" : ""
        if copies > 1 {
            return Result(mark: "!", name: "npx 副本  ", value: "发现 \(copies) 份 @deepseek-ai/dsh 缓存\(profileNote)", color: warnColor,
                          advice: "多副本无害（解析链自动选活跃副本），仅占磁盘。如需释放空间点下方「释放 npm 缓存」；如需手动清点副本点「打开 npx 目录」。")
        }
        return Result(mark: "✓", name: "npx 副本  ", value: "恰好 1 份 · 健康\(profileNote)", color: nodeGreen)
    }

    /// 失效缓存体量：_npx 与 _cacache 的粗粒度只读统计（du），超过阈值给建议
    private static func checkCacheBulk() async -> Result {
        guard let du = firstExecutable(["/usr/bin/du"]) else {
            return Result(mark: "!", name: "缓存体量 ", value: "系统无 du，跳过", color: warnColor)
        }
        let npxRoot = NSHomeDirectory() + "/.npm"
        guard FileManager.default.fileExists(atPath: npxRoot) else {
            return Result(mark: "!", name: "缓存体量 ", value: "无 ~/.npm，跳过", color: warnColor)
        }
        let output = await runCapture(du, ["-sh", npxRoot])
        guard let output else {
            return Result(mark: "!", name: "缓存体量 ", value: "统计失败，跳过", color: warnColor)
        }
        let size = output.components(separatedBy: CharacterSet(charactersIn: "\t")).first ?? "?"
        if size.hasSuffix("G") {
            return Result(mark: "!", name: "缓存体量 ", value: "~/.npm 共 \(size)", color: warnColor,
                          advice: "npm 缓存较大。如需释放空间：`npm cache clean --force`（不影响已安装的后端）。")
        }
        return Result(mark: "✓", name: "缓存体量 ", value: "~/.npm 共 \(size)", color: nodeGreen)
    }

    // MARK: - 版本方框（报告头）

    /// 方框里盘点的家族插件目录：只显示真实在位的，未安装的不显示（用户定稿口径）
    private static let boxPluginNames = [
        "dsh-theme-sdk", "dsh-plugin-norm", "dsh-mini-dialog", "dsh-l10n-zh", "dsh-theme-grok",
    ]

    /// 有独立 GitHub 发布仓的家族插件（落后检测只查这些；其余无发布仓，不检不上色）。
    /// 主题仓没有 release 时 latest 接口 404 → 视为无法判定，不上色不误报
    private static let pluginReleaseRepos = [
        "dsh-plugin-norm": "iiiiiei/dsh-plugin-norm",
        "dsh-theme-grok": "iiiiiei/dsh-theme-grokbot",
    ]

    /// 方框行身份（检测流出结论后按它回填定位屏幕区间）
    private enum BoxRowKind: Hashable {
        case shell
        case backend
        case plugin(String)
    }

    /// 方框一行：项目名左对齐、版本号（含后缀）右对齐到版本列右缘；
    /// 落后行黄色、运行错误行由检测流结论回填红色
    private struct BoxRow {
        let kind: BoxRowKind
        let label: String
        let version: String
        var suffix: String
        var color: NSColor
    }

    /// 方框产物：屏幕渲染行（右对齐制表位段落样式，右边框像素级闭合）+ 纯文本行
    /// （进 reportLines 供复制）+ 可回填行身份 + 落后插件清单
    private struct VersionBox {
        var plainLines: [String]
        var screenLines: [NSAttributedString]
        var lineKinds: [BoxRowKind?]
        var outdatedNames: [String]
    }

    /// 方框内容行的正文灰（比框线的标题色稍暗，保持报告头层次）
    private static let boxBodyColor = NSColor(white: 0.78, alpha: 1)

    /// 框线行颜色（与实例 titleColor 同值；渲染在 static 上下文，单列一份）
    private static let boxFrameColor = NSColor(white: 0.85, alpha: 1)

    /// 方框字体：与 attributed(_:) 同一套（Menlo 13），标签→版本的空格数按它的像素宽折算
    private static let boxFont = NSFont(name: "Menlo", size: 13)
        ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// 文本在方框字体下的像素宽。等宽字体遇 CJK 会回退到系统中日韩字体，
    /// 字宽不是恰好 2 倍 ASCII 格宽，所以对齐要按像素算、不能按"中文算 2 列"算。
    private static func pixelWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: boxFont]).width
    }

    /// 设备实测宽度：NSLayoutManager 与 textView 是同一排版引擎（同一回退字体
    /// 链、同一像素取整），量出的前缀宽度就是真机渲染宽度——size() 对回退字形
    /// 有低估、保守步进又会留下多余空隙（2026-09-12 底框 3 格缺口根因），
    /// 填充计数一律改由此实测驱动
    private static func measuredWidth(_ text: String) -> CGFloat {
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 1_000_000, height: 200))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        let storage = NSTextStorage(attributedString:
            NSAttributedString(string: text, attributes: [.font: boxFont]))
        storage.addLayoutManager(manager)
        let glyphs = manager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: (text as NSString).length),
            actualCharacterRange: nil)
        return manager.boundingRect(forGlyphRange: glyphs, in: container).maxX
    }

    /// 前端（dsh-macos）版本：主应用（mainAppURL 候选逻辑同启动器）Info.plist 的
    /// CFBundleShortVersionString；应用不存在 / plist 缺失 / 字段为空一律 nil（整行不显示）
    private static func mainAppVersion() -> String? {
        guard let app = mainAppURL else { return nil }
        let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String
        return (version?.isEmpty == false) ? version : nil
    }

    /// 后端 dsh 版本（方框口径）：在线时问桌面桥 status 报文——与体检流水线「桥接接口」
    /// 同一数据源（方框先于检测流渲染，此处自取一次；回环 GET 只读且短超时）；拿不到时
    /// 退回扫 npx 缓存副本。都取不到返回 nil（整行不显示）。
    private static func probeBackendVersion() async -> String? {
        if let online = await liveBackendVersion() { return online }
        return npxBackendVersion()
    }

    /// 在线版本：GET /api/desktop/status（短超时、绕缓存；后端未监听时回环连接立即
    /// 失败，不会拖慢体检开跑）
    private static func liveBackendVersion() async -> String? {
        guard let url = URL(string: "http://127.0.0.1:3080/api/desktop/status") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["ok"] as? Bool == true,
              let version = obj["version"] as? String,
              !version.isEmpty, version != "?" else { return nil }
        return version
    }

    /// 离线版本：扫 ~/.npm/_npx 下装有 @deepseek-ai/dsh 的缓存目录（与「npx 副本」
    /// 检测同型扫描），取 bin.js 修改时间最新的那份，读其 package.json 的 version
    private static func npxBackendVersion() -> String? {
        let npxRoot = NSHomeDirectory() + "/.npm/_npx"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: npxRoot) else { return nil }
        var latest: (mtime: Date, version: String)? = nil
        for entry in entries {
            let pkgDir = npxRoot + "/" + entry + "/node_modules/@deepseek-ai/dsh"
            guard let version = packageVersion(at: pkgDir + "/package.json") else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: pkgDir + "/bin.js")
            let binMtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            if latest == nil || binMtime > latest!.mtime { latest = (binMtime, version) }
        }
        return latest?.version
    }

    /// 已安装家族插件版本：扫 profile 内层部署位 ~/.dsh/profiles/web/node_modules/，
    /// 只列 boxPluginNames 里 package.json 能读出版本的（目录在但清单缺失/损坏的跳过）
    private static func installedPluginVersions() -> [(name: String, version: String)] {
        let root = NSHomeDirectory() + "/.dsh/profiles/web/node_modules"
        var installed: [(name: String, version: String)] = []
        for name in boxPluginNames {
            if let version = packageVersion(at: root + "/" + name + "/package.json") {
                installed.append((name, version))
            }
        }
        return installed
    }

    /// 取数并组框：本地版本逐项 fail-soft（取不到的行整行不显示，一项都取不到则整个
    /// 方框不显示）；落后检测并发拉 GitHub（单项 2s 超时），任何失败都视为无法判定
    private static func buildVersionBox() async -> VersionBox? {
        var rows: [BoxRow] = []
        if let shell = mainAppVersion() {
            rows.append(BoxRow(kind: .shell, label: "前端（dsh-macos）", version: shell,
                               suffix: "", color: boxBodyColor))
        }
        if let backend = await probeBackendVersion() {
            rows.append(BoxRow(kind: .backend, label: "后端 dsh", version: backend,
                               suffix: "", color: boxBodyColor))
        }
        // 项目列前缀（2026-09-12 用户定稿）：插件行写功能名 + 插件 ID，如
        // 「后端插件协议 dsh-plugin-norm」；表外插件回落「插件」
        let pluginDisplayNames = [
            "dsh-plugin-norm": "后端插件协议",
            "dsh-theme-sdk": "后端主题插件",
            "dsh-mini-dialog": "迷你对话框",
            "dsh-l10n-zh": "中文语言包",
            "dsh-theme-grok": "Grok 主题",
        ]
        var pluginRows = installedPluginVersions().map {
            BoxRow(kind: .plugin($0.name),
                   label: (pluginDisplayNames[$0.name] ?? "插件") + " " + $0.name,
                   version: $0.version, suffix: "", color: boxBodyColor)
        }
        var outdatedNames: [String] = []
        await withTaskGroup(of: (String, String?).self) { group in
            for row in pluginRows {
                guard case .plugin(let name) = row.kind,
                      let repo = pluginReleaseRepos[name] else { continue }
                group.addTask { () -> (String, String?) in
                    (name, await Self.latestReleaseTag(repo: repo))
                }
            }
            for await (name, tag) in group {
                // 仅 remote 严格比 local 新才判落后；无 release/超时/解析失败不上色不误报
                guard let tag,
                      let index = pluginRows.firstIndex(where: {
                          if case .plugin(let n) = $0.kind { return n == name }
                          return false
                      }),
                      let order = compareVersions(pluginRows[index].version, tag),
                      order == .orderedAscending else { continue }
                pluginRows[index].suffix = "（可更新）"
                pluginRows[index].color = warnColor
                outdatedNames.append(name)
            }
        }
        rows.append(contentsOf: pluginRows)
        guard !rows.isEmpty else { return nil }
        return renderVersionBox(rows: rows, outdatedNames: outdatedNames)
    }

    /// 布局（第 4 版，2026-09-12 定稿）。三段历史教训：
    /// - 空格按像素补齐：CJK/制表符回退字体渲染步进有漂移，各行汉字数不同
    ///   → 残差模 cell 各异 → 右缘四档错位（用户截图像素实测 646/650/651/656）
    /// - 双制表位（值右锚 + 边框左锚）：真机 NSTextView 对行内第二个制表位
    ///   统一右偏 ~1.5 格（离线 drawWithRect 无此现象），整框右缘漂移
    /// - 单左制表位：同样跳位（┘ 落后停靠位 +2 格，右下角不闭合）
    /// 定稿构造：**只保留一个右制表位**（值列右缘，真机像素验证精确落位），
    /// 边框字形不占制表位——值后接一个 Menlo 空格（主字体步进精确无漂移）
    /// 直接拼 │/┐/┘：位置 = contentRight + 1 格，与左侧「│ 」对称。填充计数由
    /// measuredWidth（NSLayoutManager 实测，与 textView 同引擎）驱动，右制表位
    /// 前留 eps 余量——「跳过停靠点」是唯一失败模式，实测同引擎误差 ≤0.5px，
    /// eps=2pt 已是 8 倍安全。纯文本行（复制报告）用空格近似。框宽全部由
    /// 当次行集动态测算
    private static func renderVersionBox(rows: [BoxRow], outdatedNames: [String]) -> VersionBox {
        let spacePx = pixelWidth(" ")
        let dotCell = pixelWidth("·")
        let dashCell = pixelWidth("─")
        let prefix = "│ "
        let prefixPx = pixelWidth(prefix)
        let headerRightText = "本地版本号"

        // 内容右缘（= 值列右缘）= 最宽「项目名 + 2 格 + 版本」行 + 3 枚点线保底
        let contentW = rows.map {
            pixelWidth($0.label) + spacePx * 2 + pixelWidth($0.version + $0.suffix)
        }.max() ?? 0
        let contentRightPx = prefixPx + contentW + dotCell * 3
        // 制表位语义（2026-09-12 定稿，第 6 版）：右停靠位把「制表符到行尾的
        // 整段」右对齐到停靠位——整段 = 值 + 空格 + 边框字形。停靠位定在
        // contentRight + 2 格（值右缘 + 1 格内衬 + 边框字形一格），整段右缘
        // 钉停靠位 ⇒ 值右缘恰在 contentRight、边框字形紧随其后，│ ┐ ┘ 的
        // 墨迹右缘同列闭合。填充预算 = 停靠位 - 整段实测宽 - eps（measuredWidth
        // 同引擎实测，装不下必跳默认停靠位——跳位后落点随段宽浮动，即历史
        // 各版「看似对齐实则错位」的根因）
        let borderStopPx = contentRightPx + spacePx * 2

        // 填充计数由 measuredWidth 实测驱动：逐枚加到装不下为止，右制表位前
        // 留 eps 余量（实测与终渲染同引擎，误差仅像素取整 ≤0.5px，eps 放大 8 倍）
        let eps: CGFloat = 2.0
        func fillCount(prefix: String, fill: String, budget: CGFloat) -> Int {
            var n = 0
            while measuredWidth(prefix + String(repeating: fill, count: n + 1)) <= budget {
                n += 1
            }
            return n
        }

        func makeStyle(rightAt: [CGFloat], leftAt: [CGFloat]) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            var stops = rightAt.map { NSTextTab(textAlignment: .right, location: $0, options: [:]) }
            stops += leftAt.map { NSTextTab(textAlignment: .left, location: $0, options: [:]) }
            stops.sort { $0.location < $1.location }
            style.tabStops = stops
            return style
        }
        let rowStyle = makeStyle(rightAt: [contentRightPx], leftAt: [])
        func boxLine(_ text: String, color: NSColor, style: NSParagraphStyle) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .font: boxFont, .foregroundColor: color, .paragraphStyle: style,
            ])
        }
        func px(_ text: String) -> CGFloat { pixelWidth(text) }
        // 纯文本行（复制报告）用：空格补到目标像素宽（近似对齐，无制表位语义）
        func padToPx(_ text: String, _ targetPx: CGFloat) -> String {
            var t = text
            while px(t) < targetPx { t += " " }
            return t
        }

        var plainLines: [String] = []
        var screenLines: [NSAttributedString] = []
        var lineKinds: [BoxRowKind?] = []

        // 表头与内容行同构（2026-09-12 二次定稿：顶部实线）：项目 = 左列头，
        // 横线填充；「本地版本号」右缘钉值列（右制表位）；┐ 钉边框列——
        // 两个制表位都被真实文本消费，与内容行同一套经验证的构造
        let headerChunk = headerRightText + " ┐"
        let headerDashes = max(2, fillCount(
            prefix: "┌─ 项目 ", fill: "─",
            budget: borderStopPx - measuredWidth(headerChunk) - eps))
        let header = "┌─ 项目 " + String(repeating: "─", count: headerDashes)
            + "\t" + headerRightText + " ┐"
        screenLines.append(boxLine(header, color: boxFrameColor, style: rowStyle))
        plainLines.append(padToPx(padToPx(
            "┌─ 项目 " + String(repeating: "─", count: headerDashes) + " ",
            contentRightPx - px(headerRightText)) + headerRightText, borderStopPx) + "┐")
        lineKinds.append(nil)

        // 内容行：项目名左对齐 · 点线导引 · 版本号右对齐（右缘同列）
        for row in rows {
            let value = row.version + row.suffix
            let valuePx = px(value)
            let labelEndPx = prefixPx + px(row.label) + spacePx
            // 点线预算 = 停靠位 - 整段（值+空格+│）实测宽 - eps
            let rowChunk = value + " │"
            let dots = max(2, fillCount(
                prefix: prefix + row.label + " ", fill: "·",
                budget: borderStopPx - measuredWidth(rowChunk) - eps))
            let line = prefix + row.label + " " + String(repeating: "·", count: dots)
                + "\t" + value + " │"
            screenLines.append(boxLine(line, color: row.color, style: rowStyle))
            plainLines.append(padToPx(padToPx(
                prefix + row.label + " " + String(repeating: "·", count: dots) + " ",
                contentRightPx - valuePx) + value, borderStopPx) + "│")
            lineKinds.append(row.kind)
        }

        // 底框（2026-09-12 二次定稿）：与内容行完全同构——└ + 横线（label 侧）
        // + 右制表位锚一枚横线到值列右缘（充当「值」消费第一个停靠位）+ 左制表位
        // 接 ┘。单停靠位样式在真机 NSTextView 上实测会跳位（┘ 落后停靠位 +2 格，
        // 右下角不闭合）；行样式的两个停靠位都被真实文本消费，经验证不跳位。
        // 末段横线与 ┘ 之间的 1 格间隙 = 内容行「值→│」的内衬列，网格一致
        // 底框整段 = K 枚横线 + 空格 + ┘（右锚停靠位）；链与整段按剩余空间
        // 联动迭代：K 逐枚加，链始终留得住至少 1 枚横线为止
        var bottomValueDashes = 1
        var bottomDashes = 1
        while true {
            let chunk = String(repeating: "─", count: bottomValueDashes) + " ┘"
            let n = fillCount(prefix: "└", fill: "─",
                              budget: borderStopPx - measuredWidth(chunk) - eps)
            if n < 1 { break }
            bottomDashes = n
            let chainW = measuredWidth("└" + String(repeating: "─", count: n))
            let spare = borderStopPx - measuredWidth(chunk) - eps - chainW
            if spare >= measuredWidth("─") && bottomValueDashes < 8 {
                bottomValueDashes += 1
            } else {
                break
            }
        }
        let bottom = "└" + String(repeating: "─", count: bottomDashes)
            + "\t" + String(repeating: "─", count: bottomValueDashes) + " ┘"
        screenLines.append(boxLine(bottom, color: boxFrameColor, style: rowStyle))
        plainLines.append(padToPx(
            "└" + String(repeating: "─", count: bottomDashes), borderStopPx) + "┘")
        lineKinds.append(nil)

        return VersionBox(plainLines: plainLines, screenLines: screenLines,
                          lineKinds: lineKinds, outdatedNames: outdatedNames)
    }


    /// 边框自校准：对本窗已排版的方框行，读 │/┐/┘ 实际 x，全体对齐到最大列
    private func calibrateBoxBorders() {
        guard let textView, let lm = textView.layoutManager, let container = textView.textContainer else { return }
        let storage = textView.textStorage
        let str = textView.string as NSString
        // kern 补偿：停靠位位移在在窗布局上实测无效（落位对 stop 不敏感），
        // kern 直接改字形步进、强制真实重排——对边框字形前的空格加 kern，
        // 把 │┐┘ 精确推到全体最大列
        for pass in 0..<3 {
            lm.ensureLayout(for: container)
            struct RowInfo { let kernAt: Int; let barX: CGFloat; let kern: CGFloat }
            var rowsInfo: [RowInfo] = []
            var charIdx = 0
            for line in str.components(separatedBy: "\n") {
                let len = line.count
                defer { charIdx += len + 1 }
                guard len > 0, line.contains("\t") else { continue }
                let lineRange = NSRange(location: charIdx, length: len)
                let gr = lm.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
                guard gr.length > 0 else { continue }
                var barChar = -1
                var barX: CGFloat = -1
                for g in stride(from: gr.length - 1, through: 0, by: -1) {
                    let c = lm.characterIndexForGlyph(at: gr.location + g)
                    let ch = str.substring(with: NSRange(location: c, length: 1))
                    if ch == "│" || ch == "┐" || ch == "┘" {
                        barChar = c
                        barX = lm.boundingRect(forGlyphRange: NSRange(location: gr.location + g, length: 1),
                                               in: container).minX
                        break
                    }
                }
                guard barChar > 0 else { continue }   // 前一个字符即 kern 承接位（构造保证是空格）
                let kern = (storage?.attribute(.kern, at: barChar - 1, effectiveRange: nil) as? CGFloat) ?? 0
                rowsInfo.append(RowInfo(kernAt: barChar - 1, barX: barX, kern: kern))
            }
            guard rowsInfo.count > 1 else { return }
            let target = rowsInfo.map { $0.barX }.max()!
            var moved = false
            for row in rowsInfo where row.barX < target - 0.3 {
                let delta = target - row.barX
                storage?.addAttribute(.kern, value: row.kern + delta, range: NSRange(location: row.kernAt, length: 1))
                moved = true
            }
            if !moved { break }
        }
        lm.ensureLayout(for: container)
    }

    /// 方框渲染进文本视图：屏幕行逐行追加；可回填行记录屏幕区间，供检测流出结论后改色；
    /// 纯文本行同步进 reportLines，复制报告时一并带上
    private func appendVersionBox(_ box: VersionBox) {
        for (index, line) in box.screenLines.enumerated() {
            let base = textView.map { ($0.string as NSString).length } ?? 0
            append(line: line)
            if let kind = box.lineKinds[index] {
                // append 在非空文本前会先补一个换行符，行起点相应 +1
                boxRowRanges[kind] = NSRange(
                    location: base == 0 ? 0 : base + 1,
                    length: (line.string as NSString).length)
            }
        }
        reportLines.append(contentsOf: box.plainLines)
    }

    /// 回填刷新：方框先渲染、检测流后出结论——norm caps 探针失败 / mini-dialog 检查 ✗
    /// 的红色结论晚于方框渲染。用 addAttribute 原地改色：不动字符、不改长度，方框其余行
    /// 与后续文本位置不受影响；每行只刷一次（用后即清）
    private func markBoxRowFailed(_ kind: BoxRowKind) {
        guard let range = boxRowRanges.removeValue(forKey: kind) else { return }
        textView?.textStorage?.addAttribute(.foregroundColor, value: Self.nodeRed, range: range)
    }

    /// 检测流结论 → 方框行错误映射（nil = 不回填）：
    /// - norm 协议：caps 探针失败 = ✗，或 ！且非「降级:」清单告警（即未加载/异常/报文
    ///   异常/未部署）；仅降级清单属功能告警，不算运行错误
    /// - mini 对话框：检查 ✗ 时同理
    /// - 后端未运行时的占位跳过行不代表插件故障，不回填（fail-soft 不误报）
    private static func boxErrorKind(for result: Result) -> BoxRowKind? {
        guard !result.value.contains("后端未运行") else { return nil }
        if result.name == "norm 协议 " {
            if result.mark == "✗" { return .plugin("dsh-plugin-norm") }
            // 「探测 x/x」= caps 已应答（! + 降级清单属功能告警不算运行错误）；
            // 未加载/异常/报文异常/连接失败的 ! 值里没有这一段
            if result.mark == "!" && !result.value.contains("探测 ") { return .plugin("dsh-plugin-norm") }
            return nil
        }
        if result.name == "mini 对话框", result.mark == "✗" { return .plugin("dsh-mini-dialog") }
        return nil
    }

    // MARK: 落后检测（GitHub latest release · 轻量 semver）

    /// 拉 repo 最新 release tag（只读 GET，2s 超时）；任何失败（断网/限流/404=无
    /// release/解析不出 tag_name）一律 nil = 无法判定
    private static func latestReleaseTag(repo: String) async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("DSH-Launcher-Checkup", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String, !tag.isEmpty else { return nil }
        return tag
    }

    /// 轻量 semver 比较（主/次/补丁 + 预发布段；构建元数据忽略）：返回 local 相对 remote
    /// 的次序；任一侧解析不出版本 → nil（视为无法判定，不上色）
    private static func compareVersions(_ local: String, _ remote: String) -> ComparisonResult? {
        guard let lhs = parseSemver(local), let rhs = parseSemver(remote) else { return nil }
        if lhs.core != rhs.core {
            return lhs.core < rhs.core ? .orderedAscending : .orderedDescending
        }
        // 核心号相同：正式版 > 预发布；两侧都预发布则逐段比（数字段按数值，数字段 <
        // 字符串段，字符串段按字典序；段少者小，如 1.0.0-alpha < 1.0.0-alpha.1）
        if lhs.prerelease == nil && rhs.prerelease == nil { return .orderedSame }
        if lhs.prerelease == nil { return .orderedDescending }
        if rhs.prerelease == nil { return .orderedAscending }
        guard let a = lhs.prerelease, let b = rhs.prerelease else { return nil }
        let aIds = a.split(separator: ".").map(String.init)
        let bIds = b.split(separator: ".").map(String.init)
        for i in 0..<max(aIds.count, bIds.count) {
            let x = i < aIds.count ? aIds[i] : nil
            let y = i < bIds.count ? bIds[i] : nil
            if x == nil, y == nil { continue }
            if x == nil { return .orderedAscending }
            if y == nil { return .orderedDescending }
            guard let xv = x, let yv = y else { continue }
            if let xi = Int(xv), let yi = Int(yv), xi != yi {
                return xi < yi ? .orderedAscending : .orderedDescending
            }
            if Int(xv) != nil { return .orderedAscending }
            if Int(yv) != nil { return .orderedDescending }
            if xv != yv { return xv < yv ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private struct Semver {
        var core: (Int, Int, Int)
        var prerelease: String?
    }

    /// "v1.2.3" / "1.2.3-beta.1+exp" / "0.2.0" → Semver；解析不出主/次版本 → nil。
    /// 数字核心段复用 parseVersion；预发布段取首个「-」之后（构建元数据「+」截断）
    private static func parseSemver(_ text: String) -> Semver? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.first == "v" || s.first == "V" { s = String(s.dropFirst()) }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        if let dash = s.firstIndex(of: "-") {
            let core = parseVersion(String(s[..<dash]))
            let prerelease = String(s[s.index(after: dash)...])
            guard let core, !prerelease.isEmpty else { return nil }
            return Semver(core: core, prerelease: prerelease)
        }
        guard let core = parseVersion(s) else { return nil }
        return Semver(core: core, prerelease: nil)
    }

    // MARK: 小工具

    /// 读 package.json 顶层 version 字段；文件缺失 / JSON 损坏 / 无版本号一律 nil（fail-soft）
    private static func packageVersion(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = obj["version"] as? String, !version.isEmpty else { return nil }
        return version
    }

    private static func firstExecutable(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 灰色跳过行（后端未运行时用，避免重复报错刷屏）
    private static func skip(name: String, reason: String) -> Result {
        Result(mark: "!", name: name, value: "\(reason)，跳过", color: NSColor(white: 0.6, alpha: 1))
    }

    /// "0.2.0" / "1.3.0-beta" → (1, 3, 0)；解析不出两个数字段则 nil
    private static func parseVersion(_ text: String) -> (Int, Int, Int)? {
        let comps = text.split(separator: ".").map { sub -> Int? in
            let digits = sub.prefix(while: { $0.isNumber })
            return digits.isEmpty ? nil : Int(digits)
        }
        guard comps.count >= 2, let major = comps[0], let minor = comps[1] else { return nil }
        let patch = comps.count >= 3 ? (comps[2] ?? 0) : 0
        return (major, minor, patch)
    }

    /// 组装可用的 npm 启动参数。GUI 进程 PATH 里通常没有 node，而 npm 多为指向
    /// npm-cli.js 的 symlink（shebang `env node`）——直接 exec 会失败，
    /// 所以优先用 node 显式拉起 cli js；都不是再退回直接跑 npm。
    private static func npmInvocation() async -> (launchPath: String, args: [String])? {
        var npmPath = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        if npmPath == nil, let which = firstExecutable(["/usr/bin/which", "/bin/which"]),
           let found = await runCapture(which, ["npm"], timeout: 3) {
            let candidate = found.components(separatedBy: CharacterSet.newlines).first ?? found
            if FileManager.default.isExecutableFile(atPath: candidate) { npmPath = candidate }
        }
        guard let npmPath else { return nil }

        if let nodePath = firstExecutable(["/opt/homebrew/bin/node", "/usr/local/bin/node"]),
           let rawLink = try? FileManager.default.destinationOfSymbolicLink(atPath: npmPath) {
            let cliJs = rawLink.hasPrefix("/")
                ? rawLink
                : (npmPath as NSString).deletingLastPathComponent + "/" + rawLink
            let resolved = (cliJs as NSString).standardizingPath
            if resolved.hasSuffix(".js"), FileManager.default.fileExists(atPath: resolved) {
                return (nodePath, [resolved, "cache", "clean", "--force"])
            }
        }
        return (npmPath, ["cache", "clean", "--force"])
    }

    private static let nodeGreen = NSColor(red: 0x4C / 255.0, green: 0xAF / 255.0, blue: 0x50 / 255.0, alpha: 1)
    private static let warnColor = NSColor(red: 0xFF / 255.0, green: 0xC1 / 255.0, blue: 0x07 / 255.0, alpha: 1)
    private static let nodeRed = NSColor(red: 0xE5 / 255.0, green: 0x53 / 255.0, blue: 0x5A / 255.0, alpha: 1)

    // MARK: - 动作按钮（用户显式点按才执行；白名单：npm cache clean / NSWorkspace.open
    // / dsh plugin --profile web add https://github.com/iiiiiei/dsh-plugin-norm）

    /// 放行的安装命令形态（唯一）：dsh-plugin-norm 的 profile add。其余家族插件无独立
    /// 安装来源，不做按钮、不放行命令
    private static let pluginInstallCommands: [String: [String]] = [
        "dsh-plugin-norm": ["plugin", "--profile", "web", "add",
                            "https://github.com/iiiiiei/dsh-plugin-norm"],
    ]

    /// dsh 命令探测（从简）：只认 /opt/homebrew/bin/dsh；不在则跳过并写日志
    private static let dshBinaryPath = "/opt/homebrew/bin/dsh"

    /// 触发条件矩阵：
    /// - [释放 npm 缓存]：缓存体量建议（含 `npm cache clean`）或 npx 多副本建议（含
    ///   「多副本无害」，其文案同样指向该按钮）出现时
    /// - [打开 npx 目录]：npx 多副本建议出现时
    /// - [一键更新插件]：版本方框检出「落后且有放行安装命令」的插件（dsh-plugin-norm）时
    private func refreshActionButtons(advices: [String]) {
        let wantsCleanCache = advices.contains {
            $0.contains("npm cache clean") || $0.contains("多副本无害")
        }
        let wantsOpenNpx = advices.contains { $0.contains("多副本无害") }
        let wantsUpdatePlugins = outdatedPluginNames.contains {
            Self.pluginInstallCommands[$0] != nil
        }
        cleanCacheButton?.isHidden = !wantsCleanCache
        openNpxButton?.isHidden = !wantsOpenNpx
        updatePluginsButton?.isHidden = !wantsUpdatePlugins
        cleanCacheButton?.isEnabled = true
        openNpxButton?.isEnabled = true
        updatePluginsButton?.isEnabled = true
        relayoutActionButtons()
    }

    /// 动作按钮紧贴「重新体检」左侧排布（只排可见者；窗口拉伸由 autoresizing 右锚定兜底）
    private func relayoutActionButtons() {
        guard let rerunButton else { return }
        var left = rerunButton.frame.minX - 8
        for button in [updatePluginsButton, cleanCacheButton, openNpxButton].compactMap({ $0 })
        where !button.isHidden {
            let x = left - button.frame.width
            button.frame.origin.x = x
            left = x - 8
        }
    }

    /// 动作结果行：屏幕与 reportLines 同步追加
    private func appendActionLine(_ text: String, color: NSColor) {
        append(line: attributed(text, color: color))
        reportLines.append(text)
    }

    @objc private func rerunCheckup() { runCheckup() }

    @objc private func cleanNpmCache() {
        guard let button = cleanCacheButton, button.isEnabled else { return }
        button.isEnabled = false
        appendActionLine("[…] 动作：正在执行 npm cache clean --force（缓存大时需数十秒）…", color: titleColor)
        Task { @MainActor in
            guard let npm = await Self.npmInvocation() else {
                self.appendActionLine("[!] 动作：未找到 npm（已跳过缓存释放）", color: self.warnColor)
                button.isHidden = true
                return
            }
            // 清理放后台队列防 UI 卡死；结果回主线程追加
            let outcome = await Self.runProcess(npm.launchPath, npm.args, timeout: 300)
            if outcome.ok {
                self.appendActionLine("[✓] 动作：npm 缓存已释放（_cacache；_npx 副本目录不受影响）",
                                      color: self.passColor)
            } else {
                let reason = outcome.ran ? (outcome.text ?? "退出码非 0") : (outcome.text ?? "无法启动进程")
                self.appendActionLine("[!] 动作：npm 缓存释放失败（\(reason)）", color: self.warnColor)
            }
            button.isHidden = true
            // 重测「缓存体量」数值行，让用户看到释放效果
            let fresh = await Self.checkCacheBulk()
            self.append(line: self.attributed("[\(fresh.mark)] \(fresh.name)：\(fresh.value)", color: fresh.color))
            self.reportLines.append("[\(fresh.mark)] \(fresh.name): \(fresh.value)")
        }
    }

    @objc private func openNpxDir() {
        let path = NSHomeDirectory() + "/.npm/_npx"
        guard FileManager.default.fileExists(atPath: path) else {
            appendActionLine("[!] 动作：~/.npm/_npx 不存在，无法打开", color: warnColor)
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        appendActionLine("[✓] 动作：已在 Finder 打开 npx 目录（可手动清点/删除非活跃副本；删前确认后端已停）",
                         color: passColor)
    }

    /// 一键更新插件：逐个对落后插件执行放行的安装命令（当前仅 dsh-plugin-norm 一种形态；
    /// 其余落后插件无放行命令，写日志跳过）。全部执行完自动重跑一次体检，
    /// 体检会按最新状态重排方框颜色与按钮
    @objc private func updateOutdatedPlugins() {
        guard let button = updatePluginsButton, button.isEnabled else { return }
        button.isEnabled = false
        let targets = outdatedPluginNames.filter { Self.pluginInstallCommands[$0] != nil }
        let skipped = outdatedPluginNames.filter { Self.pluginInstallCommands[$0] == nil }
        guard !targets.isEmpty else { return }
        appendActionLine("[…] 动作：正在更新落后插件（\(targets.joined(separator: "、"))）…", color: titleColor)
        Task { @MainActor in
            guard FileManager.default.isExecutableFile(atPath: Self.dshBinaryPath) else {
                self.appendActionLine(
                    "[!] 动作：未找到 dsh 命令（\(Self.dshBinaryPath) 不存在；已跳过插件更新）",
                    color: self.warnColor)
                button.isHidden = true
                return
            }
            if !skipped.isEmpty {
                self.appendActionLine("[!] 跳过 \(skipped.joined(separator: "、"))（无放行的安装命令形态）",
                                      color: self.warnColor)
            }
            for name in targets {
                guard let args = Self.pluginInstallCommands[name] else { continue }
                self.appendActionLine("[…] \(name)：dsh \(args.joined(separator: " "))", color: self.titleColor)
                let outcome = await Self.runProcess(Self.dshBinaryPath, args, timeout: 300)
                if outcome.ok {
                    self.appendActionLine("[✓] \(name)：安装命令执行完成", color: self.passColor)
                } else {
                    let reason = outcome.ran ? (outcome.text ?? "退出码非 0") : (outcome.text ?? "无法启动进程")
                    self.appendActionLine("[!] \(name)：安装命令失败（\(reason)）", color: self.warnColor)
                }
            }
            // 执行后自动重跑一次体检
            self.runCheckup()
        }
    }
}
