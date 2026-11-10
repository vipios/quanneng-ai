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

    /// 产物总数只用于标题副行。订阅单例而不是另开入参。
    @ObservedObject private var artifacts = ArtifactStore.shared

    var body: some View {
        VStack(spacing: 0) {

            // ── 标题 ──
            titleBar

            // ── 搜索 ──
            searchBar

            // ── 两个入口：搜索框正下方同一行 ──
            // [R32-入口位置] 原先挂在 VStack 最末尾（底部那条），设计稿
            // （联动模板-完整.html 的 .dw-actions）是紧贴搜索框下方一行居中。
            // 底部那条会随列表长度浮动，越长的列表越难够到；放上面是固定位置。
            entryRow

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
        }
        .background(Color(.systemGroupedBackground))
        // [R28-设置入口右下角] 设置入口从导航栏 `.topBarLeading` 挪到这里：
        // 抽屉右下角一枚 52pt 悬浮齿轮，点它直接开原版 SettingsSheet。
        //
        // 用 overlay 而不是塞进 VStack：齿轮要浮在列表之上、入口行之外，
        // 两者互不影响。R32 把入口行挪到搜索框下方之后，齿轮的 bottom
        // 内边距从 70 收到 14 —— 那个 70 是给底部按钮区让位的，按钮走了
        // 它就得跟着走，否则齿轮会停在半空。
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
        // R32：底部按钮区挪走后这里从 70 收到 14。70 = 旧底部按钮 54 + 间隙 16，
        // 留着会让齿轮悬在列表中间。
        .padding(.bottom, 14)
        .accessibilityLabel("设置")
    }

    // MARK: 标题

    private var titleBar: some View {
        // 标题居中，关闭按钮浮在右侧 —— 用 ZStack 而不是 HStack + Spacer。
        //
        // 为什么不能用 HStack：
        //   HStack { 标题; Spacer(); 关闭按钮 } 里，标题的居中位置取决于
        //   右侧按钮的宽度。按钮 28pt + 右 padding，标题就会被推得偏离
        //   真正的中线约 19pt。改 Spacer 权重只能凑近似值，换个字号又歪。
        //
        // 用 ZStack 后两件事解耦：标题按整条宽度居中（不管右边有没有按钮），
        // 按钮单独贴右。这样以后加第二个按钮也不会再动标题的位置。
        ZStack {
            VStack(spacing: 2) {
                Text(sidebarTitle)
                    .font(.system(size: 27, weight: .bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // 居中容器要占满宽度，否则 ZStack 按内容宽度居中，
            // 标题会挤在左侧按钮旁边而不是整条的中线。
            .frame(maxWidth: .infinity)
            // 标题左右各留出关闭按钮的 28pt + 一点间隙，长标题才不会被
            // 按钮压住。注意这是**对称**的，所以中线不偏 —— 只在右侧留
            // 就会把标题往左推，居中又白做了。
            .padding(.horizontal, 36)

            HStack {
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
        }
        // 左右留一样的内边距：居中是对称留白算出来的中线，两侧不等就偏。
        // 这里右侧还要额外让出关闭按钮的 28pt，否则长标题会顶到按钮下面。
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var sidebarTitle: String {
        // 固定「全能AI管理」。
        //
        // [R32-标题对不齐设计] 这里原先是 `SoulStore.cachedMetadata.name`，
        // 没配过人格名时上游给的是 App 名，于是抽屉顶上一直显示「Minis」。
        // 设计稿（联动模板-完整.html 的 .dw-title）写死的是「全能AI管理」，
        // 而且它是侧栏的身份标识，不该跟着用户改人格名一起漂。
        "全能AI管理"
    }

    private var subtitle: String {
        if isSearching && !query.isEmpty {
            let n = sessionMatchCount + artifactMatches.count
            return n == 0 ? "没找到" : "找到 \(n) 项"
        }
        // 设计稿的副标题是两个数：对话数 · 产物数，不是只有会话数。
        let a = artifactTotal
        return a > 0 ? "\(sessions.count) 个对话 · \(a) 个产物" : "\(sessions.count) 个对话"
    }

    /// 产物总数。设计稿标题下那个「32 个产物」就是它。
    ///
    /// 直接读单例而不是从 ContentView 传：这个数只用来显示一行字，
    /// 为它多开一条参数据通道不划算，而且 `ArtifactStore` 本来就是
    /// `@MainActor` 单例，@ObservedObject 能跟着它自己刷。
    private var artifactTotal: Int {
        artifacts.groups.reduce(0) { $0 + $1.items.count }
    }

    // MARK: 搜索

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜索对话与产物", text: $query)
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

    // MARK: 入口行

    /// 搜索框正下方一行两枚入口：「全部产物」「新建任务」。
    ///
    /// 照设计稿 `.dw-actions / .dw-entry` 落：两枚等宽、46pt 高、圆角 12、
    /// 白卡底 + 极细投影；左枚图标上叠数量角标 + 右侧 chevron，
    /// 右枚是蓝色系的 primary 样式。
    ///
    /// 为什么入口放上面而不是像以前那样钉在底部：底部那条要吃掉一整个
    /// safeAreaInset，抽屉里又没有列表留白去垫它，会话一多就顶到脸前；
    /// 设计稿把它固定在搜索框下面，位置不随列表长度漂。
    private var entryRow: some View {
        HStack(spacing: 10) {
            Button(action: onOpenAllArtifacts) {
                HStack(spacing: 7) {
                    // 图标 + 右上角数量角标。角标单独叠一层而不是塞进 HStack，
                    // 塞进去会把「全部产物」四个字挤掉（设计稿注释原话）。
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(.systemIndigo))
                        .frame(width: 27, height: 27)
                        .background(Color(.systemIndigo).opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            if artifactTotal > 0 {
                                Text(artifactTotal > 99 ? "99+" : "\(artifactTotal)")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 15, minHeight: 15)
                                    .background(Color(.systemIndigo), in: Capsule())
                                    .overlay {
                                        Capsule().strokeBorder(Color(.secondarySystemGroupedBackground),
                                                               lineWidth: 1.6)
                                    }
                                    .offset(x: 5, y: -4)
                            }
                        }

                    Text("全部产物")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(.label))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(.tertiaryLabel))
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5)
                }
            }
            .buttonStyle(.plain)

            Button {
                onNewChat()
                drawerState.close()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 27, height: 27)
                        .background(Color.accentColor.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Text("新建任务")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(Color.accentColor.opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
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
