import Foundation

/// 主应用窗口可见性监视器（迷你框三态判定的 iii 支持）。
///
/// 数据源：主应用壳在自己窗口最小化/恢复时经 DistributedNotificationCenter
/// 广播 `com.deepseek-ai.dsh-desktop.windowState`，userInfo["visible"] 为 Bool。
/// Launcher 只做被动监听并维护一个内存布尔位——即用即弃、零缓存零落盘，
/// 主应用退场后该值自然过期（配合进程判活使用，见 MiniDialogPolicy）。
///
/// 在主应用壳尚未加广播能力之前，lastKnownVisible 恒为 nil，
/// 判定层会保守地把"应用在跑"视为可见（快捷键失效），不会误弹双输入面。
@MainActor
final class VisibilityMonitor {
    static let notificationName = "com.deepseek-ai.dsh-desktop.windowState"

    /// nil = 从未收到广播（信号不可用）；true=可见；false=已最小化或隐藏
    private(set) var lastKnownVisible: Bool?

    private var observing = false

    func start() {
        guard !observing else { return }
        observing = true
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(windowStateChanged(_:)),
            name: NSNotification.Name(Self.notificationName),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func windowStateChanged(_ notification: Notification) {
        guard let value = notification.userInfo?["visible"] else { return }
        switch value {
        case let flag as Bool:  lastKnownVisible = flag
        case let num as NSNumber: lastKnownVisible = num.boolValue
        default: break
        }
    }
}
