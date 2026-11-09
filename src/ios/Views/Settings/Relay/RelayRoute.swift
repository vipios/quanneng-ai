//
//  RelayRoute.swift
//  Minis — 中转站 / 路由器线路判定
//
//  这套判定逻辑来自 Cabin（2026-11-08 真机实测），结论已固化，**不要再改**。
//
//  ============================================================
//  一、为什么不用 WiFi 名判「在不在家」
//
//  真机诊断页实测 `wifi="nil"`：TrollStore 装的 App 拿不到读 SSID 的
//  entitlement，NEHotspotNetwork 和 CNCopyCurrentNetworkInfo 都返回 nil。
//  拿它当主判据 → 主判据永远是 nil → 每次都掉进兜底分支 → 结果乱七八糟。
//
//  所以：**WiFi 名这条路是死的，不能当主判据。**
//
//  ============================================================
//  二、为什么只探用户配置的那一个地址
//
//  实测 .88 和 .250 是同一台设备的两个 IP，扫到哪个都可能；更糟的是
//  扫完把结果写回用户配置，把用户填的 .88 覆盖成 .250。
//
//  所以：**只探用户配置的那一个地址，不扫网段、不改配置。**
//
//  ============================================================
//  三、为什么必须看 service 字段，不能只看 HTTP 200
//
//  家里网段上可能有别的东西占着 8080（实测网关 .1 就回了 no_cmd_match
//  的 200），只要回 200 就当真会误判。
//
//  ============================================================
//  四、为什么必须判准（差 35 倍）
//
//  内网 192.168.1.88:8080 = 0.07 秒
//  域名 lidongyang.dpdns.org = 2.5 秒
//  在家里走域名就是白白慢 35 倍。
//  ============================================================

import Foundation
import Network

// MARK: - 线路

/// 一条线路。中转站与路由器两个界面共用同一个判定结果，
/// 不会出现「中转站认为在家、路由器认为在外」。
struct RelayRoute: Equatable {

    enum Kind: String {
        case lan
        case wan
    }

    var kind: Kind
    /// 纯 host，**不含协议与端口**。协议和端口由这里按线路决定。
    var host: String

    var isLan: Bool { kind == .lan }

    /// 中转站后台（relay.py 网页 + /admin/api/*）
    /// 内网固定 8080（relay 监听端口），域名走 443 由 Cloudflare 隧道转进去。
    var adminBase: String {
        kind == .lan ? "http://\(host):8080" : "https://\(host)"
    }

    /// 路由器指令（uhttpd 的 /cgi-bin/airboot）
    /// 内网 80，域名 443 —— 实测两台服务在同一台设备、同一个 443。
    var bootBase: String {
        kind == .lan ? "http://\(host)" : "https://\(host)"
    }

    /// 给人看的一行
    var label: String {
        kind == .lan ? "在家 · 直连" : "在外 · 域名"
    }

    var detail: String {
        kind == .lan ? "本地网络，最快" : "公网隧道，绕一圈"
    }

    var icon: String {
        kind == .lan ? "house.fill" : "globe.asia.australia.fill"
    }

    /// 当前实际在用的地址（带端口），给界面显示用
    var displayAddress: String {
        kind == .lan ? "\(host):8080" : host
    }
}

// MARK: - 判定

enum RelayProbe {

    /// 判定超时。内网正常 70ms，给 1.2 秒已经很宽松；
    /// 超过就当不通 —— 宁可判「在外」走域名，也不能让界面卡着。
    static let timeout: TimeInterval = 1.2

    /// **唯一入口**：现在该走哪条线。
    ///
    /// 只探用户配置的家里地址，一个请求，不扫网段、不改配置。
    static func resolve() async -> RelayRoute {
        let home = RelayVault.shared.homeHost
        let away = RelayVault.shared.awayHost

        let ok = await reachable(home: home)
        let route = ok ? RelayRoute(kind: .lan, host: home)
                       : RelayRoute(kind: .wan, host: away)

        RelayLog.log("判定：探 \(home):8080 → \(ok ? "通" : "不通") → \(route.kind.rawValue) \(route.host)")
        return route
    }

    /// 家里直连地址通不通。
    ///
    /// 判据用 relay 的 `/health`：
    ///   {"status":"ok","service":"ai-relay",...}
    /// 认 `service` 字段而不是「有 HTTP 响应就算通」—— 见文件头第三条。
    static func reachable(home: String) async -> Bool {
        let host = RelayVault.cleanHost(home)
        guard !host.isEmpty, let url = URL(string: "http://\(host):8080/health") else {
            return false
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 0.6
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        // ⚠️ 用 NSMutableURLRequest 而不是 URLRequest 的 Swift 属性 setter：
        //    `req.httpMethod = ...` / `req.timeoutInterval = ...` 在旧系统上是
        //    缺失的 ABI 符号，调用即 dyld: Symbol not found，App 启动就闪退。
        //    ObjC 消息跨 iOS 14–17 稳定，所以走 mutableCopy。
        let m = NSMutableURLRequest(url: url)
        m.timeoutInterval = timeout
        m.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        m.setValue("Minis/\(RelayDeviceInfo.appVersion) CFNetwork/1410.0.3 Darwin/22.6.0",
                   forHTTPHeaderField: "User-Agent")
        m.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, resp) = try? await session.data(for: m as URLRequest),
              let code = (resp as? HTTPURLResponse)?.statusCode,
              (200...299).contains(code)
        else { return false }

        guard let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let svc = doc["service"] as? String
        else { return false }

        // "ai-relay" / "relay" 都认
        return svc.lowercased().contains("relay")
    }
}

// MARK: - 本地网络授权

enum RelayLocalNet {
    /// 主动触发 iOS 的「允许访问本地网络」弹窗。
    ///
    /// iOS 14+ 对发往 192.168.x.x 的请求做权限门控。App 从没发起过 Bonjour
    /// 发现时系统**不弹窗**，而是让请求直接失败 —— 表现就是「连着家里
    /// WiFi 也连不上」。所以冷启动最早的时刻主动起一个 NWBrowser，
    /// 逼系统把弹窗弹出来。
    static func requestPermission() {
        let browser = NWBrowser(for: .bonjour(type: "_minis-relay._tcp", domain: nil),
                                using: .tcp)
        browser.start(queue: DispatchQueue(label: "minis.relay.localnet"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { browser.cancel() }
    }
}

// MARK: - 调试日志

/// 判定过程留痕，出问题时用户能自己看到「为什么走了域名」。
final class RelayLog {

    static let shared = RelayLog()
    private init() {}

    private var lines: [String] = []
    private let lock = NSLock()
    private let maxLines = 60

    static func log(_ s: String) {
        shared.append(s)
    }

    private func append(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let line = f.string(from: Date()) + "  " + s
        lock.lock()
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        lock.unlock()
    }

    var dump: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    var text: String {
        let all = dump
        return all.isEmpty ? "（暂无记录）" : all.joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }
}

// MARK: - 设备信息

enum RelayDeviceInfo {
    /// 只用来拼 UA（中转站前面挂着 Cloudflare，裸 UA 会被 1010 拒掉）
    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
}
