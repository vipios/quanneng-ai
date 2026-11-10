//
//  TemplateUIView.swift
//  全能AI - 用 WKWebView 承载设计稿（联动模板-完整.html）
//
//  ============================================================
//  为什么是 WebView，不是 SwiftUI
//  ------------------------------------------------------------
//  设计稿是一份 418KB 的自包含 HTML/CSS/JS，它本身就是成品：
//  抽屉的 318px 宽、行高 52、图标 29×29 圆角 7.5、分组标题 13pt/600、
//  搜索在抽屉内就地出结果、长按改名、说话模式七选一、中转站/路由器
//  三字段直填、自动判定在家在外 —— 全部是可执行代码。
//
//  用 SwiftUI 复刻它的每一个数值，结果一定是「哪里都不一样」：
//  字体度量、行高取整、圆角抗锯齿、阴影扩散都和浏览器不同，
//  而且每改一处都要重新对像素。所以这里直接让同一份文件在 App 里跑，
//  浏览器里怎么排，包里就怎么排。
//
//  分层
//  ------------------------------------------------------------
//      ZStack
//        ├ content()            原生 AIChatView（真实会话、真实发送）
//        ├ TemplateUIWebView    透明全屏，只画抽屉和全屏页
//        └ EdgePanOverlay       原生手势（识别左边缘右滑）
//
//  WebView 平时**完全不接收触摸**（isUserInteractionEnabled = false），
//  触摸直接穿透到下面的原生聊天界面。只有模板报告「抽屉/全屏页已打开」
//  时才变成可交互。这是整个方案能成立的关键 —— 否则一层透明的
//  WKWebView 会把输入框、发送按钮、消息长按全部吃掉。
//
//  数据流
//  ------------------------------------------------------------
//      Swift → JS：__MS__.setData(json)  真实会话与产物
//                  __MS__.openDrawer()  抽屉开（动画由模板自己跑）
//                  __MS__.setVersion(v) 版本号（原生是唯一真源）
//      JS → Swift：overlay { active, drawer, page }
//                  switchSession { id }
//                  newChat
//                  settingsRow { row }
//

import SwiftUI
import WebKit

// MARK: - 状态与桥

/// 一个 WebView 的控制器。SwiftUI 侧只跟它打交道，不直接持有 WKWebView。
@MainActor
final class TemplateUIHost: ObservableObject {

    /// 页面加载完成。没完成之前发 JS 全是空转，所以所有调用都先看它。
    @Published private(set) var ready = false

    /// 模板报上来的三个状态。`drawer` 和 `page` 要分开 ——
    /// 抽屉态右侧留 72pt 给原生关闭热区，全屏页态整屏归网页。
    @Published private(set) var drawerOpen = false
    @Published private(set) var pageOpen = false

    /// 网页里抛的错，原样攒着。真机上如果某段 JS 报错，这里能看到，
    /// 不用连 Safari 调试。
    ///
    /// 不是 private(set)：`makeUIView` 里「bundle 找不到 ui.html」这种
    /// 致命错也要写进来，那是 UI 层的事，不该为此再加一个 setter。
    @Published fileprivate(set) var jsError: String?

    weak var webView: WKWebView?

    var onSwitchSession: ((String) -> Void)?
    var onNewChat: (() -> Void)?
    var onSettingsRow: ((String) -> Void)?

    /// WebView 该不该接收触摸。
    var wantsInteraction: Bool { drawerOpen || pageOpen }

    // MARK: 调用

    private func call(_ js: String) {
        guard let wv = webView else { return }
        wv.evaluateJavaScript(js) { [weak self] _, err in
            guard let err else { return }
            Task { @MainActor in
                self?.jsError = "\(err.localizedDescription) ← \(js.prefix(60))"
            }
        }
    }

    func openDrawer() {
        call("window.__MS__ && window.__MS__.openDrawer()")
    }

    func closeDrawer() {
        call("window.__MS__ && window.__MS__.closeDrawer()")
    }

    /// 手势拖动期间调用：把抽屉摆到手指当前位置。
    ///
    /// `p` 是 0…1 的展开进度。模板那边会关掉 transition 直接改 transform，
    /// 所以调用频率跟着手势帧走也不会看到缓动拖尾。
    func dragTo(_ p: CGFloat) {
        let v = min(max(Double(p), 0), 1)
        call("window.__MS__ && window.__MS__.dragTo(\(String(format: "%.4f", v)))")
    }

    /// 松手：交回模板自己的 cubic-bezier 收尾。
    ///
    /// 不直接在 dragTo 里做，是因为拖动结束和「progress 变到 0/1」不一定
    /// 同时发生（比如拖到一半松手、判定为回到原位，progress 值没变）。
    func dragEnd(open: Bool) {
        call("window.__MS__ && window.__MS__.dragEnd(\(open ? "true" : "false"))")
    }

    /// 灌真实数据。
    ///
    /// 走 base64 而不是把 JSON 拼进 JS 字面量：会话标题里有引号、
    /// 换行、emoji、`</script>` 这类字符，拼字面量一定会炸；
    /// base64 只含 `A-Za-z0-9+/=`，怎么都不会破坏语法。
    func setData(_ json: String) {
        let b64 = Data(json.utf8).base64EncodedString()
        call("window.__MS__ && window.__MS__.setDataB64('\(b64)')")
    }

    func setVersion(_ v: String) {
        let safe = v.replacingOccurrences(of: "'", with: "")
        call("window.__MS__ && window.__MS__.setVersion('\(safe)')")
    }

    /// 从原生别处进来时直接开设置页（比如设置齿轮被别的地方触发）。
    func openSettings() {
        call("window.__MS__ && window.__MS__.openSettings()")
    }

    // MARK: 桥回调

    fileprivate func handle(_ body: [String: Any]) {
        guard let action = body["action"] as? String else { return }

        switch action {
        case "ready":
            ready = true

        case "overlay":
            drawerOpen = body["drawer"] as? Bool ?? false
            pageOpen = body["page"] as? Bool ?? false

        case "switchSession":
            if let id = body["id"] as? String, !id.isEmpty {
                onSwitchSession?(id)
            }

        case "newChat":
            onNewChat?()

        case "settingsRow":
            if let row = body["row"] as? String {
                onSettingsRow?(row)
            }

        case "error":
            jsError = (body["where"] as? String ?? "js") + ": "
                    + (body["msg"] as? String ?? "unknown")

        default:
            break
        }
    }
}

// MARK: - WebView 包装

struct TemplateUIWebView: UIViewRepresentable {

    @ObservedObject var host: TemplateUIHost

    func makeCoordinator() -> Coordinator {
        Coordinator(host: host)
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()

        // 页面里所有资源都内联，不需要任何网络访问策略。
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.suppressesIncrementalRendering = false

        let ucc = cfg.userContentController
        ucc.add(context.coordinator, name: "minis")

        let wv = WKWebView(frame: .zero, configuration: cfg)

        // ── 让它真的透明 ──
        // WKWebView 默认有两层底色：自己的 backgroundColor 和内部
        // scrollView 的。只设前者会在滚动回弹时露出白色，两个都要设。
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never

        // 抽屉和全屏页自己处理滚动，WebView 这一层不该有惯性。
        wv.scrollView.showsVerticalScrollIndicator = false
        wv.scrollView.showsHorizontalScrollIndicator = false

        // 关掉双指缩放：模板是固定布局，缩放只会把界面搞乱。
        wv.scrollView.pinchGestureRecognizer?.isEnabled = false

        // 初始不可交互 —— 触摸全部穿透给原生聊天界面。
        // 打开抽屉时由 DrawerContainer 显式打开。
        wv.isUserInteractionEnabled = false

        host.webView = wv

        // [R41-界面热更新] 先找沙箱里的 ui.html，没有再回落到 bundle。
        //
        // 为什么加这个：这个界面的全部内容（抽屉、设置、聊天外壳）都是
        // 这份 html 渲染的，Swift 只负责把它装进 WKWebView。可是它被打包
        // 进了 App bundle，于是「改一行 CSS」也要走一次完整构建 ——
        // 而这个工程 670 个源文件全量编译要 20 分钟。为了一个 margin
        // 等 20 分钟，反馈环长到没法调交互。
        //
        // 现在：把 ui.html 丢进 App 沙箱的 Documents/UITemplate/ 下，
        // 重启 App 就生效，零编译。沙箱路径（TrollStore 装的包）：
        //   /var/mobile/Containers/Data/Application/<UUID>/Documents/UITemplate/ui.html
        //
        // 顺序不能反：一定要**先**沙箱后 bundle。反过来的话沙箱那份
        // 永远被忽略，热更新就是假的。
        //
        // 安全边界：只允许 Documents/UITemplate 这一个目录，且文件名
        // 写死 ui.html —— 不是「读任意传入路径」，不会变成任意文件读取。
        let sandboxURL = Self.sandboxTemplateURL()
        let bundleURL = Bundle.main.url(forResource: "ui",
                                        withExtension: "html",
                                        subdirectory: "UITemplate")

        if let s = sandboxURL {
            wv.loadFileURL(s, allowingReadAccessTo: s.deletingLastPathComponent())
            return wv
        }

        guard let url = bundleURL else {
            host.jsError = "bundle 里找不到 UITemplate/ui.html"
            return wv
        }
        wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return wv
    }

    /// 沙箱里的 ui.html。不存在返回 nil。
    ///
    /// 用 `urls(for:.documentDirectory)` 而不是拼绝对路径 ——
    /// 容器 UUID 每次重装都会变，写死路径必然失效。
    static func sandboxTemplateURL() -> URL? {
        guard let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        let f = docs
            .appendingPathComponent("UITemplate", isDirectory: true)
            .appendingPathComponent("ui.html")
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        // 交互开关只跟 host 的实时状态走。放在 updateUIView 里是因为
        // host 是 @Published，状态一变 SwiftUI 就会重算这一帧。
        wv.isUserInteractionEnabled = host.wantsInteraction
    }

    static func dismantleUIView(_ wv: WKWebView, coordinator: Coordinator) {
        // 不摘 handler 会留一个循环引用：configuration 持有 ucc，
        // ucc 持有 coordinator，coordinator 反向持有 host。
        wv.configuration.userContentController.removeScriptMessageHandler(forName: "minis")
    }

    /// 桥的接收端。
    ///
    /// 整个类标 `@MainActor`：`host` 是主线程隔离的，而
    /// `WKScriptMessageHandler` 的回调本来就发生在主线程 —— 标上之后
    /// Swift 6 的严格并发才不会把 `host.handle` 判成跨 actor 访问。
    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {

        let host: TemplateUIHost

        init(host: TemplateUIHost) {
            self.host = host
        }

        /// `nonisolated` 是给协议签名用的。WebKit 保证这个回调在主线程。
        ///
        /// 刻意不用 `MainActor.assumeIsolated`：它是 iOS 17 才有的 API，
        /// 而这个工程最低支持 16.0。多一次 `Task` 跳转的代价可以忽略 ——
        /// 桥只处理点击，不是每帧都过的热路径。
        nonisolated func userContentController(_ ucc: WKUserContentController,
                                               didReceive message: WKScriptMessage) {
            guard message.name == "minis",
                  let body = message.body as? [String: Any] else { return }
            Task { @MainActor in
                self.host.handle(body)
            }
        }
    }
}
