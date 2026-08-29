import Foundation

/// 后端三态判定结果。
///
/// - healthy:     3080 返回 200 且携带桥接插件的健康标记（ok + pid）
/// - transitional: 有进程在监听 3080 但不满足绿色条件（启动中 / 半开连接 / 端口被陌生服务占用）
/// - down:        无任何进程监听 3080（连接被拒）
///
/// 判定语义来自 v1 对齐卡 A1：查询类信息（版本号）只进 tooltip，
/// 不参与状态机；未知错误保守归入 transitional 而非 down，避免启动窗口误报红灯。
enum BackendState: Equatable {
    case healthy
    case transitional
    case down
}

/// 自适应健康轮询（对齐卡 A3）：
/// 稳态 30s 一次；状态发生变化后的 60s 内加密到 5s 以快速反映启动/退出过程；
/// 菜单展开或迷你框唤起时由外部调用 `refreshNow()` 强制补测一次。
///
/// 功耗约束（用户红线）：只保留 volatile 当前态，不落任何缓存/历史；
/// 定时器以单实例 Timer 惰性重排实现，空闲期每 30s 才有一次本地回环请求。
@MainActor
final class StatusProbe {
    private(set) var state: BackendState = .down
    private(set) var detail: String = ""          // tooltip 文案，随每次探测刷新
    var onChange: ((BackendState, String) -> Void)?

    private var timer: Timer?
    /// 状态突变后保持高频探测的截止时刻；nil 表示处于稳态
    private var burstDeadline: Date?
    /// 在途防护：refreshNow 与定时 tick 并发时合并为一次真实请求（对齐审查 P2-2）
    private var probing = false
    /// 首探强制回调：即便结果与初始 down 相同也要让 UI 拿到真实 detail（审查 P2-1）
    private var forceEmitNext = true

    /// 探测目标固定为桥接插件的 status 端点（数据源即桌面桥，见 dsh-handoff 层次勘误节）。
    /// 注意端口写死 3080 与主应用 ServerManager 的默认口一致；将来若做可配置端口，
    /// 这里与 MiniDialogClient 必须同源改动。
    private let url = URL(string: "http://127.0.0.1:3080/api/desktop/status")!

    func start() {
        Task { await self.tick() }
    }

    /// 外部强制补测（菜单即将展开、迷你框弹出前）。立即探测一次并重排下一次稳态计时。
    func refreshNow() {
        Task { await self.tick() }
    }

    private func scheduleNext() {
        timer?.invalidate()
        let interval: TimeInterval = (burstDeadline ?? .distantPast) > Date() ? 5 : 30
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.tick() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() async {
        // 在途合并：上一轮还没回来就不叠加并发请求，直接把节奏交给 scheduleNext
        guard !probing else { return }
        probing = true
        defer { probing = false }

        let result = await Self.probe(url: url)
        let forceEmitting = forceEmitNext
        forceEmitNext = false
        let changed = result.state != state || result.detail != detail || forceEmitting
        state = result.state
        detail = result.detail
        if changed {
            // 进入过渡期加密节奏；回归绿色稳态时同样短暂加密确认一次再回落
            burstDeadline = Date().addingTimeInterval(60)
            onChange?(state, detail)
        }
        scheduleNext()
    }

    /// 单次网络判定。独立成静态函数便于单测注入假 URL。
    nonisolated private static func probe(url: URL) async -> (state: BackendState, detail: String) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData   // 状态判定绝不吃本地缓存（审查 P1-2）
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode.description ?? "?"
                return (.transitional, "端口有响应但非 200（HTTP \(code)），可能是启动中或被其他服务占用")
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (.transitional, "端口在监听但响应不是桥接健康报文，可能被陌生服务占用")
            }
            // ok + pid 同时在场才认定是自家桥接（照抄主应用 BridgeClient 的判据粒度）
            guard obj["ok"] as? Bool == true, (obj["pid"] as? Int ?? 0) > 0 else {
                return (.transitional, "端口在监听但健康标记缺失")
            }
            let version = obj["version"] as? String ?? "?"
            let uptimeMs = obj["uptimeMs"] as? Int ?? 0
            return (.healthy, "DSH Desktop 后端运行中 · v\(version) · 已运行 \(uptimeMs / 1000)s")
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                // 连接被拒 ≙ 端口无人监听，对齐卡里的红色语义
                return (.down, "DSH Desktop 后端未运行")
            case .timedOut:
                // 半开/高负载场景归入过渡，等待下一轮密集探测收敛
                return (.transitional, "探测超时，端口疑似半开")
            default:
                return (.transitional, "探测异常：\(error.code.rawValue)")
            }
        } catch {
            return (.transitional, "探测异常：\(error.localizedDescription)")
        }
    }
}
