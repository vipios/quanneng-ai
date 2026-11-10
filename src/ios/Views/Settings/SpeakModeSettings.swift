//
//  SpeakModeSettings.swift
//  全能AI - 说话模式（R42 新增设置页）
//
//  ============================================================
//  这个文件解决一件事：让「说话模式」有一个可以点的入口，
//  同时保证默认行为是**自动选**，而不是让用户去手挑。
//
//  背景
//  ------------------------------------------------------------
//  自动路由（RouteEngine + RouteRules + RouteInjector）早就写完并接在
//  发送链路上 —— 每次发消息都会判一个三元组：
//
//      能力域（domain） + 人格（persona） + 说话模式（mode）
//
//  用户说「帮我破解这个 ipa」，一次判出：移动端 · 全能执行 · 逆向专家模式。
//  也就是说「让它自己选」这件事本来就在跑。
//
//  缺的只有两样：
//    1. 设置页里没有「说话模式」这一行，用户看不到这套机制存在；
//    2. 没有任何办法让用户**手动指定**「这一轮我就想用某个模式」。
//
//  这个文件补的就是这两样，且刻意做成「自动优先」：
//    · 默认值是 `.auto` —— 一次都不点的话，行为和现在完全一样；
//    · 选了具体模式之后，注入的仍然是完整三元组，只把 mode 换掉，
//      域和人格照旧自动判 —— 用户想控制的是「怎么说」，不是
//      「这是什么活」。
//
//  为什么只覆盖 mode 而不是整条三元组
//  ------------------------------------------------------------
//  域和人格是「这句话是什么活、该由谁干」，这两件事用户手挑没有意义
//  （他描述任务，我们判活）。而说话模式是「输出风格」—— 同一个任务，
//  用户可以想要简洁一点、或者想看完整推导。这是主观偏好，只能他说了算。
//
//  ============================================================
//

import SwiftUI

// MARK: - 存储

/// 说话模式的全局设置。两个值：自动 / 指定某个模式。
///
/// 用 `UserDefaults` 而不是 @AppStorage：
///   · 需要在非 View 的地方读（`RouteInjector.make` 里，它在
///     `AIChatViewModel+AgentLoop` 的异步链路中执行，拿不到 View 环境）；
///   · @AppStorage 的 read 在 View 更新时才有意义，这里是业务逻辑读。
enum SpeakModeSettings {

    private static let key = "minis.speakMode.selected"

    /// 自动判定的哨兵值。存的是这个字符串，不是 nil ——
    /// nil 在 UserDefaults 里和「从没设置过」不可区分，而我们要的
    /// 默认值恰好也是自动，两者语义相同，用哨兵更省一层判断。
    static let autoId = "auto"

    /// 当前选的模式 id。`.autoId` 表示交给 RouteEngine 判。
    static var selected: String {
        get {
            let v = UserDefaults.standard.string(forKey: key) ?? autoId
            // 存进去的 id 必须仍是已知模式 —— 模式表以后改了（删了某个
            // 模式）之后，老存档里那个 id 会让 Picker 选不中任何一项。
            // 这种时候回落到自动，行为不会坏。
            if v == autoId { return autoId }
            return RouteMode.names[v] != nil ? v : autoId
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }

    /// 是否处于「自动」。
    static var isAuto: Bool { selected == autoId }

    /// 当前是不是用户手选了一个具体模式。
    static var isPinned: Bool { !isAuto }
}

// MARK: - 设置页

/// 「说话模式」设置页。
///
/// 排版沿用设计稿的卡片样式（见 `SettingsDesign`），和设置首页一致。
struct SpeakModeSettingsView: View {

    /// 让 Picker 的变化立刻反映到界面。
    @State private var selected: String = SpeakModeSettings.selected

    /// 「试一句」的输入框。这个页面完整照搬设计稿里的试用面板 ——
    /// 没有它，用户无法知道「自动」到底会把他这句话判成什么，
    /// 只能盲选。
    @State private var probeText: String = ""
    @State private var probe: RouteDecision?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {

                // ── 当前策略 ──
                header

                // ── 自动 ──
                card {
                    optionRow(id: SpeakModeSettings.autoId,
                              title: "自动",
                              subtitle: "按你这句话的内容，和技能、人格一起自动选",
                              icon: "wand.and.stars",
                              tint: SettingsDesign.blue,
                              isDefault: true)
                }

                // ── 七个具体模式 ──
                groupHeader("手动指定")

                card {
                    let ids = orderedModeIds
                    ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                        if index > 0 { divider }
                        optionRow(id: id,
                                  title: RouteMode.name(id),
                                  subtitle: modeHint(id),
                                  icon: modeIcon(id),
                                  tint: modeTint(id),
                                  isDefault: false)
                    }
                }

                // ── 试用 ──
                groupHeader("试一句")

                card {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("输入一句话，看会判成什么", text: $probeText)
                            .font(SettingsDesign.titleFont)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: probeText) { _ in
                                // 边打边判，不用点按钮 —— 判定是纯字符串
                                // 匹配，一次几微秒，没有性能顾虑。
                                let t = probeText.trimmingCharacters(in: .whitespacesAndNewlines)
                                probe = t.isEmpty ? nil : RouteEngine.decide(t)
                            }

                        if let p = probe {
                            probeResult(p)
                        }
                    }
                    .padding(.horizontal, SettingsDesign.rowPaddingH)
                    .padding(.vertical, 12)
                }

                // 底部说明
                Text(pinnedHint)
                    .font(SettingsDesign.subFont)
                    .foregroundStyle(Color(.secondaryLabel))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SettingsDesign.cardInset)
                    .padding(.top, 14)
            }
            .padding(.bottom, SettingsDesign.listBottomPadding)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("说话模式")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 组件

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SpeakModeSettings.isAuto ? "当前：自动" : "当前：\(RouteMode.name(selected))")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color(.label))
            Text("能力域和人格始终自动判定；这里只决定「怎么说」。")
                .font(SettingsDesign.subFont)
                .foregroundStyle(Color(.secondaryLabel))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsDesign.sectionHeaderLeading)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private func groupHeader(_ text: String) -> some View {
        Text(text)
            .font(SettingsDesign.sectionHeaderFont)
            .foregroundStyle(Color(.label))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, SettingsDesign.sectionHeaderLeading)
            .padding(.trailing, SettingsDesign.cardInset)
            .padding(.top, SettingsDesign.sectionHeaderTop)
            .padding(.bottom, SettingsDesign.sectionHeaderBottom)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: SettingsDesign.cardRadius,
                                        style: .continuous))
            .padding(.horizontal, SettingsDesign.cardInset)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 0.5)
            .padding(.leading, SettingsDesign.separatorInset)
    }

    private func optionRow(id: String,
                           title: String,
                           subtitle: String,
                           icon: String,
                           tint: Color,
                           isDefault: Bool) -> some View {
        Button {
            selected = id
            SpeakModeSettings.selected = id
        } label: {
            HStack(spacing: SettingsDesign.rowGap) {
                Image(systemName: icon)
                    .font(.system(size: SettingsDesign.iconGlyph, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: SettingsDesign.iconSize,
                           height: SettingsDesign.iconSize)
                    .background(tint,
                                in: RoundedRectangle(cornerRadius: SettingsDesign.iconRadius,
                                                     style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SettingsDesign.titleFont)
                        .foregroundStyle(Color(.label))
                    Text(subtitle)
                        .font(SettingsDesign.subFont)
                        .foregroundStyle(Color(.secondaryLabel))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if selected == id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, SettingsDesign.rowPaddingH)
            .padding(.vertical, SettingsDesign.rowPaddingV)
            .frame(minHeight: SettingsDesign.rowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func probeResult(_ p: RouteDecision) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(p.line)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(.label))
            if p.hit.isEmpty {
                Text("一个技术词都没命中，走的是默认口径。")
                    .font(SettingsDesign.subFont)
                    .foregroundStyle(Color(.secondaryLabel))
            } else {
                Text("命中「\(p.hit)」· 得分 \(p.scores.first?.score ?? 0) · \(p.confident ? "信号明确" : "信号弱")")
                    .font(SettingsDesign.subFont)
                    .foregroundStyle(Color(.secondaryLabel))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: 模式元数据

    /// 七个模式按「从简到专」排：自动不在里面（单独一行）。
    ///
    /// 顺序取自 `RouteMode.names` 的声明顺序 —— 那份字典本身就是按
    /// 这个顺序写的，直接沿用可以避免两处各写一遍。
    private var orderedModeIds: [String] {
        ["plain", "dev", "rev", "sec", "game", "inject"]
    }

    private func modeHint(_ id: String) -> String {
        switch id {
        case "plain":  return "只说结论，不要过程"
        case "dev":    return "带代码、带命令，偏工程实现"
        case "rev":    return "逆向视角：字节、符号、调用链"
        case "sec":    return "攻防视角，讲清风险和边界"
        case "game":   return "游戏内存修改的方向和手法"
        case "inject": return "注入与 Hook 的落地细节"
        default:       return ""
        }
    }

    private func modeIcon(_ id: String) -> String {
        switch id {
        case "plain":  return "text.alignleft"
        case "dev":    return "chevron.left.forwardslash.chevron.right"
        case "rev":    return "magnifyingglass.circle.fill"
        case "sec":    return "shield.lefthalf.filled"
        case "game":   return "gamecontroller.fill"
        case "inject": return "syringe.fill"
        default:       return "circle.fill"
        }
    }

    private func modeTint(_ id: String) -> Color {
        switch id {
        case "plain":  return SettingsDesign.gray
        case "dev":    return SettingsDesign.blue
        case "rev":    return SettingsDesign.indigo
        case "sec":    return SettingsDesign.red
        case "game":   return SettingsDesign.orange
        case "inject": return SettingsDesign.purple
        default:       return SettingsDesign.gray
        }
    }

    /// 底部那句提示，跟着「自动 / 指定」变。
    ///
    /// 指定模式时要说清「域和人格还在自动判」，否则用户会以为整条
    /// 判定都被锁死了，反而不敢用。
    private var pinnedHint: String {
        if SpeakModeSettings.isAuto {
            return "自动模式下，说话模式随每句话的内容变化 —— 和技能、人格一起判，不需要你选。"
        }
        return "已固定为「\(RouteMode.name(selected))」。能力域和人格仍然自动判定，只有说话风格按这里来。"
    }
}
