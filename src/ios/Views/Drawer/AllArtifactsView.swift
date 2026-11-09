//
//  AllArtifactsView.swift
//  全能AI - 全部产物
//
//  R28 的另一半。抽屉负责「搜到了就直接定位」，这一页负责「不搜，按类型
//  翻一遍全部文件」。
//
//  数据源直接用现成的 `ArtifactStore`（原版就有，扫描、分组、搜索、改名、
//  重算体积都已实现），这一页只做呈现和交互，不重写任何扫描逻辑。
//
//  三个交互是这一页的重点，也是 R28 交付清单里点名的：
//
//    1. 长按行 → 菜单（存到相册 / 分享 / 在对话中定位 / 删除）
//    2. 点行     → 用系统 Quick Look 打开
//    3. 「在对话中定位」→ 不是跳出这一页，而是把它关掉并切到那个会话，
//       同时把信号带到会话页让它滚到那条消息
//
//  第 3 条是「双命中搜索」的另一半：抽屉里搜到产物 → 点 → 回到对话定位。
//

import SwiftUI
import QuickLook

struct AllArtifactsView: View {

    @Environment(\.dismiss) private var dismiss

    /// 现成的数据源，不新建。
    @ObservedObject var store: ArtifactStore

    /// 会话列表，用来把 sessionId 翻译成标题。
    let sessions: [ChatSession]

    /// 分组方式
    @AppStorage("artifactsGroupBy") private var groupByRaw: String = ArtifactsGroupBy.kind.rawValue
    private var groupBy: ArtifactsGroupBy {
        ArtifactsGroupBy(rawValue: groupByRaw) ?? .kind
    }

    /// 搜索词。这一页自带搜索 —— 抽屉里的搜索是为「顺手找一下」，
    /// 这里是「我就想在这页里过滤」。
    @State private var query = ""

    /// Quick Look 预览
    @State private var previewURL: URL?

    /// 长按菜单 / 删除确认 / 改名 / 报错，统一走一个 alert（见 body 里的注释）
    @State private var activeAlert: ActiveAlert?
    @State private var renameText = ""
    @State private var errorText: String?

    /// 「在对话中定位」的回调。由 ContentView 实现：关掉这一页、
    /// 切到 sessionId、并把文件名传过去让它滚动定位。
    let onLocate: (String, String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if store.groups.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("全部产物")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "搜文件名或对话名")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("分组", selection: Binding(
                            get: { groupBy },
                            set: { groupByRaw = $0.rawValue }
                        )) {
                            ForEach(ArtifactsGroupBy.allCases) { g in
                                Label(g.title, systemImage: g.symbol).tag(g)
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                    .accessibilityLabel("分组方式")
                }
            }
            .task {
                await store.refresh(sessions: sessions)
            }
            .quickLookPreview($previewURL)
            // 三个 alert（删除 / 改名 / 报错）合成一个。
            //
            // 三个 `.alert` 依次挂在同一个视图上是能编译的，但 iOS 15+
            // 里同一个视图只可靠地弹最后一个 —— 前面那些经常点了没反应，
            // 或者弹出来立刻消失。这是 SwiftUI 的老问题：每个 alert 都
            // 往同一条 modifier 链上加 presentation，后加的把前面的顶掉。
            //
            // 改成单一 alert + 一个「当前要弹什么」的状态，三者互斥，
            // 谁都不会被吞。删除和改名的正文要用到具体 item，
            // 所以把 item 一起放进 enum 里带着走。
            .alert(alertTitle, isPresented: Binding(
                get: { activeAlert != nil },
                set: { if !$0 { activeAlert = nil } }
            ), presenting: activeAlert) { kind in
                switch kind {
                case .delete(let item):
                    Button("删除", role: .destructive) { delete(item) }
                    Button("取消", role: .cancel) { activeAlert = nil }
                case .rename(let item):
                    // renameText 在长按菜单里已经预填成原名了；这里把 item
                    // 直接喂给 commitRename，不再从 @State 里反查「在改谁」——
                    // 反查那条路在 alert 被系统中途撤掉时 item 会丢。
                    TextField("新文件名", text: $renameText)
                    Button("保存") { commitRename(item) }
                    Button("取消", role: .cancel) { activeAlert = nil }
                case .error:
                    Button("好", role: .cancel) { activeAlert = nil }
                }
            } message: { kind in
                Text(alertMessage(kind))
            }
        }
    }

    /// 同一时刻只允许一个 alert。原来的 pendingDelete / renaming /
    /// errorText 三个 @State 合并成这一个，避免出现「两个都非 nil」
    /// 时不知道该弹哪个。
    private enum ActiveAlert: Identifiable {
        case delete(ArtifactItem)
        case rename(ArtifactItem)
        case error

        /// 改名要用到具体 item（拿原名比较、按原名改），
        /// 所以 rename 也得带着它走 —— 不能只存一个「正在改名」的布尔。
        var item: ArtifactItem? {
            switch self {
            case .delete(let i): return i
            case .rename(let i): return i
            case .error:         return nil
            }
        }

        var id: String {
            switch self {
            case .delete(let item): return "del:\(item.id)"
            case .rename(let item): return "ren:\(item.id)"
            case .error:            return "error"
            }
        }
    }

    private var alertTitle: String {
        switch activeAlert {
        case .delete(_): return "删除这个产物？"
        case .rename(_): return "改名"
        case .error:     return "出错了"
        case nil:        return ""
        }
    }

    private func alertMessage(_ kind: ActiveAlert) -> String {
        switch kind {
        case .delete(let item):
            return item.name + "\n\n文件会被删掉，对话记录里那条引用会变成失效链接。"
        case .rename(_):
            return ""
        case .error:
            return errorText ?? ""
        }
    }

    // MARK: 列表

    private var visibleGroups: [ArtifactGroup] {
        let base = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? store.groups
            : store.search(query)
        return base
    }

    private var list: some View {
        List {
            switch groupBy {
            case .kind:
                kindSections
            case .session:
                sessionSections
            case .date:
                dateSections
            }
        }
        .listStyle(.insetGrouped)
    }

    // ── 按类型 ──

    @ViewBuilder
    private var kindSections: some View {
        let all = visibleGroups.flatMap(\.items)
        let byKind = Dictionary(grouping: all, by: \.kind)
        // 固定顺序，不按数量排 —— 顺序会跳的列表比不好看的列表更难用。
        let order: [ArtifactItem.Kind] = [.image, .video, .audio, .document, .code, .data, .archive, .other]

        ForEach(order, id: \.rawValue) { kind in
            if let items = byKind[kind], !items.isEmpty {
                Section {
                    ForEach(items) { item in
                        row(item)
                    }
                } header: {
                    HStack {
                        Label(kindTitle(kind), systemImage: kind.symbol)
                        Spacer()
                        Text("\(items.count)")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // ── 按会话 ──

    @ViewBuilder
    private var sessionSections: some View {
        ForEach(visibleGroups) { g in
            Section {
                ForEach(g.items) { item in
                    row(item)
                }
            } header: {
                HStack {
                    Text(g.title)
                    Spacer()
                    Text(g.totalSizeText)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // ── 按日期 ──

    @ViewBuilder
    private var dateSections: some View {
        let all = visibleGroups.flatMap(\.items)
        let cal = Calendar.current
        let byBucket = Dictionary(grouping: all) { item -> String in
            if cal.isDateInToday(item.modifiedAt) { return "今天" }
            if cal.isDateInYesterday(item.modifiedAt) { return "昨天" }
            let days = cal.dateComponents([.day], from: item.modifiedAt, to: Date()).day ?? 999
            if days <= 7 { return "最近 7 天" }
            if days <= 30 { return "最近 30 天" }
            return "更早"
        }
        let order = ["今天", "昨天", "最近 7 天", "最近 30 天", "更早"]

        ForEach(order, id: \.self) { bucket in
            if let items = byBucket[bucket], !items.isEmpty {
                Section(bucket) {
                    ForEach(items.sorted { $0.modifiedAt > $1.modifiedAt }) { item in
                        row(item)
                    }
                }
            }
        }
    }

    private func kindTitle(_ k: ArtifactItem.Kind) -> String {
        switch k {
        case .image:    return "图片"
        case .video:    return "视频"
        case .audio:    return "音频"
        case .document: return "文档"
        case .code:     return "代码"
        case .data:     return "数据"
        case .archive:  return "压缩包"
        case .other:    return "其它"
        }
    }

    // MARK: 行

    private func row(_ item: ArtifactItem) -> some View {
        Button {
            previewURL = item.url
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.kind.symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(item.sizeText) · \(shortDate(item.modifiedAt))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            // 长按菜单。R28 点名的四项，一项不少。
            if item.kind == .image {
                Button {
                    UIImageWriteToSavedPhotosAlbum(
                        UIImage(contentsOfFile: item.url.path) ?? UIImage(),
                        nil, nil, nil
                    )
                } label: {
                    Label("存到相册", systemImage: "square.and.arrow.down")
                }
            }

            Button {
                share(item)
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
            }

            if let sid = item.sessionId {
                Button {
                    // 关掉这一页并切回会话 —— 这就是「双命中」的落点。
                    dismiss()
                    // 给 dismiss 一点时间，否则切页和关页会打架。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        onLocate(sid, item.name)
                    }
                } label: {
                    Label("在对话中定位", systemImage: "arrow.turn.down.right")
                }
            }

            Divider()

            Button {
                renameText = item.name
                activeAlert = .rename(item)
            } label: {
                Label("改名", systemImage: "pencil")
            }

            Button(role: .destructive) {
                activeAlert = .delete(item)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            f.dateFormat = "HH:mm"
        } else if cal.isDateInYesterday(d) {
            f.dateFormat = "'昨天'"
        } else {
            f.dateFormat = "MM-dd"
        }
        return f.string(from: d)
    }

    // MARK: 空态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.quaternary)
            Text(store.isScanning ? "正在扫描…" : "还没有产物")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            if !store.isScanning {
                Text("对话里生成的文件、下载的附件、保存的截图\n都会出现在这里。")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 动作

    private func share(_ item: ArtifactItem) {
        let av = UIActivityViewController(activityItems: [item.url], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else { return }
        // iPad 上不给 popover 的 sourceView 会直接崩。
        av.popoverPresentationController?.sourceView = root.view
        av.popoverPresentationController?.sourceRect = CGRect(
            x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
        root.present(av, animated: true)
    }

    private func delete(_ item: ArtifactItem) {
        activeAlert = nil
        do {
            try store.delete(item)
        } catch {
            raise(error)
        }
    }

    private func commitRename(_ item: ArtifactItem) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        activeAlert = nil
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        do {
            try store.rename(item, to: trimmed)
        } catch {
            raise(error)
        }
    }

    /// 弹报错。
    ///
    /// 不能直接 `activeAlert = .error`：此刻上一个 alert 正在退场动画里，
    /// 同一个 modifier 上立刻换内容会被系统吞掉（点了删除失败，界面什么都不弹）。
    /// 等一拍，等上一个的退场结束再上。
    private func raise(_ error: Error) {
        errorText = error.localizedDescription
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            activeAlert = .error
        }
    }
}

// MARK: - 分组方式

enum ArtifactsGroupBy: String, CaseIterable, Identifiable {
    case kind, session, date
    var id: String { rawValue }

    var title: String {
        switch self {
        case .kind:    return "按类型"
        case .session: return "按对话"
        case .date:    return "按日期"
        }
    }

    var symbol: String {
        switch self {
        case .kind:    return "square.grid.2x2"
        case .session: return "bubble.left.and.bubble.right"
        case .date:    return "calendar"
        }
    }
}
