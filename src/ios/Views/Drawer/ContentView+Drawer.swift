//
//  ContentView+Drawer.swift
//  全能AI - 把侧抽接进 iPhone 的 stackLayout
//
//  这一层只做两件事，不碰对话页任何一个像素：
//
//    1. 把 `stackLayout` 的现有内容（NavigationStack + 会话列表 + AIChatView）
//       原样包进 `DrawerContainer` 的 content 闭包里 —— 对话页、导航、push
//       全部走原版代码，这里一行没改。
//    2. 造 `SessionDrawer` 要的参数。全部从 ContentView 现成的 @State /
//       计算属性取，不新读一遍库（两处各读一次会出现「列表已更新、抽屉还是旧的」）。
//
//  刻意不做的事：
//    - 不改 `sessionList()` / `stackList` / `AIChatView`：对话界面就是原版。
//    - 不改 iPad 的 `splitLayout`：那边本来就有常驻侧栏，不需要抽屉。
//    - 导航一律走原版 push（改 `navigationPath`），不自己造导航栈。
//
//  需要 ContentView.swift 里新增三个 @State（存储属性不能加在 extension 上）：
//      @State var drawerQuery = ""
//      @State var showAllArtifacts = false
//  以及一个抽屉宽度缓存不必加 —— 宽度从 GeometryReader 现取。
//

import SwiftUI

extension ContentView {

    // MARK: - iPhone 主布局（原版对话 + 左边缘抽屉）

    /// 宽度由调用方从**外层**的 GeometryReader 传进来。
    ///
    /// 这里刻意不再套一层 GeometryReader —— 外层 `body` 已经是
    /// `GeometryReader { geo in ... }`，再嵌一层的话内层读到的是「建议尺寸」
    /// 而不是分配尺寸，里面的 NavigationStack 会塌成 0 高（对话页整屏空白）。
    func stackLayoutWithDrawer(width: CGFloat) -> some View {
        DrawerContainer(width: width) { drawerState in
            SessionDrawer(
                sessions: sessions,
                folders: folders,
                groups: drawerGroups,
                currentSessionId: currentDrawerSessionId,
                isActive: { sessionIsRunning($0) },
                isSuspended: { sidebarConcurrencyManager.isSuspended($0) },
                query: $drawerQuery,
                isSearching: drawerIsSearching,
                sessionMatches: drawerSessionMatches,
                artifactMatches: drawerArtifactMatches,
                menuActions: menuActions,
                onOpenAllArtifacts: {
                    drawerState.close()
                    showAllArtifacts = true
                },
                onNewChat: {
                    handleNewChatRequest()
                },
                onOpenSettings: {
                    drawerState.close()
                    activeToolSheet = .settings
                },
                onSearchChanged: { text in
                    drawerQuery = text
                }
            )
        } content: {
            stackLayout
        }
    }

    // MARK: - 抽屉用的派生数据

    /// 抽屉里的会话分组。
    ///
    /// 搜索态只给命中的会话，非搜索态给全量。分组口径完全复用现成的
    /// `groupedSessionIDs`（置顶 / 日期桶 / 文件夹分组都在里面），
    /// 不自己写一套排序。
    var drawerGroups: [SidebarGroup] {
        guard drawerIsSearching else { return groupedSessionIDs(sessions) }

        // 先过滤会话，再把过滤后的列表交给原版分组函数。
        //
        // 比「分完组再逐组裁剪」好在：文件夹聚合（glyph / 未读 / 运行中 /
        // 折叠态 / summaryTitle）全部由 `groupedSessionIDs` 自己算，这里
        // 不接手任何一项 —— 一旦手搓 SidebarGroup，就得把十几个字段
        // 一一搬过来，漏一个就是运行时空指针或错图标。
        let hitIds = Set(drawerSessionMatches.keys)
        guard !hitIds.isEmpty else { return [] }

        let filtered = sessions.filter { hitIds.contains($0.id) }
        return groupedSessionIDs(filtered)
    }

    /// 抽屉里高亮哪一行。
    ///
    /// iPhone 上「当前打开的是哪个」记在 `currentStackSessionId`，
    /// 不是 `selectedSessionId`（那是 iPad 的 detail 选中项）。
    var currentDrawerSessionId: String? {
        currentStackSessionId
    }

    /// 抽屉搜索是否生效。
    var drawerIsSearching: Bool {
        !drawerQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 命中的会话 → 匹配片段。
    ///
    /// 标题命中一定算；正文命中沿用原版搜索算好的 `searchMatchSnippets`
    /// （那是全库检索的结果，抽屉这边不重跑一遍 SQL）。
    var drawerSessionMatches: [String: String] {
        guard drawerIsSearching else { return [:] }
        let terms = SearchKeywords.terms(drawerQuery)
        guard !terms.isEmpty else { return [:] }

        var out: [String: String] = [:]
        for s in sessions {
            // `ChatSession.title` 是 String?（草稿还没生成标题时为 nil），
            // 和原版行渲染同一口径：nil 当 "New Chat" 处理。
            let title = s.title ?? "New Chat"
            if SearchKeywords.firstHit(in: title, terms: terms) != nil {
                out[s.id] = searchMatchSnippets[s.id] ?? title
            } else if let snippet = searchMatchSnippets[s.id] {
                out[s.id] = snippet
            }
        }
        return out
    }

    /// 命中的产物，拍平成一行一条。
    ///
    /// `ArtifactStore.search()` 返回 `[ArtifactGroup]`（一个会话一组），
    /// 抽屉要的是带「所属对话标题」的扁平行。搜索规则完全用 Store 里那套
    /// （对话名命中整组带出 / 否则只留文件名命中的条目），不重写。
    var drawerArtifactMatches: [ArtifactMatch] {
        guard drawerIsSearching else { return [] }
        return ArtifactStore.shared.search(drawerQuery).flatMap { group in
            group.items.map { item in
                ArtifactMatch(
                    id: item.id,
                    sessionId: group.id,
                    sessionTitle: group.title,
                    name: item.name,
                    kind: item.kind
                )
            }
        }
    }

    // MARK: - 动作

    /// 从「全部产物」页点「在对话中定位」时，切到目标会话。
    ///
    /// 这里刻意委托给原版 `switchToSession`，不自己改 navigationPath。
    /// 自己写那版（下面注释里保留的旧实现）漏了三件事：
    ///   1. iPad 宽屏分支 —— 宽屏不用导航栈，走的是 selectedSessionId，
    ///      自己 append 一遍等于什么都没选上；
    ///   2. `shouldAnimateSessionPush` 的动画判定；
    ///   3. `currentStackSessionId` 的同步 —— 不写它，
    ///      `previousStackSessionId` 会错位，AIChatView 的 onAppear /
    ///      onDisappear 记号跟着乱。
    ///
    /// 旧实现（保留作参照，不要再启用）：
    ///     navigationPath = NavigationPath()
    ///     navigationPath.append(id)
    func openSessionFromDrawer(_ id: String) {
        if Self.isNewSessionId(id) {
            handleNewChatRequest()
            return
        }
        switchToSession(id)
    }
}
