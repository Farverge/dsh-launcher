import AppKit

/// 菜单栏三态图标工厂（对齐卡 A1 第五轮定稿）：
/// - healthy     → 官方鲸鱼模板图标原样
/// - transitional→ 鲸鱼右下角叠一枚"？"角标，以约 1Hz 闪烁（用户拍板的问号闪烁方案）
/// - down        → 右下角叠一枚"！"角标
///
/// 全部为模板单色合成，零新增美术资源、零额外进程开销。
/// 合成原理：模板图只认 alpha 通道——角标圆盘画满不透明像素，
/// 再用 .clear 抠出字符笔画，菜单栏深浅色下自动呈现反色可读效果。
enum StatusIcons {
    enum Badge {
        case question   // transitional
        case exclamation // down
    }

    private static let sideLength: CGFloat = 18

    /// 基础鲸鱼：与 v0 相同的加载优先级（SVG → PNG → SF Symbol 兜底）
    static let whaleBase: NSImage = {
        if let svgPath = Bundle.main.path(forResource: "whale", ofType: "svg"),
           let svg = NSImage(contentsOfFile: svgPath) {
            svg.size = NSSize(width: sideLength, height: sideLength)
            svg.isTemplate = true
            return svg
        }
        let path = Bundle.main.path(forResource: "whale-icon", ofType: "png")
        let image = path.flatMap { NSImage(contentsOfFile: $0) }
            ?? NSImage(systemSymbolName: "bolt.shield", accessibilityDescription: "DSH Desktop")!
        image.size = NSSize(width: sideLength, height: sideLength)
        image.isTemplate = true
        return image
    }()

    /// 各态成品图（惰性合成一次后常驻内存——这是不可变资源，不属于用户红线里的"状态缓存"）
    static let healthy: NSImage = copyTemplate()
    static let questionOn: NSImage = compose(.question)
    static let questionOff: NSImage = copyTemplate()
    static let exclamation: NSImage = compose(.exclamation)

    /// 过渡态闪烁取图：blinkOn 为 true 时带问号角标，false 时素鲸鱼
    static func transitional(blinkOn: Bool) -> NSImage {
        blinkOn ? questionOn : questionOff
    }

    private static func copyTemplate(_ base: NSImage = whaleBase) -> NSImage {
        let copy = base.copy() as! NSImage
        copy.isTemplate = true
        return copy
    }

    /// 在鲸鱼副本右下角合成角标：不透明圆盘 + clear 抠字
    private static func compose(_ badge: Badge) -> NSImage {
        guard let copy = whaleBase.copy() as? NSImage else { return whaleBase }
        copy.isTemplate = true

        let discRect = NSRect(x: 10, y: 0, width: 8, height: 8)

        copy.lockFocusFlipped(false)
        defer { copy.unlockFocus() }

        // 角标圆盘：实心圆
        NSColor.black.setFill()
        NSBezierPath(ovalIn: discRect).fill()

        // 抠出字符笔画：把上下文合成模式切到 clear 画字符，像素即被挖空，
        // 露出菜单栏本底——深浅色模式下自动形成可读对比。顺序不可乱：
        // 先底鲸鱼、再角标圆盘、最后抠字。
        if let context = NSGraphicsContext.current {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            ]
            let glyphSize = glyphString(for: badge).size()
            let origin = NSPoint(
                x: discRect.midX - glyphSize.width / 2,
                y: discRect.midY - glyphSize.height / 2 + 0.5
            )
            context.compositingOperation = .clear
            (glyphString(for: badge).string as NSString).draw(at: origin, withAttributes: attributes)
            context.compositingOperation = .sourceOver
        }
        return copy
    }

    private static func glyphString(for badge: Badge) -> NSAttributedString {
        let text = badge == .question ? "?" : "!"
        return NSAttributedString(string: text)
    }
}
