//
//  SettingsRename.swift
//  Minis — 设置页每行的「长按改名」
//
//  需求（用户口径）：这个界面所有的字体都添加一个长按弹窗，里面可以
//  改名字、恢复名字、取消。
//
//  设计取舍，逐条记下来，免得后面有人问「为什么这么写」：
//
//  1. 只改「显示名」，不动功能。
//     长按改名改的是用户在设置页看到的文字，`NavigationLink` 的目标、
//     tool id、UserDefaults 的键全都不变。否则改个标题就能把功能改坏。
//
//  2. 名字落在 UserDefaults，键 = `minis.settings.rowName.<rowId>`。
//     不给每一项加 @AppStorage 字段：设置页有二十多行，逐个加字段
//     既啰嗦又容易漏，而且以后新增行还得改代码。用 rowId 做键，
//     新增行只要给一个稳定 id 就自动获得改名能力。
//
//  3. 恢复名字 = 删掉那条覆盖，回落到本地化原文。
//     不是「把原名写回去」—— 否则语言一换，存下来的中文原名就盖住了
//     英文界面。删覆盖才能跟着系统语言走。
//
//  4. 空名字 / 纯空白 = 视为恢复原名。
//     用户清空输入框再点保存，本意就是「不要这个自定义名了」，
//     不该存一个空标题上去。
//
//  5. 长按不拦截点击。
//     用 `.simultaneousGesture(LongPressGesture())` 而不是
//     `.onLongPressGesture`：后者会吃掉手势，导致轻点跳转失灵。
//

import SwiftUI

// MARK: - 行标识

/// 设置页每一行的稳定标识。
///
/// 加新行时在这里补一个 case 就行 —— 改名能力自动继承，不用改别的文件。
/// **不要**用显示标题当 id：标题会翻译、会被用户改掉，拿来当键会互相覆盖。
enum SettingsRowId: String, CaseIterable {
    // AI 服务商
    case providers          = "providers"
    case modelGroups        = "modelGroups"
    case tokenUsage         = "tokenUsage"
    // 设备管理
    case relayAdmin         = "relayAdmin"
    case relayRouter        = "relayRouter"
    // 外观
    case appearance         = "appearance"
    // 智能体运行时
    case agentTools         = "agentTools"
    case subAgents          = "subAgents"
    case skills             = "skills"
    case soul               = "soul"
    case memory             = "memory"
    case mcpIntegrations    = "mcpIntegrations"
    case environmentVars    = "environmentVars"
    // 存储
    case storage            = "storage"
    case sharedFolders      = "sharedFolders"
    case mountedFolders     = "mountedFolders"
    case iCloudSync         = "iCloudSync"
    case backupRestore      = "backupRestore"
    case githubAccount      = "githubAccount"
    // 权限
    case permissions        = "permissions"
    case faceID             = "faceID"
    // 日志
    case logs               = "logs"
    // 版本和更新（在 SelfUpdateSection.swift 里）
    case version            = "version"
    case checkUpdate        = "checkUpdate"
    case updateSource       = "updateSource"
    // 关于
    case about              = "about"
    case privacyPolicy      = "privacyPolicy"
    case feedback           = "feedback"
}

// MARK: - 存储

/// 自定义行名的读写。
///
/// 刻意没有做成 ObservableObject 单例：设置页本来就短命，
/// 每次进页面重读一遍 UserDefaults 代价可以忽略，
/// 而引入一个要手动 notify 的全局对象反而容易忘。
enum SettingsRowNameStore {

    private static let prefix = "minis.settings.rowName."

    private static func key(_ id: SettingsRowId) -> String {
        prefix + id.rawValue
    }

    /// 当前生效的名字。没有自定义过就返回 nil，调用方回落到本地化原文。
    static func custom(_ id: SettingsRowId) -> String? {
        guard let v = UserDefaults.standard.string(forKey: key(id)) else { return nil }
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 写入自定义名。传空串等于恢复原名。
    static func set(_ name: String, for id: SettingsRowId) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            reset(id)
        } else {
            UserDefaults.standard.set(t, forKey: key(id))
        }
    }

    /// 删掉覆盖，回到原文。
    static func reset(_ id: SettingsRowId) {
        UserDefaults.standard.removeObject(forKey: key(id))
    }

    static func hasCustom(_ id: SettingsRowId) -> Bool {
        custom(id) != nil
    }

    /// 只给测试 / 调试用：一次性清掉所有自定义名。
    static func resetAll() {
        for id in SettingsRowId.allCases { reset(id) }
    }
}

// MARK: - 标题

/// 设置页的标题。想要自定义名就写这个，别直接写 `Text("Skills")`。
///
/// 用法：
/// ```
/// SettingsRowLabel(.skills, fallback: "Skills")
/// ```
/// 内部先查自定义名，没有就回落到本地化原文，所以英文界面 / 中文界面
/// 都能正确显示，改过名的也照用户写的显示。
struct SettingsRowLabel: View {

    let id: SettingsRowId
    let fallbackKey: LocalizedStringKey

    /// 名字变了要重画。放在这里而不是放全局，是因为只有设置页关心。
    @State private var custom: String? = nil

    // 参数标签不用 `default`：它是 Swift 保留字，写成标签要靠反引号，
    // 调用点一多就容易漏。`fallback` 意思一样且没有坑。
    init(_ id: SettingsRowId, fallback fallbackKey: LocalizedStringKey) {
        self.id = id
        self.fallbackKey = fallbackKey
    }

    var body: some View {
        Group {
            if let c = custom {
                // 自定义名不加括号、不加标记 —— 用户自己起的名字，
                // 就该看起来和原名一样，不能像「被改过」的告示。
                Text(c)
            } else {
                Text(fallbackKey)
            }
        }
        .onAppear { custom = SettingsRowNameStore.custom(id) }
        // 改名弹窗保存后会 post 这个通知，界面立刻跟着变，
        // 不用退出重进设置页。
        .onReceive(NotificationCenter.default.publisher(for: .settingsRowNameChanged)) { note in
            guard let changed = note.object as? String, changed == id.rawValue else { return }
            custom = SettingsRowNameStore.custom(id)
        }
    }
}

extension Notification.Name {
    /// 某一行改了名。object 是 `SettingsRowId.rawValue`。
    static let settingsRowNameChanged = Notification.Name("minis.settings.rowNameChanged")
}

// MARK: - 长按弹窗

/// 长按某一行后弹出来的东西：改名 / 恢复原名 / 取消。
///
/// 为什么不用 `.alert`：
///   · alert 里塞 TextField 是 iOS 16 之后才有，且样式被系统锁死，
///     改不了文案层级，也放不下「当前名字」这种说明行；
///   · 用户要的是「弹窗」，iOS 上这一套最贴的是 `confirmationDialog`
///     配一个自定义小面板 —— 但 confirmationDialog 不允许自定义内容。
///   所以这里做一个轻量浮层，视觉照 `confirm-box` 那套来，
///   和其他二次确认保持一致。
struct SettingsRowRenameSheet: View {

    let id: SettingsRowId
    /// 原始标题，用于「恢复原名」的说明与改名框的占位。
    let defaultName: String

    @Environment(\.dismiss) private var dismiss

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    private var hasCustom: Bool { SettingsRowNameStore.custom(id) != nil }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部说明：现在叫什么、原名是什么
            VStack(spacing: 4) {
                Text(hasCustom ? "改名" : "给这一项改个名字")
                    .font(.headline)
                Text("原名：\(defaultName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 18)
            .padding(.bottom, 14)

            TextField(defaultName, text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { save() }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 16)

            Text("留空保存 = 恢复原名。只改这一页显示的文字，不影响功能。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            Divider().padding(.top, 14)

            Button { save() } label: {
                Text("保存")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasCustom)

            Divider()

            Button { resetName() } label: {
                Text("恢复原名")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            // 没改过名就没什么可恢复的，别给一个点了没反应的按钮
            .disabled(!hasCustom)
            .foregroundStyle(hasCustom ? Color.accentColor : Color.secondary)

            Divider()

            Button { dismiss() } label: {
                Text("取消")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .foregroundStyle(.primary)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 32)
        .onAppear {
            draft = SettingsRowNameStore.custom(id) ?? defaultName
            focused = true
        }
    }

    private func save() {
        SettingsRowNameStore.set(draft, for: id)
        announce()
        dismiss()
    }

    private func resetName() {
        SettingsRowNameStore.reset(id)
        announce()
        dismiss()
    }

    private func announce() {
        NotificationCenter.default.post(name: .settingsRowNameChanged, object: id.rawValue)
    }
}

// MARK: - 挂载修饰符

/// 给一行加上「长按改名」。
///
/// 用 `.simultaneousGesture` 而不是 `.onLongPressGesture`：
/// 后者会把手势从 NavigationLink 手里抢走，轻点就不跳转了。
/// `simultaneousGesture` 允许多个手势同时识别，长按和轻点互不影响。
extension View {

    /// - Parameters:
    ///   - id: 这一行的稳定标识
    ///   - defaultName: 已经本地化好的原文，用于弹窗里显示「原名」。
    ///     注意传的是**解析后**的字符串（不是 key），否则弹窗里会显示
    ///     `Skills` 而不是「技能」。
    func settingsRowRenameable(_ id: SettingsRowId,
                               defaultName: String) -> some View {
        modifier(SettingsRowRenameModifier(id: id, defaultName: defaultName))
    }
}

private struct SettingsRowRenameModifier: ViewModifier {

    let id: SettingsRowId
    let defaultName: String

    @State private var showing = false

    func body(content: Content) -> some View {
        content
            // 长按：同时识别，不抢轻点
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45)
                    .onEnded { _ in
                        // 长按成功给一下触感，让用户知道「按到了」
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        showing = true
                    }
            )
            // 浮层：整个设置页盖一层，点外面关掉
            .overlay {
                if showing {
                    ZStack {
                        Color.black.opacity(0.28)
                            .ignoresSafeArea()
                            .onTapGesture { showing = false }
                        SettingsRowRenameSheet(id: id, defaultName: defaultName)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                    .animation(.easeOut(duration: 0.16), value: showing)
                }
            }
    }
}
