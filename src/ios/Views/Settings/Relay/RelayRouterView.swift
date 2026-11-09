//
//  RelayRouterView.swift
//  Minis — 路由器管理页
//
//  ============================================================
//  设计（R17 要求「重新规划页面」，不是照搬 Cabin）
//
//  原版四个问题，这一版逐个解决：
//
//  ① 顶部「在家·直连」卡与下方状态卡信息重复
//      → 合并成**一张顶部概览卡**：线路 + 在线状态在同一张卡里，
//        线路用图标颜色区分，在线状态用一个小圆点。不再有第二张卡重复。
//
//  ② 运行时长和内存两栏留白过多，数值大字压不住
//      → 改成**自适应网格**，数值字号加大到 22pt semibold + 等宽数字，
//        单位缩小一级；三列（时长 / 可用内存 / 负载）填满宽度，不留空。
//
//  ③ 两个重启按钮层级相同，危险程度却差一个量级
//      → **视觉分级**：常规操作（蓝，普通按钮）与危险操作（红，需长按确认）
//        分两组，中间留 20pt 空隙；危险按钮带「会断网」的红色说明条。
//
//  ④ 没有「该不该重启」的智能提示（后端 already 有 should_reboot）
//      → 顶部概览卡下方加**建议条**：命中内存/swap 阈值时出现，
//        直接给「建议只重启中转站」的一句话 + 一键跳转。
//  ============================================================

import SwiftUI

struct RelayRouterView: View {

    @ObservedObject private var store = RelayStore.shared
    @State private var pending: RelayStore.PowerAction?
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if store.unconfigured {
                    setupCard
                    // 结果条不能只在「已配置」分支里显示。
                    // 没配密码时点重启，perform 会直接把「需要先填密码」写进 actionResult，
                    // 要是这里不渲染，用户点完按钮屏幕一动不动，看着像点坏了。
                    if let r = store.actionResult {
                        resultBanner(r)
                    }
                    // errorText 同理：没配密钥时 refresh 也可能写出
                    // 「路由器没响应」这类话，不渲染等于白算。
                    if !store.errorText.isEmpty {
                        errorCard
                    }
                } else {
                    overviewCard

                    if let hint = rebootHintRow {
                        hint
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    metricsCard

                    if !store.errorText.isEmpty {
                        errorCard
                    }

                    actionsSection

                    if let r = store.actionResult {
                        resultBanner(r)
                    }
                }

                settingsLink
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("路由器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if store.busy {
                    ProgressView().scaleEffect(0.8)
                }
            }
        }
        .refreshable {
            await store.refresh()
        }
        .onAppear {
            store.refreshIfStale()
            RelayStore.shared.clearActionResult()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            store.refreshIfStale()
        }
        .confirmationDialog(
            pending?.confirmTitle ?? "",
            isPresented: Binding(get: { pending != nil },
                                 set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            if let action = pending {
                Button(action.confirmButton, role: .destructive) {
                    let a = action
                    pending = nil
                    Task { await store.perform(a) }
                }
                Button("取消", role: .cancel) { pending = nil }
            }
        } message: {
            Text(pending?.confirmMessage ?? "")
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                RelaySettingsView()
            }
        }
    }

    // MARK: - 概览卡（合并原「线路卡」+「状态卡」）

    /// 还没配过密码时的引导卡。
    /// 不做成「弹输入框」，因为用户可能只是路过点进来看看。
    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.blue)
                Text("先填一次后台密码")
                    .font(.headline)
            }
            Text("填过之后就一直记住，以后进后台、重启中转站、重启路由器都不会再问你。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            NavigationLink {
                RelaySettingsView()
            } label: {
                Text("去填写")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private var overviewCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(routeTint.opacity(0.14))
                        .frame(width: 46, height: 46)
                    Image(systemName: store.route?.icon ?? "questionmark")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(routeTint)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(store.route?.label ?? "正在判定…")
                        .font(.headline)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(onlineTint)
                            .frame(width: 6, height: 6)
                        Text(onlineText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().opacity(0.4)

            infoRow("地址", store.route?.displayAddress ?? "—", mono: true)
            Divider().opacity(0.25).padding(.leading, 16)
            infoRow("通道", store.route?.detail ?? "—", mono: false)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var routeTint: Color {
        guard let r = store.route else { return .secondary }
        return r.isLan ? .green : .orange
    }

    private var onlineTint: Color {
        switch store.routerOnline {
        case .some(true):  return .green
        case .some(false): return .red
        case .none:        return .secondary.opacity(0.5)
        }
    }

    private var onlineText: String {
        switch store.routerOnline {
        case .some(true):  return "路由器在线"
        case .some(false): return "路由器没响应"
        case .none:        return "检测中…"
        }
    }

    // MARK: - 建议条（原版没用 should_reboot，这里用起来）

    private var rebootHintRow: AnyView? {
        guard let d = store.device, d.recommendReboot,
              let reason = d.rebootReason else { return nil }
        return AnyView(
            Button {
                pending = .restartRelay
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("建议重启中转站")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        Text(reason)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .padding(12)
                .background(Color.orange.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        )
    }

    // MARK: - 指标卡（三列自适应，数值加大）

    private var metricsCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                metric(title: "运行时长",
                       value: store.device?.uptimeText ?? "—",
                       icon: "clock",
                       warn: false)
                divider
                metric(title: "可用内存",
                       value: store.device?.memAvailText ?? "—",
                       icon: "memorychip",
                       warn: store.device?.memLow == true)
                divider
                metric(title: "系统负载",
                       value: store.device?.loadText ?? "—",
                       icon: "speedometer",
                       warn: store.device?.loadHigh == true)
            }
            .padding(.vertical, 16)

            if let d = store.device {
                Divider().opacity(0.3)
                HStack(spacing: 16) {
                    smallStat("交换", d.swapText, d.swapHigh)
                    smallStat("中转站内存", d.relayRssText, false)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 34)
    }

    private func metric(title: String, value: String, icon: String, warn: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(warn ? .orange : .secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundColor(warn ? .orange : .primary)
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func smallStat(_ title: String, _ value: String, _ warn: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(warn ? .orange : .primary)
        }
        .frame(maxWidth: .infinity)
    }

    private func infoRow(_ title: String, _ value: String, mono: Bool) -> some View {
        HStack {
            Text(title)
                .font(.footnote)
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    // MARK: - 操作（视觉分级）

    private var actionsSection: some View {
        VStack(spacing: 20) {
            // 第一组：常规
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("日常维护")
                actionButton(
                    action: .restartRelay,
                    icon: "arrow.clockwise.circle.fill",
                    tint: .blue,
                    title: "只重启中转站",
                    note: "网页断几秒，WiFi 不断"
                )
            }

            // 第二组：危险（单独成组 + 红色警示条）
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("危险操作")
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text("整台路由器重启会让家里所有设备断网约 1 分钟")
                        .font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 2)

                actionButton(
                    action: .rebootRouter,
                    icon: "power.circle.fill",
                    tint: .red,
                    title: "重启路由器",
                    note: rebootNote
                )
            }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.leading, 2)
    }

    /// 重启路由器按钮下面那行小字。
    ///
    /// 说实话，不粉饰：
    ///   · 判断不出线路 → 直说「还没判出来」，不要拿它假装是禁用原因
    ///   · 在家        → 走 airboot（http 80），最快
    ///   · 在外        → 也走 airboot（https 443，隧道转进去），
    ///                    **只需要路由器指令密钥**，不需要后台密码
    ///                   （2026-11-09 实测：直接回 {"ok":true,"svc":"airboot"}）
    ///   · 一个密钥都没有 → 提示去填，因为这时候点了也只会报错
    ///
    /// 早前这里在外写的是「经隧道下发指令」，让人以为是走后台接口、
    /// 要后台密码、断网逻辑也不同。实际走的还是 airboot，文案得跟着改。
    private var rebootNote: String {
        _ = store.vaultRevision   // 建依赖，见 RelayStore.vaultRevision 的说明
        guard store.route != nil else { return "线路还没判出来，稍等一下" }
        if store.route?.isLan == true { return "当前在家直连，走最快路径" }
        if RelayVault.shared.effectiveRouterKey.isEmpty { return "还缺密钥，先去设置里填一次" }
        return "经隧道下发，不需要后台密码"
    }

    private func actionButton(action: RelayStore.PowerAction,
                              icon: String,
                              tint: Color,
                              title: String,
                              note: String) -> some View {
        let enabled = store.canPerform(action)
        return Button {
            pending = action
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(enabled ? tint : Color.secondary.opacity(0.4))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(enabled ? .primary : .secondary)
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.4))
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(tint.opacity(enabled ? 0.18 : 0), lineWidth: 1)
            )
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func resultBanner(_ r: (ok: Bool, text: String)) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(r.ok ? .green : .red)
            Text(r.text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background((r.ok ? Color.green : Color.red).opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var errorCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 13))
                .foregroundColor(.orange)
            Text(store.errorText)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var settingsLink: some View {
        Button {
            showSettings = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                Text("地址与密码设置")
                    .font(.footnote)
            }
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }
}
