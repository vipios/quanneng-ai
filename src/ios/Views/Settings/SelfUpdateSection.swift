//
//  SelfUpdateSection.swift
//  Minis — 设置页「版本和更新」区
//
//  ============================================================
//  [R40-更新两处删除] 这一版照着用户 2026-11-10 18:52 的截图改了两处
//
//  ① 删掉「检查更新」右边那枚「未配置」徽标。
//  ② 删掉「更新源」整行。
//
//  合起来是一件事：更新源已经内置（`SelfUpdate.builtinRepo`），
//  用户不需要知道它的存在，也就不需要有「配置它」的位置和
//  「还没配置」的提示。
//
//  第三件事不是删除而是改造：「检查更新」点下去现在会
//  自动测速 → 挑最快的线路 → 自动下载，不再停在「发现新版本」。
//  进度和结果都落在原来那个徽标的位置上，不新增一行。
//  ============================================================

import SwiftUI

struct SelfUpdateSection: View {

    // 检查 / 下载状态。nil = 还没查过
    @State private var result: SelfUpdateResult?
    @State private var checking = false
    @State private var downloading = false
    @State private var progress: Double = 0
    @State private var totalBytes: Int64 = 0
    @State private var savedFile: URL?
    @State private var showInstallHint = false

    var body: some View {
        Section {
            // ── 版本 ──
            // 副标题也一并去掉：用户要求这一组不许有小字。
            // 版本号本身已经说明一切，再写「自有版本线」只是噪音。
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
                Text(SelfUpdate.displayVersion)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .settingsRowRenameable(.version,
                                   defaultName: AppLocalized("版本"))

            // ── 检查更新 ──
            // 点一下就把整条流程跑完：测速 → 比版本 → 有新版就下载。
            Button {
                Task { await runCheckAndDownload() }
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
                    trailingStatus
                }
            }
            .foregroundStyle(.primary)
            .disabled(checking || downloading)
            .settingsRowRenameable(.checkUpdate,
                                   defaultName: AppLocalized("检查更新"))

            // 结果一句话。只在有话说的时候出现 ——
            // 常驻一行「点上面检查」是多余的，那一行标题已经写清楚了。
            if !checking && !downloading, let r = result {
                Text(r.message)
                    .font(.caption)
                    .foregroundStyle(color(for: r))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 下载完成后给一个安装入口。
            //
            // 为什么不自动装：iOS 的应用安装必须经过系统确认，
            // App 自己不能静默替换自己（TrollStore 环境也一样，
            // 它需要用户点一下）。所以这里只负责把包装好、把入口摆出来。
            if let f = savedFile {
                Button {
                    showInstallHint = true
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .foregroundColor(.blue)
                        Text("安装已下载的包")
                        Spacer()
                        Text(f.lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .alert("包已经下好了", isPresented: $showInstallHint) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text("文件在「文件」App → 全能AI → Updates 里。用 TrollStore 或全能签打开它就能装上。")
                }
            }
        } header: {
            Text("版本和更新")
        } footer: {
            // [R40] 原来这里有两套文案（配了 / 没配更新源）。
            // 现在没有「配没配」这回事，只说一件事：包从哪来。
            Text("更新包从 \(SelfUpdate.builtinRepo) 的 release 取，会自动挑当前最快的线路下载。")
        }
    }

    // MARK: - 右侧状态

    @ViewBuilder
    private var trailingStatus: some View {
        if downloading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(percentText)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else if checking {
            // 「测速中」而不是「检查中」：这次真的在测四条线路，
            // 文案跟着实际动作走。
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("测速中")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if let r = result {
            updateBadge(r)
        } else {
            // [R40-删未配置] 这里原来是写死的「未配置」灰徽标。
            // 没有结果时什么都不画 —— 空白比一个假状态干净。
            EmptyView()
        }
    }

    private var percentText: String {
        let mb = Double(totalBytes) / 1_048_576
        if mb < 0.1 { return "\(Int(progress * 100))%" }
        return "\(Int(progress * 100))%  \(String(format: "%.0f", mb))MB"
    }

    private func updateBadge(_ r: SelfUpdateResult) -> some View {
        let (text, bg): (String, Color) = {
            switch r {
            case .notConfigured:      return ("未配置", .gray)
            case .upToDate:           return ("最新", .green)
            case .updateAvailable:    return ("有新版", .blue)
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

    // MARK: - 动作

    /// 一次点击走完整条：测速 → 判断 → 有新版就下载。
    ///
    /// 不做二次确认。用户的原话是「点一下就自动判断、自动下载」，
    /// 中间插一个「要下载吗」的弹窗就是把他的要求又推回去一次。
    ///
    /// 测速只做一次：`check()` 返回的 `win` 就是那条最快的线路，
    /// 下载直接复用它。再单独 race 一轮是白等。
    private func runCheckAndDownload() async {
        checking = true
        result = nil
        savedFile = nil
        progress = 0
        totalBytes = 0

        let outcome = await SelfUpdate.check()
        result = outcome.result
        checking = false

        // 只有「有新版」才继续。已是最新 / 失败都停在这里。
        guard case .updateAvailable = outcome.result, let win = outcome.win else { return }

        guard SelfUpdate.downloadURL(for: win) != nil else {
            result = .failed(reason: "这个版本里没有可安装的包")
            return
        }

        downloading = true
        progress = 0
        totalBytes = win.ipaSize

        do {
            // 进度回调是从 URLSession 的后台队列来的，@State 只能在主线程改，
            // 所以闭包里显式跳一次 MainActor。这不是多余的保险 ——
            // 直接写 progress = p 会触发「Publishing changes from
            // background threads is not allowed」并在真机上表现为界面卡住。
            let file = try await SelfUpdate.download(win: win) { p, total in
                Task { @MainActor in
                    progress = p
                    if total > 0 { totalBytes = total }
                }
            }
            savedFile = file
        } catch {
            // 失败不把 result 打回「有新版」—— 那会让人以为没下载成功是错觉。
            result = .failed(reason: (error as? SelfUpdateError)?.errorDescription
                                    ?? error.localizedDescription)
        }

        downloading = false
    }
}
