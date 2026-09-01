import AppKit

/// 一键体检窗口（对齐卡卡2 定稿规格 + alpha 时代扩展）：
/// - 独立小窗，可拖动，非模态——主应用/后端照常使用，体检只读
/// - 深色 #1E1E1E 底，Menlo 13pt；标题灰白 / 通过绿 #4CAF50 / 告警黄 / 失败红
/// - 结果"逐行即时刷出"（用户拍板的像素风格进度）：每完成一项检测立刻滚出
///   一行 `[✓|!|✗] 名称 数值`，按真实检测结果推进，不做预渲染假进度
/// - 检查维度（全只读）：系统 / Node / 应用签名 / 端口身份 / 后端通道形态
///   （稳定通道 200=健康 · alpha 认证链 401+文案=健康）/ 桥接接口 / norm 协议层
///   （dsh-plugins-norm caps 路由，免认证）/ profile 工作区装配（alpha.3 白屏坑）/
///   mini-dialog 版本 / npx 副本 / 缓存体量
/// - 动作按钮（体检完成后按结果出现，用户点按才执行，绝不在体检过程中自动执行）：
///   释放 npm 缓存（`npm cache clean --force`）、打开 npx 目录（Finder）、重新体检
/// - 安全红线：体检全只读；动作仅限白名单（npm cache clean / NSWorkspace.open），
///   绝不自动删目录、绝不杀任何既有进程（超时强杀仅针对我们自起的短命命令进程）
final class CheckupWindowController {
    static let shared = CheckupWindowController()

    private var window: NSWindow?
    private var textView: NSTextView?
    private var rerunButton: NSButton?
    private var cleanCacheButton: NSButton?
    private var openNpxButton: NSButton?
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

    func show() {
        if window == nil { buildWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        runCheckup()
    }

    // MARK: - 突体与输出

    private func buildWindow() {
        // 底部按钮行最多 5 枚（2 动作 + 重新体检/复制报告/关闭），窗口加宽到 640 保证不挤压
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable, .resizable],   // 真机反馈：字号加大＋窗口可拉伸
            backing: .buffered,
            defer: false
        )
        win.title = "DSH Launcher · 一键体检"
        win.backgroundColor = bgColor
        win.isMovableByWindowBackground = true
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 620, height: 320)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 624, height: 350))
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        let scroll = NSScrollView(frame: NSRect(x: 6, y: 40, width: 628, height: 352))
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        // 底部按钮行（从右往左）：[关闭][复制报告][重新体检] ← 动作按钮区（动态） ← 弹性空隙
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        closeButton.frame = NSRect(x: 530, y: 8, width: 104, height: 26)
        closeButton.autoresizingMask = [.minXMargin]
        let copyButton = NSButton(title: "复制报告", target: self, action: #selector(copyReport))
        copyButton.bezelStyle = .rounded
        copyButton.frame = NSRect(x: 418, y: 8, width: 104, height: 26)
        copyButton.autoresizingMask = [.minXMargin]
        let rerunButton = NSButton(title: "重新体检", target: self, action: #selector(rerunCheckup))
        rerunButton.bezelStyle = .rounded
        rerunButton.toolTip = "清空报告并重新体检"
        rerunButton.frame = NSRect(x: 306, y: 8, width: 104, height: 26)
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

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        content.addSubview(scroll)
        content.addSubview(closeButton)
        content.addSubview(copyButton)
        content.addSubview(rerunButton)
        content.addSubview(cleanCacheButton)
        content.addSubview(openNpxButton)
        win.contentView = content

        self.window = win
        self.textView = textView
        self.rerunButton = rerunButton
        self.cleanCacheButton = cleanCacheButton
        self.openNpxButton = openNpxButton
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

    private func attributed(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                // 真机反馈：11pt 看不清，加大到 13pt
                .font: NSFont(name: "Menlo", size: 13)
                    ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: color,
            ]
        )
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
        cleanCacheButton?.isHidden = true
        openNpxButton?.isHidden = true
        cleanCacheButton?.isEnabled = true
        openNpxButton?.isEnabled = true
        guard let textView else { return }
        textView.string = ""
        append(line: attributed("── DSH Launcher 体检 ──", color: titleColor))

        Task { @MainActor in
            var advices: [String] = []
            for await result in Self.checkAll() {
                guard generation == self.checkupGeneration else { return }
                self.append(line: self.attributed(
                    "[\(result.mark)] \(result.name)：\(result.value)", color: result.color))
                self.reportLines.append("[\(result.mark)] \(result.name): \(result.value)")
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
                return Result(mark: "✓", name: "Node      ", value: "\(version)（\(nodePath)）",
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
                               value: "在线 · alpha 认证链形态（健康）", color: nodeGreen), .alphaAuth)
            }
            if code == 404 {
                return (Result(mark: "!", name: "后端通道 ",
                               value: "在线但路由未就绪（后端刚启动？稍后重测）", color: warnColor), .notReady)
            }
            return (Result(mark: "!", name: "后端通道 ", value: "根路径 HTTP \(code)（形态未知）", color: warnColor,
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
                           value: "/api/desktop/status ok · dsh v\(version ?? "?") · pid \(pid)",
                           color: nodeGreen),
                    (version?.isEmpty == false && version != "?") ? version : nil)
        } catch {
            return (Result(mark: "✗", name: "桥接接口 ",
                           value: "不可达（\(error.localizedDescription)）", color: nodeRed), nil)
        }
    }

    /// norm 协议层：dsh-plugins-norm 是家族漂移屏蔽层，caps 路由免认证。
    /// 200 → 报 norm 版本 / 探测计数 / 降级清单；404 或连接失败 → 未部署（跳转通道降级）。
    private static func checkNormCaps() async -> Result {
        guard let url = URL(string: "http://127.0.0.1:3080/api/dsh-plugins-norm/caps") else {
            return Result(mark: "✗", name: "norm 协议 ", value: "URL 构造失败", color: nodeRed)
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode.description ?? "?"
                return Result(mark: "!", name: "norm 协议 ",
                              value: "未部署（HTTP \(code)；会话跳转通道降级；部署方法见 wiki）", color: warnColor)
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
                              value: "norm \(version) · \(probeText) · 降级:无", color: nodeGreen)
            }
            let labels = degradedRaw.map { item -> String in
                if let s = item as? String { return s }
                if let d = item as? [String: Any] {
                    return (d["name"] as? String) ?? (d["plugin"] as? String) ?? (d["reason"] as? String) ?? "?"
                }
                return "?"
            }
            return Result(mark: "!", name: "norm 协议 ",
                          value: "norm \(version) · \(probeText) · 降级:\(labels.joined(separator: "、"))",
                          color: warnColor)
        } catch {
            return Result(mark: "!", name: "norm 协议 ",
                          value: "未部署（连接失败；会话跳转通道降级；部署方法见 wiki）", color: warnColor)
        }
    }

    /// mini-dialog 版本：读 package.json。≥0.2.0 focus 走 norm；旧版自带 WS 通道建议升级。
    private static func checkMiniDialog() async -> Result {
        let pkgPath = NSHomeDirectory() + "/.dsh/profiles/node_modules/dsh-mini-dialog/package.json"
        guard let data = FileManager.default.contents(atPath: pkgPath),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = obj["version"] as? String else {
            return Result(mark: "!", name: "mini 对话框", value: "未安装（launcher 一键安装可补）", color: warnColor)
        }
        guard let semver = parseVersion(version) else {
            return Result(mark: "!", name: "mini 对话框",
                          value: "\(version)（版本无法解析，建议升级 0.2.0+）", color: warnColor)
        }
        if semver >= (0, 2, 0) {
            return Result(mark: "✓", name: "mini 对话框", value: "\(version)（focus 走 norm）", color: nodeGreen)
        }
        return Result(mark: "!", name: "mini 对话框",
                      value: "\(version)（旧版自带 WS 通道，建议升级 0.2.0+ 并部署 norm）", color: warnColor)
    }

    /// profile 工作区装配（alpha.3 白屏坑）：0.1.2-alpha 起 GUI 装配在 pnpm 工作区
    /// `~/.dsh/profiles/web/`，缺失则 GUI 白屏。后端在线缺失直接红；离线缺失给黄色预警。
    private static func checkProfileWorkspace(backendOnline: Bool, backendVersion: String?) async -> Result {
        let webAppRoot = NSHomeDirectory() + "/.dsh/profiles/web/node_modules/@deepseek-ai/dsh-web-app"
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: webAppRoot, isDirectory: &isDir), isDir.boolValue {
            return Result(mark: "✓", name: "profile 装配", value: "已装配（GUI 可启动）", color: nodeGreen)
        }
        let version = backendVersion ?? "<后端版本>"
        var fix = "修复：cd ~/.dsh/profiles/web && pnpm add "
                  + "@deepseek-ai/dsh-base@\(version) @deepseek-ai/dsh-web-app@\(version)"
        if backendVersion == nil { fix += "（后端版本待在线后重测获取）" }
        if backendOnline {
            return Result(mark: "✗", name: "profile 装配", value: "未装配——GUI 将白屏", color: nodeRed, advice: fix)
        }
        return Result(mark: "!", name: "profile 装配",
                      value: "未装配（后端未运行；GUI 启动前需装配，否则白屏）", color: warnColor, advice: fix)
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
                              value: "npx 缓存 0 份；profile 内有安装版（干净）", color: nodeGreen)
            }
            return Result(mark: "✗", name: "npx 副本  ", value: "未发现 @deepseek-ai/dsh 缓存", color: nodeRed,
                          advice: "后端尚未经 npx 安装过；第一次启动主应用会自动完成。")
        }
        let profileNote = profileDeployed ? "；profile 内另有安装版" : ""
        if copies > 1 {
            return Result(mark: "!", name: "npx 副本  ", value: "发现 \(copies) 份 @deepseek-ai/dsh 缓存\(profileNote)", color: warnColor,
                          advice: "多副本无害（解析链自动选活跃副本），仅占磁盘。如需释放空间点下方「释放 npm 缓存」；如需手动清点副本点「打开 npx 目录」。")
        }
        return Result(mark: "✓", name: "npx 副本  ", value: "恰好 1 份（健康）\(profileNote)", color: nodeGreen)
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

    // MARK: 小工具

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

    // MARK: - 动作按钮（用户显式点按才执行；白名单：npm cache clean / NSWorkspace.open）

    /// 触发条件矩阵：
    /// - [释放 npm 缓存]：缓存体量建议（含 `npm cache clean`）或 npx 多副本建议（含
    ///   「多副本无害」，其文案同样指向该按钮）出现时
    /// - [打开 npx 目录]：npx 多副本建议出现时
    private func refreshActionButtons(advices: [String]) {
        let wantsCleanCache = advices.contains {
            $0.contains("npm cache clean") || $0.contains("多副本无害")
        }
        let wantsOpenNpx = advices.contains { $0.contains("多副本无害") }
        cleanCacheButton?.isHidden = !wantsCleanCache
        openNpxButton?.isHidden = !wantsOpenNpx
        cleanCacheButton?.isEnabled = true
        openNpxButton?.isEnabled = true
        relayoutActionButtons()
    }

    /// 动作按钮紧贴「重新体检」左侧排布（只排可见者；窗口拉伸由 autoresizing 右锚定兜底）
    private func relayoutActionButtons() {
        guard let rerunButton else { return }
        var left = rerunButton.frame.minX - 8
        for button in [cleanCacheButton, openNpxButton].compactMap({ $0 }) where !button.isHidden {
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
}
