//
//  ContentView+Drawer.swift
//  全能AI - 把设计稿抽屉接进 iPhone 的 stackLayout
//
//  ============================================================
//  R37 起这里只做一件事：把手势容器换成「模板模式」，然后把真实数据
//  灌进设计稿的抽屉里。
//
//  抽屉的外观、搜索、折叠、长按改名、右下角齿轮、设置页的 25 行 8 组、
//  说话模式七选一、中转站/路由器三字段直填 —— 全部来自
//  `Resources/UITemplate/ui.html`，也就是那份 418KB 的设计稿原文件。
//  Swift 这边一个像素都不画。
//
//  刻意不做的事
//  ------------------------------------------------------------
//    - 不用 SessionDrawer 了。它是我照设计稿手抄的 SwiftUI 版，
//      行高、字号、间距全靠猜，结果就是「哪里都不一样」。留着只会
//      有人再引用一次。模板模式下它就是死代码。
//    - 不改 `sessionList()` / `stackList` / `AIChatView`：对话界面
//      就是原版，真实发送、真实历史。
//    - 不改 iPad 的 `splitLayout`：那边本来就有常驻侧栏，不需要抽屉。
//
//  数据口径
//  ------------------------------------------------------------
//  抽屉里每行是「会话 + 它的产物数」，数据来自两个现成来源：
//    · `sessions`            —— 会话列表（含没有产物的会话）
//    · `ArtifactStore.shared.groups` —— 按 sessionId 聚合好的产物
//  以 sessions 为骨架、把产物挂上去，这样「有产物」和「没产物」的
//  会话都在，不会因为 ArtifactStore 只收录有文件的目录而漏行。
//

import SwiftUI

extension ContentView {

    // MARK: - iPhone 主布局（原版对话 + 设计稿抽屉）

    /// 宽度由调用方从**外层**的 GeometryReader 传进来。
    ///
    /// 这里刻意不再套一层 GeometryReader —— 外层 `body` 已经是
    /// `GeometryReader { geo in ... }`，再嵌一层的话内层读到的是「建议尺寸」
    /// 而不是分配尺寸，里面的 NavigationStack 会塌成 0 高（对话页整屏空白）。
    func stackLayoutWithDrawer(width: CGFloat) -> some View {
        DrawerContainer(width: width,
                        useTemplate: true,
                        onTemplateReady: { host in
                            templateHost = host
                            installTemplateCallbacks(host)
                            pushDrawerData(to: host)
                        }) { _ in
            // 模板模式下这个闭包不会被调用（抽屉层是 WebView）。
            // 保留只是因为 DrawerContainer 是泛型，得给个类型。
            EmptyView()
        } content: {
            stackLayout
        }
        // 会话增删、标题改名都要让抽屉跟着变。
        // 用 count 当触发器而不是监听整个数组：数组元素里有流式内容，
        // 每帧都变，监听它会让 WebView 一秒被灌几十次数据。
        .onChange(of: sessions.count) { _ in
            pushDrawerData()
        }
    }

    // MARK: - 模板回调

    /// 把模板里「点了什么」接到原版动作上。
    ///
    /// 这三件事模板自己做不了：
    ///   · 切会话 —— 真实会话数据在原生，模板里的 renderChat 是假消息
    ///   · 新建任务 —— 要走原版的草稿会话流程
    ///   · 设置页里需要原生能力的行 —— 见下面的分支
    private func installTemplateCallbacks(_ host: TemplateUIHost) {
        host.onSwitchSession = { id in
            // 模板点完会自己 closeDrawer，这里只负责真正的切换。
            openSessionFromDrawer(id)
        }

        host.onNewChat = {
            handleNewChatRequest()
        }

        host.onSettingsRow = { row in
            handleTemplateSettingsRow(row, host: host)
        }
    }

    /// 设置页里某些行在模板内部没有对应 pane，必须交给原生。
    ///
    /// 判断依据是模板 `openDetail()` 的分支：ai / relayAdmin / relayRouter /
    /// skills / modes / soul / github 这些它自己画得出来，其余的（模型分组、
    /// 令牌用量、外观、可用工具、子代理任务、记忆…）原版页面功能完整，
    /// 直接推原版界面，不在网页里重造一遍。
    private func handleTemplateSettingsRow(_ row: String, host: TemplateUIHost) {
        switch row {
        case "ai", "relayAdmin", "relayRouter", "skills", "modes", "soul", "github":
            // 模板自己会开 pane，这里什么都不做。
            break
        case "providers":
            host.closeDrawer()
            activeToolSheet = .settings
        default:
            // 其余行：原版设置页有完整实现，跳过去。
            host.closeDrawer()
            activeToolSheet = .settings
        }
    }

    // MARK: - 数据推送

    /// 把真实会话与产物灌进模板。
    func pushDrawerData() {
        guard let host = templateHost else { return }
        pushDrawerData(to: host)
    }

    func pushDrawerData(to host: TemplateUIHost) {
        host.setData(drawerDataJSON())
    }

    /// 生成和模板内置 `DATA` 完全同构的 JSON：
    /// `[{id, title, items:[{n, k, s, t}]}]`
    ///
    /// 字段名短得莫名其妙，是因为模板里 `renderDrawer` / `renderFold` /
    /// `searchHTML` 全都按 `g.title` / `it.n` / `it.k` 取值。改字段名要
    /// 同时改三个函数，收益为零，所以跟着模板的命名走。
    func drawerDataJSON() -> String {
        // 产物按 sessionId 归堆。`ArtifactStore.groups` 本身就是按会话分的，
        // 这里拍平成字典只是为了 O(1) 查。
        var itemsBySession: [String: [ArtifactItem]] = [:]
        for g in ArtifactStore.shared.groups {
            itemsBySession[g.id] = g.items
        }

        let rows: [[String: Any]] = sessions.map { s in
            let title = (s.title?.isEmpty == false) ? s.title! : "新对话"
            let items = (itemsBySession[s.id] ?? []).map { item -> [String: Any] in
                [
                    "n": item.name,
                    "k": Self.templateKind(item.kind),
                    "s": ByteCountFormatter.string(fromByteCount: item.byteCount,
                                                   countStyle: .file),
                    "t": Self.templateTime(item.modifiedAt)
                ]
            }
            return ["id": s.id, "title": title, "items": items]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    /// `ArtifactItem.Kind` → 模板里 `k` 的取值。
    /// 模板只认 code / doc / image / data / archive / video 六个，
    /// 音频和「其它」归到 data（模板里这两类共用同一个图标）。
    static func templateKind(_ kind: ArtifactItem.Kind) -> String {
        switch kind {
        case .image:    return "image"
        case .video:    return "video"
        case .audio:    return "data"
        case .document: return "doc"
        case .archive:  return "archive"
        case .code:     return "code"
        case .data:     return "data"
        case .other:    return "data"
        }
    }

    /// 时间格式对齐模板里的三种写法：
    ///   今天     → `11:42`
    ///   昨天     → `昨天 22:14`
    ///   更早     → `11-07 14:20`
    ///
    /// 模板那些示例数据就是这么写的，统一了抽屉看起来才不是「两种日期混排」。
    static func templateTime(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")

        if cal.isDateInToday(date) {
            f.dateFormat = "HH:mm"
            return f.string(from: date)
        }
        if cal.isDateInYesterday(date) {
            f.dateFormat = "HH:mm"
            return "昨天 " + f.string(from: date)
        }
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    // MARK: - 抽屉用的派生数据（其它地方仍在用）

    /// 抽屉搜索是否生效。
    var drawerIsSearching: Bool {
        !drawerQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 从「全部产物」页点「在对话中定位」时，切到目标会话。
    ///
    /// 这里刻意委托给原版 `switchToSession`，不自己改 navigationPath。
    /// 自己写那版漏了三件事：
    ///   1. iPad 宽屏分支 —— 宽屏不用导航栈，走的是 selectedSessionId，
    ///      自己 append 一遍等于什么都没选上；
    ///   2. `shouldAnimateSessionPush` 的动画判定；
    ///   3. `currentStackSessionId` 的同步 —— 不写它，
    ///      `previousStackSessionId` 会错位，AIChatView 的 onAppear /
    ///      onDisappear 记号跟着乱。
    func openSessionFromDrawer(_ id: String) {
        if Self.isNewSessionId(id) {
            handleNewChatRequest()
            return
        }
        switchToSession(id)
    }
}
