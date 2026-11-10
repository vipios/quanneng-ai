//
//  SelfUpdate.swift
//  Minis — 自有版本线的更新检查与自动下载
//
//  ============================================================
//  [R40-内置更新源] 这一版推翻了原来的设计，改动集中在三点
//
//  1. 更新源不再让用户填，内置成常量 `builtinRepo`。
//     原来的设计要用户去设置里写「用户名/仓库名」，理由是「不能回落到
//     原版仓库」。那个理由本身没错，但结论错了：这个包只有一个发布来源，
//     让用户填一个我们早就知道的值，是把他当配置员用。
//     现在把仓库写死，仍然绝不触碰原版 —— 两件事并不冲突。
//
//  2. 「检查更新」从「查一下告诉你有没有」变成「查 → 测速 → 自动下载」。
//     用户 2026-11-10 18:52 的原话：「让我点击检查更新就会自动判定哪个
//     线路最快，然后他就自动下载了」。所以这条路必须自己走完，
//     不能停在「发现新版本，请去浏览器」。
//
//  3. 测速和下载共用同一条线路。哪条线路在竞速里赢了，就用它拼下载
//     地址 —— 已经测出来的结论没有理由再猜第二次。
//
//  版本线约定（未变）
//  ----------------------------------------------------------
//  这个 App 从 1.0 起步，和原版 1.15.x 没有任何大小关系。
//  比较只在「我们自己的 release」和「我们自己的版本号」之间发生。
//  ============================================================

import Foundation

// MARK: - 配置变更通知

extension Notification.Name {
    /// 更新源被改过。
    ///
    /// [R40] 更新源现在内置、用户改不了，这个通知的触发点只剩
    /// 一处：开发者改代码换仓库（那不需要通知）。保留它是因为
    /// 关于页仍在监听它刷新仓库链接，删掉会让那处失去响应。
    static let selfUpdateSourceChanged = Notification.Name("minis.selfupdate.sourceChanged")
}

// MARK: - 结果模型

/// 一次更新检查的结果。界面只读这个，不碰网络细节。
///
/// `Sendable`：`check()` 是 async，结果要被带回主线程的 @State。
enum SelfUpdateResult: Equatable, Sendable {
    /// [R40] 保留了 but 不再产生：更新源内置，没有「未配置」这个状态了。
    /// 留着枚举分支是为了不让外面所有 switch 都改一遍 —— 界面上的
    /// 分支已经删掉，这里保留一个不可达值比大范围改签名安全。
    case notConfigured
    /// 查过了，已经是最新（附带远端 tag、走的线路、耗时）
    case upToDate(remote: String, line: String, ms: Int)
    /// 查过了，远端更新（此时下载还没开始）
    case updateAvailable(remote: String, line: String, ms: Int)
    /// 查过了但失败（网络 / 仓库不存在 / 没有 release）
    case failed(reason: String)

    /// 界面用的一行话
    var message: String {
        switch self {
        case .notConfigured:
            return "更新源没配好（这是 App 的问题，不是你操作错）"
        case .upToDate(let r, let line, let ms):
            return "已是最新 v\(r) · \(line) \(ms)ms"
        case .updateAvailable(let r, let line, let ms):
            return "有新版 v\(r) · \(line) \(ms)ms"
        case .failed(let reason):
            return reason
        }
    }
}

// MARK: - 下载结果

/// 自动下载的进展。界面靠它显示徽标文字。
///
/// 独立于 `SelfUpdateResult`：检查是一次性结论，下载是持续过程，
/// 混在一个枚举里会让「下载到 40% 时该显示什么」变得没法表达。
enum SelfUpdateDownload: Equatable, Sendable {
    case idle
    /// 正在下载，0…1
    case progress(Double, totalBytes: Int64)
    /// 下好了，给本地文件地址
    case finished(URL)
    case failed(String)
}

// MARK: - 检查器

enum SelfUpdate {

    // MARK: 版本线

    /// 我们自己的版本号。**不从 Bundle 读**。
    ///
    /// 理由：Bundle 里的值随构建配置变，而「跟谁比自己」这件事必须
    /// 只有一处定义。pbxproj 里的 1.0 与此处的常量必须同步。
    static let currentVersion: [Int] = [1, 0, 0]

    /// 构建号。显示用，不参与版本比较。
    static let currentBuild: Int = 42

    /// 界面上显示的完整版本串
    static var displayVersion: String {
        "\(currentVersion.map(String.init).joined(separator: ".")) (\(currentBuild))"
    }

    // MARK: 内置更新源

    /// [R40-内置更新源] 唯一的发布仓库。用户看不到、改不了。
    ///
    /// 换仓库只改这一行。原型里对应 `BUILTIN_REPO`（联动模板-完整.html），
    /// 两处必须一致 —— 否则原型演示的版本和真机查的版本会对不上。
    static let builtinRepo = "vipios/quanneng-ai"

    /// 供界面显示（关于页的仓库链接）。恒等于内置值。
    static var repo: String { builtinRepo }

    /// 永远是 true。保留这个属性是因为关于页还在读它。
    static var isConfigured: Bool { true }

    /// [R40] 用户已经不能改更新源了，这个方法强制返回 false。
    ///
    /// 之所以不直接删：`SettingsRename` / 关于页还有引用的地方，
    /// 删掉会牵连一串编译错误，而那些地方跟这次改动无关。
    /// 返回 false 表示「写入被拒绝」，语义正确且无害。
    @discardableResult
    static func setRepo(_ raw: String) -> Bool {
        false
    }

    // MARK: 线路

    /// 一条候选线路。
    ///
    /// `name` 只用于界面上告诉用户「这次走的哪条」；`prefix` 用来拼下载地址。
    /// 存字符串不存闭包：闭包属性在 Swift 6 并发检查下要满足 Sendable，
    /// 而 static let 数组一旦被判定为全局可变状态就会报警告。
    struct Line: Sendable {
        let id: String
        let name: String
        /// 下载用的前缀。直连为空串，加速站就是自己的域名 + 斜杠。
        let prefix: String
        /// API 地址模板，含 %@ 占位符（放 repo）
        let apiTemplate: String
    }

    /// 四条线路。2026-11-10 实测：ghfast 最快，ghproxy.net 次之，
    /// 直连在国内多数时候打不通，gh-proxy.com 最慢但活着。
    ///
    /// 顺序不代表优先级 —— 每次都是并发竞速，谁快用谁。
    static let lines: [Line] = [
        Line(id: "fast",
             name: "加速 A",
             prefix: "https://ghfast.top/",
             apiTemplate: "https://ghfast.top/https://api.github.com/repos/%@/releases/latest"),
        Line(id: "proxy",
             name: "加速 B",
             prefix: "https://ghproxy.net/",
             apiTemplate: "https://ghproxy.net/https://api.github.com/repos/%@/releases/latest"),
        Line(id: "direct",
             name: "直连",
             prefix: "",
             apiTemplate: "https://api.github.com/repos/%@/releases/latest"),
        Line(id: "slow",
             name: "加速 C",
             prefix: "https://gh-proxy.com/",
             apiTemplate: "https://gh-proxy.com/https://api.github.com/repos/%@/releases/latest"),
    ]

    /// 单条线路的超时。实测直连经常 3-8 秒才失败，9 秒是「基本确定不行」的位置。
    private static let lineTimeout: TimeInterval = 9

    // MARK: 检查

    /// 一次检查的完整产物：给界面看的结果 + 给下载用的胜出线路。
    ///
    /// 为什么要把两者绑在一起返回，而不是让 `check()` 存一个
    /// 「上次赢的线路」到静态变量里，再让下载去读：
    ///   · 静态可变全局状态在 Swift 6 严格并发下直接编译失败
    ///     （nonisolated global shared mutable state）；
    ///   · 就算加 nonisolated(unsafe) 绕过去，也是个真 bug 源 ——
    ///     两次检查交错时，下载可能拿到上一次的线路和这一次的 tag，
    ///     拼出一个必然 404 的地址。
    /// 用返回值传递，天然没有这个问题。
    struct Outcome: Sendable {
        let result: SelfUpdateResult
        /// 竞速赢家。nil 表示全部线路都失败。
        let win: Win?
    }

    /// 检查更新。**[R40] 不再有「未配置」这条早退**。
    static func check() async -> Outcome {
        guard let win = await race(repo: builtinRepo) else {
            return Outcome(result: .failed(reason: "四条线路都连不上，检查一下网络"),
                           win: nil)
        }

        let remote = win.tag
        let remoteParts = remote
            .split(separator: ".")
            .map { Int($0) ?? 0 }

        let r: SelfUpdateResult = compare(remoteParts, currentVersion) > 0
            ? .updateAvailable(remote: remote, line: win.line.name, ms: win.ms)
            : .upToDate(remote: remote, line: win.line.name, ms: win.ms)
        return Outcome(result: r, win: win)
    }

    // MARK: 线路竞速

    /// 一条线路的结果。必须 Sendable：要跨 task group 的并发域传回来。
    struct Win: Sendable {
        let tag: String
        let line: Line
        let ms: Int
        /// release 里的资产名与下载地址（原始 github.com 直链，未加前缀）
        let ipaName: String?
        let ipaURL: String?
        let ipaSize: Int64
    }

    /// 全部线路同时打，第一个拿到有效 release 的胜出。
    ///
    /// 用 `withTaskGroup` 而不是 detached task：group 退出时会等所有
    /// 子任务收尾，不会留野任务在后台跑。提前获胜时 `cancelAll()`，
    /// 已发出的请求靠 timeoutInterval 自然结束。
    static func race(repo: String) async -> Win? {
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

    /// 打一条线路。任何失败都返回 nil —— 竞速场景下失败没有信息量。
    private static func probe(line: Line, repo: String) async -> Win? {
        guard let url = URL(string: line.apiTemplate.replacingOccurrences(of: "%@", with: repo))
        else { return nil }

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

            // 找出可安装的包。找 .ipa / .tipa，没有就留 nil ——
            // 「有新版本但没有包」要能如实说出来，不能假装成功。
            var ipaName: String?
            var ipaURL: String?
            var ipaSize: Int64 = 0
            if let assets = obj["assets"] as? [[String: Any]] {
                for a in assets {
                    guard let n = a["name"] as? String else { continue }
                    let lower = n.lowercased()
                    guard lower.hasSuffix(".ipa") || lower.hasSuffix(".tipa") else { continue }
                    ipaName = n
                    ipaURL = a["browser_download_url"] as? String
                    ipaSize = (a["size"] as? NSNumber)?.int64Value ?? 0
                    break
                }
            }

            return Win(tag: tag, line: line, ms: ms,
                       ipaName: ipaName, ipaURL: ipaURL, ipaSize: ipaSize)
        } catch {
            return nil
        }
    }

    // MARK: 拼下载地址

    /// 把 release 的原始直链套上胜出线路的加速前缀。
    ///
    /// 直连线路的 prefix 是空串，拼出来就是原地址 —— 不用特判。
    static func downloadURL(for win: Win) -> URL? {
        guard let raw = win.ipaURL, !raw.isEmpty else { return nil }
        return URL(string: win.line.prefix + raw)
    }

    // MARK: 下载

    /// 自动下载 ipa，带进度回调。
    ///
    /// 用 `URLSession.download` 而不是 `data(for:)`：这个包 80MB，
    /// 装进内存既浪费又可能被杀。download 落的是临时文件，直接拿到路径。
    ///
    /// 进度回调声明为 `@Sendable` 而不是 `@MainActor`：
    /// 它会被 URLSession 的后台队列调用，标 @MainActor 会在 Swift 6
    /// 严格并发下报「跨隔离域捕获」。调用方自己跳回主线程 —— 见
    /// `SelfUpdateSection` 里 `Task { @MainActor in ... }` 那一层。
    ///
    /// 不用 `AsyncStream.makeStream()`：那是 iOS 17 才有的 API，
    /// 而本工程部署目标是 16.0。为了一点进度信号把最低版本抬上去不值。
    static func download(
        win: Win,
        onProgress: @escaping @Sendable (Double, Int64) -> Void
    ) async throws -> URL {
        guard let url = downloadURL(for: win) else {
            throw SelfUpdateError.noAsset
        }

        var req = URLRequest(url: url)
        // 大文件给足时间。9 秒是「测 API 通不通」的量级，
        // 下 80MB 用这个值会必然超时。
        req.timeoutInterval = 300
        req.setValue("Minis-SelfUpdate", forHTTPHeaderField: "User-Agent")

        let delegate = ProgressDelegate(onProgress: onProgress)

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = req.timeoutInterval
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (tmp, resp) = try await session.download(for: req)
        delegate.stop()

        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SelfUpdateError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // 挪到 Documents/Updates/ 下，文件名保持 release 里的原样。
        // 放 tmp 里会被系统随时清掉，用户还没点安装就没了。
        let dir = try updatesDir()
        let name = win.ipaName ?? "QuanNengAI.ipa"
        let dest = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Documents/Updates/。不存在就建。
    static func updatesDir() throws -> URL {
        let base = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent("Updates", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: 版本比较

    /// 逐段比大小。缺的段当 0 处理，所以 `1.0` 与 `1.0.0` 相等。
    /// 返回 1 = a 大，-1 = b 大，0 = 相等。
    static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<Swift.max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }
}

// MARK: - 错误

enum SelfUpdateError: LocalizedError {
    /// release 里没有 .ipa / .tipa
    case noAsset
    case http(Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noAsset:
            return "这个版本里没有可安装的包"
        case .http(let c):
            return "下载失败，HTTP \(c)"
        case .cancelled:
            return "下载已取消"
        }
    }
}

// MARK: - 进度代理

/// URLSession 的下载进度回调，转成闭包。
///
/// 单独一个类而不是让 `SelfUpdate` 自己去实现 delegate：
/// `SelfUpdate` 是 enum 命名空间，让它符合 URLSessionDownloadDelegate
/// 需要变成 class + NSObject，那会破坏「没有状态」这个前提。
///
/// `@unchecked Sendable`：这个类确实会被两个线程碰（URLSession 的
/// delegate 队列写、主线程 stop），所以有两个真是状态的东西要用锁护住。
/// delegate 队列是串行的，`stopped` 用 NSLock 保护就够 ——
/// 这是实测能过 Swift 6 严格并发、且没有真实竞态的最小写法。
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let onProgress: @Sendable (Double, Int64) -> Void
    private let lock = NSLock()
    private var stopped = false

    init(onProgress: @escaping @Sendable (Double, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock(); let s = stopped; lock.unlock()
        guard !s, totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(min(max(p, 0), 1), totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // download(for:) 的 async 版本会自己取这个文件，
        // 这个 delegate 方法只是协议要求，不用做事。
        _ = location
    }
}
