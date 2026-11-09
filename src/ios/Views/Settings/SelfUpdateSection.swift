//
//  SelfUpdateSection.swift
//  Minis — 设置页「版本和更新」区
//
//  ============================================================
//  这一区的职责很窄：显示我们自己的版本号，给一个检查按钮，
//  给一个填写更新源的入口。所有网络与比较逻辑在 `SelfUpdate`。
//
//  三个刻意为之的设计
//  ----------------------------------------------------------
//  1. 版本行**不显示原版版本号**，也拿不到 —— 我们跟原版没有
//     大小关系，显示了只会让人以为「1.0 比 1.15 旧所以该更新」。
//  2. 没配更新源时按钮照样能点，点完明确说「还没配」。
//     不改成 disabled —— 按钮置灰的话用户不知道为什么灰，
//     点一下得到一句解释比一个灰按钮有用。
//  3. 更新源填写用 sheet + TextField，不用 alert 里的
//     TextField。alert 里的输入框在 iOS 上有历史 bug（键盘遮挡、
//     focus 丢失），仓库名这种要粘 URL 的输入特别容易踩。
//  ============================================================

import SwiftUI

struct SelfUpdateSection: View {

    // 检查状态。nil = 还没查过
    @State private var result: SelfUpdateResult?
    @State private var checking = false
    @State private var showSrcSheet = false

    // 更新源草稿（sheet 里编辑，保存才落地）
    @State private var draft = ""
    @State private var draftInvalid = false

    // 已保存的值，用来判断 sheet 里有没有未保存修改
    @State private var saved = SelfUpdate.repo

    var body: some View {
        Section {
            // ── 版本 ──
            HStack {
                Label {
                    SettingsRowLabel(.version, fallback: "版本")
                } icon: {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .frame(width: 21, height: 21)
                        .background(.indigo, in: Circle())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(SelfUpdate.displayVersion)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(saved.isEmpty ? "自有版本线，不走原版" : "自有版本线 · 更新源已设")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .settingsRowRenameable(.version,
                                   defaultName: AppLocalized("版本"))

            // ── 检查更新 ──
            Button {
                Task { await runCheck() }
            } label: {
                HStack {
                    Label {
                        SettingsRowLabel(.checkUpdate, fallback: "检查更新")
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9))
                            .foregroundStyle(.white)
                            .frame(width: 21, height: 21)
                            .background(.green, in: Circle())
                    }
                    Spacer()
                    if checking {
                        ProgressView().controlSize(.small)
                    } else if let r = result {
                        updateBadge(r)
                    }
                }
            }
            .foregroundStyle(.primary)
            .disabled(checking)
            .settingsRowRenameable(.checkUpdate,
                                   defaultName: AppLocalized("检查更新"))

            if let r = result, !checking {
                Text(r.message)
                    .font(.caption)
                    .foregroundStyle(color(for: r))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // ── 更新源 ──
            Button {
                draft = saved
                draftInvalid = false
                showSrcSheet = true
            } label: {
                HStack {
                    Label {
                        SettingsRowLabel(.updateSource, fallback: "更新源")
                    } icon: {
                        Image(systemName: "text.badge.checkmark")
                            .font(.system(size: 9))
                            .foregroundStyle(.white)
                            .frame(width: 21, height: 21)
                            .background(.teal, in: Circle())
                    }
                    Spacer()
                    Text(saved.isEmpty ? "未配置 · 不会去查原版" : saved)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
            .settingsRowRenameable(.updateSource,
                                   defaultName: AppLocalized("更新源"))
        } header: {
            Text("版本和更新")
        } footer: {
            Text(footerText)
        }
        .sheet(isPresented: $showSrcSheet) {
            srcSheet
        }
    }

    // MARK: - 子视图

    private func updateBadge(_ r: SelfUpdateResult) -> some View {
        let (text, bg): (String, Color) = {
            switch r {
            case .notConfigured:      return ("未配置", .gray)
            case .upToDate:           return ("最新", .green)
            case .updateAvailable:    return ("可更新", .blue)
            case .failed:             return ("失败", .red)
            }
        }()
        return Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(bg, in: Capsule())
    }

    private func color(for r: SelfUpdateResult) -> Color {
        switch r {
        case .notConfigured:    return .orange
        case .upToDate:         return .green
        case .updateAvailable:  return .blue
        case .failed:           return .red
        }
    }

    private var footerText: String {
        if saved.isEmpty {
            return "还没填更新源。没填之前「检查更新」只会告诉你没配，"
                 + "不会去问原版 —— 问它就等于给自己推原版的包。"
        }
        return "只查 \(saved) 的 release。原版 OpenMinis 发布什么都不影响这里。"
    }

    private var srcSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("用户名/仓库名", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: draft) { _, _ in draftInvalid = false }
                } header: {
                    Text("更新源仓库")
                } footer: {
                    if draftInvalid {
                        Text("要写成 用户名/仓库名，例如 yourname/OpenMinis-build")
                            .foregroundStyle(.red)
                    } else {
                        Text("只查这个仓库的 release。留空表示不检查更新。\n粘完整链接也行，会自动去掉 https://github.com/ 前缀。")
                    }
                }

                if !draft.isEmpty {
                    Section {
                        Button("清空（不再检查更新）", role: .destructive) {
                            draft = ""
                            commit()
                        }
                    }
                }
            }
            .navigationTitle("更新源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showSrcSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { commit() }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty == false
                                  && draft.split(separator: "/").count != 2)
                }
            }
        }
    }

    // MARK: - 动作

    private func commit() {
        guard SelfUpdate.setRepo(draft) else {
            draftInvalid = true
            return
        }
        saved = SelfUpdate.repo
        // 换了更新源，上次的结果就没意义了
        result = nil
        // 通知其他读 `SelfUpdate` 的界面（关于页的「更新源仓库」链接）
        // 重新求值。`SelfUpdate` 是纯 UserDefaults 读写、没有 @Published，
        // 不广播的话那个链接会一直用旧值画。
        NotificationCenter.default.post(name: .selfUpdateSourceChanged, object: nil)
        showSrcSheet = false
    }

    private func runCheck() async {
        checking = true
        result = nil
        let r = await SelfUpdate.check()
        result = r
        checking = false
    }
}
