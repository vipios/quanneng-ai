//
//  SelfUpdate.swift
//  Minis — 自有版本线的更新检查
//
//  ============================================================
//  为什么需要这个文件（以及为什么它不是「改个 URL」）
//
//  原版 App 的更新检查指向 `OpenMinis/OpenMinis` 的 releases API。
//  我们的改造版如果沿用这条路径，会有两个必然后果：
//
//    1. 我们的版本号一旦落后于原版，启动就提示「发现新版本」；
//    2. 用户点了更新，装回来的是**原版**，改造内容全被覆盖。
//
//  这不是把 `MARKETING_VERSION` 调高就能绕过的 —— 那只是把撞车
//  推迟到原版下次发版。要真正切断，必须把「更新源」从代码常量
//  变成用户自己的仓库，并且**没有配置时明确不检查**，绝不回落到
//  原版仓库。
//
//  版本线约定
//  ----------------------------------------------------------
//  这个 App 从 1.0.0 起步，和原版 1.15.x 没有任何大小关系。
//  比较只在「我们自己的 release」和「我们自己的 build」之间发生。
//
//  更新源
//  ----------------------------------------------------------
//  用户在设置里填 `用户名/仓库名`，存 UserDefaults（不是秘密，
//  和 GitHubPush.repo 一样处理）。空 = 未配置 = 不检查。
//
//  三条线路竞速
//  ----------------------------------------------------------
//  api.github.com 在国内经常打不开，实测两个加速前缀可用。
//  三条同时打，第一个返回有效 JSON 的胜出，其余立刻 abort。
//  ============================================================

import Foundation

// MARK: - 配置变更通知

extension Notification.Name {
    /// 更新源被改过。
    ///
    /// `SelfUpdate` 刻意是纯 UserDefaults 读写（没有 ObservableObject），
    /// 好处是任何地方都能同步取值、不用管 actor 隔离；代价是改完不会
    /// 自动通知 SwiftUI。所以写入口 `setRepo` 之后由调用方广播这个通知，
    /// 读取方（关于页的仓库链接、设置页的 footer）监听它重新求值。
    static let selfUpdateSourceChanged = Notification.Name("minis.selfupdate.sourceChanged")
}

// MARK: - 结果模型

/// 一次更新检查的结果。界面只读这个，不碰网络细节。
///
/// `Sendable`：`check()` 是 async，结果要被带回主线程的 @State。
enum SelfUpdateResult: Equatable, Sendable {
    /// 还没填更新源。这是**正常状态**，不是错误。
    case notConfigured
    /// 查过了，已经是最新（附带远端 tag，便于确认查的是哪个版本）
    case upToDate(remote: String, line: String, ms: Int)
    /// 查过了，远端更新
    case updateAvailable(remote: String, line: String, ms: Int)
    /// 查过了但失败（网络 / 仓库不存在 / 没有 release）
    case failed(reason: String)

    /// 界面用的一行话
    var message: String {
        switch self {
        case .notConfigured:
            return "还没配更新源，先在上面填你自己的仓库"
        case .upToDate(let r, let line, let ms):
            return "已是最新 \(r) · \(line) \(ms)ms"
        case .updateAvailable(let r, let line, let ms):
            return "有新版 \(r) · \(line) \(ms)ms"
        case .failed(let reason):
            return reason
        }
    }
}

// MARK: - 检查器

/// 自有版本线的更新检查。
///
/// 刻意做成 `enum` 命名空间而不是 class：没有状态要持有，
/// 每次调用都是「读配置 → 打网络 → 返回一个值」。
/// 这也是它不需要 @MainActor 的原因。
enum SelfUpdate {

    // MARK: 版本线

    /// 我们自己的版本号。**不从 Bundle 读**。
    ///
    /// 理由：Bundle 里的值随构建配置变（pbxproj 的 MARKETING_VERSION），
    /// 而「跟谁比自己」这件事必须只有一处定义。读 Bundle 会在
    /// Debug/Release 不一致时给出不同的比较结果，那种 bug 极难查。
    /// pbxproj 里的 1.0 与此处的常量必须同步，改动时两处一起改。
    static let currentVersion: [Int] = [1, 0, 0]

    /// 构建号。显示用，不参与版本比较。
    static let currentBuild: Int = 42

    /// 界面上显示的完整版本串
    static var displayVersion: String {
        "\(currentVersion.map(String.init).joined(separator: ".")) (\(currentBuild))"
    }

    // MARK: 配置

    private static let kRepoKey = "minis.selfupdate.repo"

    /// 用户填的更新源，形如 `用户名/仓库名`。空串 = 未配置。
    ///
    /// 归一化在写入时做（`setRepo`），读的时候直接返回 ——
    /// 这样界面永远拿到干净值，不用每次都 trim/去前缀。
    static var repo: String {
        UserDefaults.standard.string(forKey: kRepoKey) ?? ""
    }

    static var isConfigured: Bool { !repo.isEmpty }

    /// 写入更新源。传空串表示清空。
    ///
    /// 顺手做了两件归一化，因为用户很可能直接粘整条 URL：
    ///   - 去掉 `https://github.com/` 前缀
    ///   - 去掉尾部斜杠
    /// 非法格式（不是恰好两段）返回 false，界面据此提示。
    @discardableResult
    static func setRepo(_ raw: String) -> Bool {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 粘整条 URL 是最常见的输入方式
        if let r = t.range(of: "github.com/", options: .caseInsensitive) {
            t = String(t[r.upperBound...])
        }
        while t.hasSuffix("/") { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)

        if t.isEmpty {
            UserDefaults.standard.removeObject(forKey: kRepoKey)
            return true
        }
        guard t.split(separator: "/").count == 2 else { return false }
        UserDefaults.standard.set(t, forKey: kRepoKey)
        return true
    }

    // MARK: 线路

    /// 一条候选线路。`name` 只用于界面上告诉用户「这次走的哪条」，
    /// 不参与任何判断 —— 谁快用谁，不预设偏好。
    ///
    /// 只存 URL 模板字符串、不存闭包：闭包属性在 Swift 6 并发检查下
    /// 要满足 Sendable，而 `static let` 数组一旦被判定为全局可变状态
    /// 就会报警告。存字符串 + 一个拼装函数，既简单又不用打标记。
    private struct Line: Sendable {
        let name: String
        let template: String          // 含 %@ 占位符
        func url(repo: String) -> URL? {
            URL(string: template.replacingOccurrences(of: "%@", with: repo))
        }
    }

    private static let lines: [Line] = [
        Line(name: "直连",
             template: "https://api.github.com/repos/%@/releases/latest"),
        Line(name: "加速 A",
             template: "https://ghfast.top/https://api.github.com/repos/%@/releases/latest"),
        Line(name: "加速 B",
             template: "https://gh-proxy.com/https://api.github.com/repos/%@/releases/latest"),
    ]

    /// 单条线路的超时。实测直连经常 3-8 秒才失败，9 秒是「基本确定不行」的位置。
    private static let lineTimeout: TimeInterval = 9

    // MARK: 检查

    /// 检查更新。没有配置更新源时立即返回 `.notConfigured`，
    /// **不发任何网络请求** —— 这一点是关键，别改成「默认查原版」。
    static func check() async -> SelfUpdateResult {
        let repo = repo
        guard !repo.isEmpty else { return .notConfigured }

        guard let win = await race(repo: repo) else {
            return .failed(reason: "连不上 \(repo)，检查仓库名或网络")
        }

        let remote = win.tag
        let remoteParts = remote
            .split(separator: ".")
            .map { Int($0) ?? 0 }

        if compare(remoteParts, currentVersion) > 0 {
            return .updateAvailable(remote: remote, line: win.line, ms: win.ms)
        }
        return .upToDate(remote: remote, line: win.line, ms: win.ms)
    }

    // MARK: 三线路竞速

    /// 一条线路的结果。
    ///
    /// 必须 `Sendable`：这个值要跨 task group 的并发域传回来。
    /// 全是 String/Int，编译器能自动合成。
    private struct Win: Sendable {
        let tag: String
        let line: String
        let ms: Int
    }

    /// 三条同时打，第一个拿到有效 release 的胜出。
    ///
    /// 用 `withTaskGroup` 而不是三个 detached task：group 在函数
    /// 退出时会等所有子任务收尾，不会留下野任务在后台跑。
    /// 提前获胜时把 `winner` 置位，其余任务看到就返回 nil，
    /// 已经发出的请求靠 `timeoutInterval` 自然结束。
    private static func race(repo: String) async -> Win? {
        await withTaskGroup(of: Win?.self) { group in
            for line in lines {
                group.addTask { await probe(line: line, repo: repo) }
            }

            var winner: Win?
            for await w in group {
                if let w {
                    winner = w
                    group.cancelAll()
                    break
                }
            }
            return winner
        }
    }

    /// 打一条线路。任何失败都返回 nil —— 竞速场景下失败没有信息量，
    /// 只有「全都失败」才需要给用户看，那由调用方统一出文案。
    private static func probe(line: Line, repo: String) async -> Win? {
        guard let url = line.url(repo) else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = lineTimeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub API 不接受没有 User-Agent 的请求
        req.setValue("Minis-SelfUpdate", forHTTPHeaderField: "User-Agent")

        let t0 = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagRaw = obj["tag_name"] as? String
            else { return nil }

            // v1.2.0 / 1.2.0 都接受
            let tag = tagRaw.hasPrefix("v") || tagRaw.hasPrefix("V")
                ? String(tagRaw.dropFirst())
                : tagRaw
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            return Win(tag: tag, line: line.name, ms: ms)
        } catch {
            return nil
        }
    }

    // MARK: 版本比较

    /// 逐段比大小。缺的段当 0 处理，所以 `1.0` 与 `1.0.0` 相等。
    /// 返回 1 = a 大，-1 = b 大，0 = 相等。
    ///
    /// `Swift.max` 显式限定：这个类型里没有同名成员，但现在不冲突
    /// 不代表以后不会 —— 写全了编译期一眼就知道指的是标准库那个。
    static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<Swift.max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }
}
