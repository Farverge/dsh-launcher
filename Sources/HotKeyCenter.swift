import AppKit
import Carbon.HIToolbox

/// 全局热键 ⌘⇧D（2026-08-28 用户改定：原 ⌥⌘D 与系统"显示/隐藏程序坞"冲突）。
/// Carbon 修饰键掩码不分左右侧。注意全局热键会吞掉同组合键的 App 级快捷方式
/// （Finder 的 ⌘⇧D"前往桌面"在本 launcher 运行期间不可用）——用户已知情选定。
/// 由 Launcher 持有：它是常驻进程，天然适合作为热键归属方。
///
/// 轻量化说明：仅在系统事件表里注册一次热键引用，无轮询、无常驻监听线程；
/// 未按键时 CPU 占用为零。热键句柄随进程存活，无需注销路径。
enum HotKeyCenter {
    /// kVK_ANSI_D = 2；cmdKey(1<<8) | shiftKey(1<<9) = 768
    private static var hotKeyRef: EventHotKeyRef?
    private static var handler: (() -> Void)?

    /// 注册成功返回 true；失败（极少见，如被其他工具占用同组合键的竞争场景
    /// 实际不会发生——全局热键允许共存，只按注册顺序分发）打印警告但不崩溃。
    static func install(handler: @escaping () -> Void) {
        Self.handler = handler

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // C 回调进入点：把事件转发回 Swift 闭包。静态单槽对本进程唯一热键足够。
        let callback: EventHandlerUPP = { _, _, _ in
            MainActor.assumeIsolated {
                HotKeyCenter.handler?()
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, nil)

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x44534831), /* "DSH1" */ id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_D),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            NSLog("[dsh-launcher] 热键注册失败 status=%d", status)
        }
    }
}
