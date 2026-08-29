import AppKit

/// 一键体检窗口（对齐卡卡2 定稿规格）：
/// - 独立小窗 460×320，可拖动，非模态——主应用/后端照常使用，体检只读
/// - 深色 #1E1E1E 底，Menlo 11pt；标题灰白 / 通过绿 #4CAF50 / 告警黄 / 失败红
/// - 结果"逐行即时刷出"（用户拍板的像素风格进度）：每完成一项检测立刻滚出
///   一行 `[✓|!|✗] 名称 数值`，按真实检测结果推进，不做预渲染假进度
/// - 全部检测只读：查版本、查签名、连本机回环、数缓存副本——不杀任何进程
final class CheckupWindowController {
    static let shared = CheckupWindowController()

    private var window: NSWindow?
    private var textView: NSTextView?

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
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable, .resizable],   // 真机反馈：字号加大＋窗口可拉伸
            backing: .buffered,
            defer: false
        )
        win.title = "DSH Launcher · 一键体检"
        win.backgroundColor = bgColor
        win.isMovableByWindowBackground = true
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 480, height: 320)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 544, height: 350))
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        let scroll = NSScrollView(frame: NSRect(x: 6, y: 40, width: 548, height: 352))
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let copyButton = NSButton(title: "复制报告", target: self, action: #selector(copyReport))
        copyButton.bezelStyle = .rounded
        copyButton.frame = NSRect(x: 336, y: 8, width: 104, height: 26)
        copyButton.autoresizingMask = [.minXMargin]
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        closeButton.frame = NSRect(x: 450, y: 8, width: 104, height: 26)
        closeButton.autoresizingMask = [.minXMargin]

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 400))
        content.addSubview(scroll)
        content.addSubview(copyButton)
        content.addSubview(closeButton)
        win.contentView = content

        self.window = win
        self.textView = textView
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

    private func runCheckup() {
        reportLines.removeAll()
        guard let textView else { return }
        textView.string = ""
        append(line: attributed("── DSH Launcher 体检 ──", color: titleColor))

        Task { @MainActor in
            var advices: [String] = []
            for await result in Self.checkAll() {
                self.append(line: self.attributed(
                    "[\(result.mark)] \(result.name)：\(result.value)", color: result.color))
                self.reportLines.append("[\(result.mark)] \(result.name): \(result.value)")
                if let advice = result.advice { advices.append(advice) }
            }
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
        }
    }

    /// 逐项检测流：每项真实执行完才 yield 一条，窗口即刻滚出该行。
    private nonisolated static func checkAll() -> AsyncStream<Result> {
        AsyncStream { continuation in
            Task { @MainActor in
                continuation.yield(CheckupWindowController.checkMacOS())
                continuation.yield(await CheckupWindowController.checkNode())
                continuation.yield(await CheckupWindowController.checkAppSignature())
                continuation.yield(await CheckupWindowController.checkPortIdentity())
                continuation.yield(await CheckupWindowController.checkBridgeEndpoint())
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
                    cont.resume(returning: (out?.isEmpty == false) ? out : nil)
                } catch {
                    cont.resume(returning: nil)
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

    /// 桥接接口：桌面桥插件的健康报文校验（与 StatusProbe 同一数据源，双确认）
    private static func checkBridgeEndpoint() async -> Result {
        guard let url = URL(string: "http://127.0.0.1:3080/api/desktop/status") else {
            return Result(mark: "✗", name: "桥接接口 ", value: "URL 构造失败", color: nodeRed)
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            request.cachePolicy = .reloadIgnoringLocalCacheData   // 状态判定绝不吃本地缓存
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["ok"] as? Bool == true else {
                return Result(mark: "!", name: "桥接接口 ", value: "有响应但报文异常", color: warnColor,
                              advice: "桥接插件的 status 报文不符合预期，可能插件未装配——重装命令可修复。")
            }
            let version = obj["version"] as? String ?? "?"
            let pid = obj["pid"] as? Int ?? 0
            return Result(mark: "✓", name: "桥接接口 ", value: "/api/desktop/status ok · dsh v\(version) · pid \(pid)",
                          color: nodeGreen)
        } catch {
            return Result(mark: "✗", name: "桥接接口 ", value: "不可达（\(error.localizedDescription)）", color: nodeRed)
        }
    }

    /// npx 副本数：数 ~/.npm/_npx 下装着 @deepseek-ai/dsh 的缓存目录个数。
    /// 多副本不算故障（resolveCommand 六级兜底正是为此设计），但会占盘且可能跨版本。
    private static func checkNPXCopies() async -> Result {
        let npxRoot = NSHomeDirectory() + "/.npm/_npx"
        var copies = 0
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: npxRoot) {
            for entry in entries {
                let probe = npxRoot + "/" + entry + "/node_modules/@deepseek-ai/dsh"
                if FileManager.default.fileExists(atPath: probe) { copies += 1 }
            }
        }
        let profileDeployed = FileManager.default.fileExists(
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
                          advice: "存在多份后端副本（占磁盘且可能新旧混用）。可在终端执行 `npm cache clean --force` 后重启一次主应用收敛。")
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

    private static let nodeGreen = NSColor(red: 0x4C / 255.0, green: 0xAF / 255.0, blue: 0x50 / 255.0, alpha: 1)
    private static let warnColor = NSColor(red: 0xFF / 255.0, green: 0xC1 / 255.0, blue: 0x07 / 255.0, alpha: 1)
    private static let nodeRed = NSColor(red: 0xE5 / 255.0, green: 0x53 / 255.0, blue: 0x5A / 255.0, alpha: 1)
}
