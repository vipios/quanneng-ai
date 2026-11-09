//
//  SessionDrawer.swift
//  全能AI - 抽屉里的会话列表
//
//  R25 / R28 的落地。抽屉内容 = 标题 + 搜索 + 分组会话列表 + 底部两个入口。
//
//  刻意复用的东西：行渲染直接用现成的 `SessionStackRow`，不另造一套。
//  理由很实在 —— 那一行里有运行指示、未读徽标、高亮匹配片段、拖拽、
//  长按菜单、文件夹归属背景，重写一遍必然漏东西，而且以后原版改了这里
//  也不会跟着变。抽屉只是把它从 List 挪到了 VStack 里。
//
//  刻意不复用的东西：外层容器。原来那套 `List` + `Section` 的 chrome
//  （分组头吸顶、侧滑删除、多选）是为「列表是主界面」设计的；抽屉里宽度
//  只有 318pt，那些 chrome 会挤成一团。所以这里用 ScrollView + VStack，
//  分组头自己画。
//

import SwiftUI

// MARK: - 抽屉主体

struct SessionDrawer: View {

    /// 抽屉状态（用来在点会话后关自己）
    @EnvironmentObject private var drawerState: DrawerState

    /// 会话数据。由 ContentView 传进来，抽屉不自己读库 —— 两处各读一次
    /// 就会出现「列表已更新、抽屉还是旧的」。
    let sessions: [ChatSession]
    let folders: [ChatFolder]
    let groups: [SidebarGroup]
    let currentSessionId: String?

    /// 每个会话的运行态。抽成闭包而不是传整张 Set，是为了不让抽屉在
    /// 任何一个会话的运行态变化时整块重建 —— 只有真正读到的行会刷。
    let isActive: (String) -> Bool
    let isSuspended: (String) -> Bool

    /// 搜索
    @Binding var query: String
    let isSearching: Bool
    /// 搜索命中的会话 id → 匹配片段。命中「产物」的那部分单独给。
    let sessionMatches: [String: String]
    let artifactMatches: [ArtifactMatch]

    /// 动作
    let menuActions: SessionMenuActionChannel
    let onOpenAllArtifacts: () -> Void
    let onNewChat: () -> Void
    let onOpenSettings: () -> Void
    let onSearchChanged: (String) -> Void

    /// 折叠状态。抽屉自己记 —— 这是纯展示偏好，不必回写全局。
    @State private var collapsed: Set<String> = []

    /// 搜索框焦点
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {

            // ── 标题 ──
            titleBar

            // ── 搜索 ──
            searchBar

            // ── 列表 ──
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    if isSearching {
                        searchResults
                    } else {
                        normalList
                    }
                }
                // [R28-设置齿轮不被压住] 底部留白 = 齿轮 52 + 底边距 16 + 一点余量。
                // 齿轮是 overlay 里的绝对定位元素，不参与 VStack 布局，
                // 少了这段留白最后一个会话会被齿轮盖住点不到。
                .padding(.bottom, 76)
            }
            .scrollDismissesKeyboard(.interactively)

            // ── 底部 ──
            bottomBar
        }
        .background(Color(.systemGroupedBackground))
        // [R28-设置入口右下角] 设置入口从导航栏 `.topBarLeading` 挪到这里：
        // 抽屉右下角一枚 52pt 悬浮齿轮，点它直接开原版 SettingsSheet。
        //
        // 刻意用 overlay 而不是塞进 VStack：底部那两个按钮是等宽的
        // 「全部产物 / 新建任务」，插一个齿轮进去会把它们挤窄。
        // overlay 让齿轮浮在列表之上、按钮区之外，两者互不影响。
        .overlay(alignment: .bottomTrailing) {
            settingsGear
        }
        // 会话真的切过去了才关抽屉。
        //
        // 为什么不写在点击回调里：行是 SessionStackRow(内部 Button)，
        // 点击先经过原版通道 `menuActions.send(.open)`，再由 ContentView
        // 改 currentSessionId。在这里观察它的变化，既能保证「切成功才关」，
        // 也不用和行的 Button 抢手势优先级。旧写法是先 onOpenSession 再
        // close，顺序反了会在新页面上看到抽屉飘一下。
        .onChange(of: currentSessionId) { newValue in
            if newValue != nil, drawerState.isOpen {
                drawerState.close()
            }
        }
    }

    /// 右下角悬浮齿轮。
    ///
    /// 52pt 是 R28 定的：手指点击目标下限 44pt，52 留出一点视觉呼吸。
    /// 阴影用两层（一层轮廓 + 一层扩散）而不是 `.shadow` 单层，
    /// 单层在浅色背景上会糊成一圈灰边。
    private var settingsGear: some View {
        Button {
            onOpenSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color(.label))
                .frame(width: 52, height: 52)
                .background(Color(.secondarySystemGroupedBackground), in: Circle())
                .overlay {
                    Circle().strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.13), radius: 12, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 14)
        // 70 = 底部按钮区 54 + 间隙 16。两个 padding 分开写会被叠加成 70 以下的
        // 两层缩进，齿轮就飘到按钮中间了，所以合成一个数。
        .padding(.bottom, 70)
        .accessibilityLabel("设置")
    }

    // MARK: 标题

    private var titleBar: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(sidebarTitle)
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            Button {
                drawerState.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭抽屉")
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var sidebarTitle: String {
        // 与原版一致：优先 SOUL.md 里的名字，没配就用 App 名。
        let n = SoulStore.cachedMetadata.name
        return n.isEmpty ? "全能AI" : n
    }

    private var subtitle: String {
        if isSearching && !query.isEmpty {
            let n = sessionMatchCount + artifactMatches.count
            return n == 0 ? "没找到" : "找到 \(n) 项"
        }
        return "\(sessions.count) 个会话"
    }

    // MARK: 搜索

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜对话和产物", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: query) { newValue in
                    onSearchChanged(newValue)
                }

            if !query.isEmpty {
                Button {
                    query = ""
                    onSearchChanged("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: 正常列表

    private var normalList: some View {
        ForEach(groups) { group in
            groupHeader(group)

            if !collapsed.contains(group.id) {
                ForEach(group.ids, id: \.self) { sid in
                    row(sid, inFolder: group.folderId != nil,
                        isLast: group.isLastMemberRow(sid))
                }
            }

            // 文件夹里还有更多命中没显示
            if group.hiddenMatchCount > 0, !collapsed.contains(group.id) {
                showMoreRow(group)
            }
        }
    }

    private func groupHeader(_ group: SidebarGroup) -> some View {
        let isCollapsed = collapsed.contains(group.id)
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if isCollapsed { collapsed.remove(group.id) }
                else { collapsed.insert(group.id) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                Text(group.label)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                Text("\(group.ids.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.label) 分组，\(group.ids.count) 个会话，\(isCollapsed ? "已折叠" : "已展开")")
    }

    private func row(_ sid: String, inFolder: Bool, isLast: Bool) -> some View {
        let session = sessions.first(where: { $0.id == sid })
            ?? .missingRowPlaceholder(sid)

        // 不要再在这行外面套 `.onTapGesture { onOpenSession(sid) }`。
        //
        // SessionStackRow 内部本身就是一个 Button，点了会走
        // `menuActions.send(.open(sid))` → ContentView 的
        // `switchToSession(sid, animated: true)`，那是原版路径：
        // 它会替换而不是追加导航栈，还会按 shouldAnimateSessionPush
        // 决定要不要动画。
        //
        // 外面再套一层 tap 就等于同一个会话开两次，而且两条路径口径不同
        // （onOpenSession 用的是 append，会把栈堆起来）。点一次抽屉、
        // 后退一次发现还在原页面，就是这么来的。
        //
        // 关抽屉交给 `.onChange(of: currentSessionId)` —— 会话真的切过去了
        // 才关，这不依赖点击事件的先后顺序，也不会和行的 Button 抢手势。
        return SessionStackRow(
            session: session,
            isActive: isActive(sid),
            isSuspended: isSuspended(sid),
            highlightQuery: isSearching ? query : nil,
            matchSnippet: isSearching ? sessionMatches[sid] : nil,
            isRegeneratingTitle: false,
            inFolder: inFolder,
            isLastInFolder: isLast,
            menuActions: menuActions
        )
        .padding(.horizontal, 8)
        .background {
            if currentSessionId == sid {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .padding(.horizontal, 8)
            }
        }
    }

    private func showMoreRow(_ group: SidebarGroup) -> some View {
        Text("还有 \(group.hiddenMatchCount) 个匹配…")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
    }

    // MARK: 搜索结果

    private var sessionMatchCount: Int {
        groups.reduce(0) { $0 + $1.ids.count }
    }

    @ViewBuilder
    private var searchResults: some View {
        if query.isEmpty {
            // 空搜索不显示结果区，回落到正常列表
            normalList
        } else if sessionMatchCount == 0 && artifactMatches.isEmpty {
            emptySearch
        } else {
            if sessionMatchCount > 0 {
                searchGroupHeader("对话", count: sessionMatchCount)
                ForEach(groups) { group in
                    ForEach(group.ids, id: \.self) { sid in
                        row(sid, inFolder: group.folderId != nil,
                            isLast: group.isLastMemberRow(sid))
                    }
                }
            }

            if !artifactMatches.isEmpty {
                searchGroupHeader("产物", count: artifactMatches.count)
                ForEach(artifactMatches) { m in
                    artifactRow(m)
                }
            }
        }
    }

    private func searchGroupHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
            Spacer()
            Text("\(count)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func artifactRow(_ m: ArtifactMatch) -> some View {
        Button {
            // R28：点产物不是「跳到产物页」，而是回到它所属的对话并定位。
            //
            // 走 menuActions 而不是 onOpenSession：这是原版的行点击通道，
            // ContentView 那边是 switchToSession(sid, animated: true) ——
            // 替换栈、按规则决定动画。onOpenSession 走的是 append，会把
            // 导航栈越堆越深，抽屉来回点几次之后返回要按很多下。
            // 关抽屉交给底部的 .onChange(of: currentSessionId)。
            menuActions.send(.open(m.sessionId))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: m.kind.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 26)
                    .background(Color.accentColor.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(m.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Text(m.sessionTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("产物 \(m.name)，属于对话 \(m.sessionTitle)")
    }

    private var emptySearch: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.quaternary)
            Text("没有匹配")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("「\(query)」在对话和产物里都没找到。")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 60)
    }

    // MARK: 底部

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button(action: onOpenAllArtifacts) {
                Text("全部产物")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color(.tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                onNewChat()
                drawerState.close()
            } label: {
                Text("新建任务")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.accentColor,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 0.5)
        }
    }
}

// MARK: - 产物匹配模型

/// 搜索结果里的一条产物。
///
/// 刻意不新造一套 Kind：直接复用 `ArtifactStore` 里现成的 `ArtifactItem.Kind`。
/// 那边已经有 8 类（image/video/audio/document/archive/code/data/other）和
/// 对应 SF Symbol，再造一个只有 5 类的枚举，两边的图标迟早会对不上。
struct ArtifactMatch: Identifiable, Equatable {
    let id: String
    /// 所属会话 id —— 点它不是开产物，是回到那个对话。
    let sessionId: String
    let sessionTitle: String
    let name: String
    let kind: ArtifactItem.Kind
}
