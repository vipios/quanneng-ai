//
//  AddRelayProviderView.swift
//  Minis — 添加 AI 中转站（R9–R13）
//
//  与「添加 AI 服务商」的区别：中转站要配**两个**地址。
//    内网地址 —— 在家直连，实测 0.07 秒
//    外网地址 —— 在外面走域名/隧道，实测 2.5 秒
//  相差 35 倍，所以线路判准比什么都重要。
//
//  ============================================================
//  表单字段
//    · 名称
//    · 协议类型（OpenAI 兼容 / Anthropic 兼容）
//    · 内网地址
//    · 外网地址
//    · API Key
//    · 线路偏好（自动判定 / 只用内网 / 只用外网）
//
//  保存时做两件事：
//    ① 建一个普通 ProviderInstance（credentialType = .apiKey，
//       customBaseURL = 内网地址，作为离线兜底）
//    ② 写一条中转站档案（双地址 + 线路偏好）
//  然后立刻按当前网络判定一次，把结果缓存进档案。
//  ============================================================

import SwiftUI

struct AddRelayProviderView: View {

    @Environment(\.dismiss) private var dismiss

    /// 外部传入：保存成功后回调，用于让列表刷新
    var onSaved: ((String) -> Void)?

    @State private var label = ""
    @State private var protocolKind: RelayProtocolKind = .openAI
    @State private var homeURL = ""
    @State private var awayURL = ""
    @State private var apiKey = ""
    @State private var routeMode: RelayRouteMode = .auto
    @State private var appendV1 = true

    @State private var testing = false
    @State private var testResult: TestResult?
    @State private var saving = false
    @State private var saveError = ""

    private enum TestResult: Equatable {
        case homeOK(Double)
        case homeFail
        case awayOK(Double)
        case awayFail
        case bothFail
    }

    var body: some View {
        Form {
            basicsSection
            addressSection
            keySection
            modeSection

            if let r = testResult {
                resultSection(r)
            }

            if !saveError.isEmpty {
                Section {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("添加 AI 中转站")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if saving {
                        ProgressView().scaleEffect(0.75)
                    } else {
                        Text("保存").font(.body.weight(.semibold))
                    }
                }
                .disabled(!canSave || saving)
            }
        }
        .onAppear {
            // 预填上次用过的中转站地址，减少重复输入
            if homeURL.isEmpty {
                homeURL = "http://\(RelayVault.shared.homeHost):8080"
            }
            if awayURL.isEmpty {
                awayURL = "https://\(RelayVault.shared.awayHost)"
            }
        }
    }

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !homeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !awayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 基础

    private var basicsSection: some View {
        Section {
            TextField("例如：家里中转站", text: $label)

            Picker("协议", selection: $protocolKind) {
                ForEach(RelayProtocolKind.allCases) { k in
                    Text(k.title).tag(k)
                }
            }

            if protocolKind == .openAI {
                Toggle("自动追加 /v1", isOn: $appendV1)
            }
        } header: {
            Text("基础")
        } footer: {
            Text("协议类型决定走哪套接口：OpenAI 兼容走 /v1/chat/completions，Anthropic 兼容走 /v1/messages。中转站两种都支持时选 OpenAI 兼容即可。")
        }
    }

    // MARK: - 地址

    private var addressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("内网地址")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("http://192.168.1.88:8080", text: $homeURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 14, design: .monospaced))
            }
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("外网地址")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("https://xxx.dpdns.org", text: $awayURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 14, design: .monospaced))
            }
            .padding(.vertical, 2)

            Button {
                Task { await test() }
            } label: {
                HStack(spacing: 6) {
                    if testing {
                        ProgressView().scaleEffect(0.7)
                        Text("正在测…")
                    } else {
                        Image(systemName: "bolt.horizontal")
                        Text("测试连不连得通")
                    }
                }
                .font(.footnote)
            }
            .disabled(testing)
        } header: {
            Text("两个地址")
        } footer: {
            Text("这里要连**完整地址**（含协议和端口），和「中转站后台」的线路设置不同——那边只填主机名。内网快 35 倍，所以在家一定走内网。")
        }
    }

    // MARK: - Key

    private var keySection: some View {
        Section {
            SecureField("sk-...", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("API Key")
        } footer: {
            Text("存在系统钥匙串里，不会写进配置文件，也不会上传到任何服务器。")
        }
    }

    // MARK: - 线路偏好

    private var modeSection: some View {
        Section {
            ForEach(RelayRouteMode.allCases) { m in
                Button {
                    routeMode = m
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: m.icon)
                            .font(.system(size: 14))
                            .foregroundColor(.accentColor)
                            .frame(width: 26, height: 26)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            Text(m.subtitle)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Spacer(minLength: 0)

                        if routeMode == m {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("线路选择")
        } footer: {
            Text("自动判定会在每次发请求前探一次内网地址（超时 1.2 秒）。固定在家或固定在外时选「只用」，可以省掉这次探测。")
        }
    }

    // MARK: - 测试结果

    private func resultSection(_ r: TestResult) -> some View {
        Section {
            switch r {
            case .homeOK(let ms):
                resultRow(ok: true, title: "内网可用",
                          detail: String(format: "%.0f ms · 在家会走这条", ms))
            case .homeFail:
                resultRow(ok: false, title: "内网不通",
                          detail: "正常。不在家，或者中转站没启动")
            case .awayOK(let ms):
                resultRow(ok: true, title: "外网可用",
                          detail: String(format: "%.2f s · 在外面走这条", ms / 1000))
            case .awayFail:
                resultRow(ok: false, title: "外网不通",
                          detail: "检查隧道、域名解析，或 Key 是否正确")
            case .bothFail:
                resultRow(ok: false, title: "两个都不通",
                          detail: "先确认中转站服务在跑，再对一遍地址和端口")
            }
        } header: {
            Text("测试结果")
        }
    }

    private func resultRow(ok: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote.weight(.medium))
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 动作

    /// 测试：两条都探，各自计时。
    /// 判据与请求路径一致 —— 能拉到 /models 才算真能用，只看 200 不够。
    private func test() async {
        testing = true
        testResult = nil
        defer { testing = false }

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = homeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = awayURL.trimmingCharacters(in: .whitespacesAndNewlines)

        async let h = probe(home, key: key)
        async let a = probe(away, key: key)
        let (homeMs, awayMs) = await (h, a)

        if let hm = homeMs {
            testResult = .homeOK(hm)
        } else if let am = awayMs {
            testResult = .awayOK(am)
        } else {
            testResult = .bothFail
        }
    }

    /// 返回耗时（毫秒）；不通返回 nil
    ///
    /// 探活要试**候选路径**，不能只拼一条：
    /// OpenAI 兼容的中转站有的把模型列表挂在 `/v1/models`，有的直接在
    /// `/models`（前面另有反代已经吃掉 /v1）。只试一条，路径不对就是 404，
    /// 而 404 在这里等于「不通」，会被记成「在外」—— 见 `save()` 里的说明。
    /// 所以按「用户配置优先，另一种兜底」的顺序各试一次，任一成功即算通。
    private func probe(_ base: String, key: String) async -> Double? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        guard !b.isEmpty else { return nil }

        // 候选 1：按当前 appendV1 设置拼（用户就是这么配的，优先尊重）
        var paths: [String] = []
        if protocolKind == .openAI {
            if appendV1 {
                let withV1 = b.hasSuffix("/v1") ? b : b + "/v1"
                paths.append(withV1 + "/models")
                if !b.hasSuffix("/v1") { paths.append(b + "/models") }
            } else {
                paths.append(b + "/models")
                if !b.hasSuffix("/v1") { paths.append(b + "/v1/models") }
            }
        } else {
            // Anthropic 兼容没有 /models，用 /v1/messages 探
            // （不带 body 会回 400，但 400 说明「到了」，见下面的判据）
            paths.append(b + "/v1/messages")
        }

        for p in paths {
            if let ms = await probeOne(p, key: key) { return ms }
        }
        return nil
    }

    /// 探一条具体 URL。返回耗时（毫秒）；不通返回 nil。
    ///
    /// 判据：2xx 算通；401/403/400 也算通 —— 它们都证明「请求到达了服务」，
    /// 只是 Key 没带或 body 不全。只有连不上、超时、5xx 才算不通。
    /// 这与 `RelayProbe.reachable(home:)` 认 `service` 字段的思路一致：
    /// 判的是「是不是目标服务在应答」，不是「这次调用成不成功」。
    private func probeOne(_ fullURL: String, key: String) async -> Double? {
        guard let url = URL(string: fullURL) else { return nil }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        let m = NSMutableURLRequest(url: url)
        m.timeoutInterval = 8
        m.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        m.setValue(key, forHTTPHeaderField: "Authorization")
        m.setValue("application/json", forHTTPHeaderField: "Accept")
        if protocolKind == .anthropic {
            m.setValue(key, forHTTPHeaderField: "x-api-key")
            m.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }

        let start = Date()
        guard let (_, resp) = try? await session.data(for: m as URLRequest),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return nil }
        guard (200...299).contains(code) || code == 400 || code == 401 || code == 403
        else { return nil }
        return Date().timeIntervalSince(start) * 1000
    }

    private func save() async {
        saving = true
        saveError = ""
        defer { saving = false }

        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = homeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = awayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // 建实例：customBaseURL 用内网地址（离线兜底），
        // 真正生效的地址由中转站档案 + requestBaseURL 决定
        let providerType: ProviderType = protocolKind == .openAI ? .openAI : .anthropic
        let instance = ProviderInstance(
            label: name,
            providerType: providerType,
            credentialType: .apiKey,
            customBaseURL: home,
            appendV1Suffix: protocolKind == .openAI ? appendV1 : true
        )

        // 先判定一次，把结果缓存进档案（失败也不阻塞保存）。
        //
        // ⚠️ 必须复用 test() 用的那个 probe，不能另写一套：
        // 早前这里调的是 `RelayProbe.reachableHome(home)`，它直接拼
        // `base + "/models"`，而 relay 的模型列表在 `/v1/models` ——
        // 用户填 `http://192.168.1.88:8080` 时探的是 `/models`，
        // 404 → 返回 false → `lastResolvedIsLan = false`。
        // 结果就是：明明在家保存的中转站，被记成「在外」，
        // 之后每次发消息都先走域名绕一圈，白慢 35 倍，直到某次
        // 用户手动刷新才纠正。这就是两套逻辑打架的典型代价。
        let isLan = await probe(home, key: key) != nil

        let profile = RelayProviderProfile(
            instanceId: instance.id,
            homeURL: home,
            awayURL: away,
            routeMode: routeMode,
            protocolKind: protocolKind,
            lastResolvedIsLan: isLan,
            lastResolvedAt: Date(),
            // 档案里也要存一份 —— 将来加「编辑中转站」时靠它回填，
            // 否则每次打开编辑页都显示默认值，用户改都不改就被覆盖掉。
            appendV1Suffix: instance.appendV1Suffix
        )

        // 顺序：先写 Key（失败就整单不落），再写档案，最后加实例。
        // 这样任何一步失败都不会留下「有实例没 Key」的坏状态。
        ProviderKeychainHelper.saveAPIKey(key, instanceId: instance.id)
        guard ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) != nil else {
            saveError = "保存失败：API Key 无法写入钥匙串。"
            return
        }

        RelayProfileStore.shared.upsert(profile)
        ProviderConfigStore.shared.addInstance(instance)

        onSaved?(instance.id)
        dismiss()
    }
}

// MARK: - 探测辅助
//
// 这里原本有一个 `RelayProbe.reachableHome(_:)`，探的是 `base + "/models"`。
// 已经删掉，原因写在 `save()` 里：它和本文件的 `probe(_:key:)` 是两套判据，
// 前者探错路径（少了 /v1）就会把「在家」误判成「在外」并写进档案。
// 线路判定只留一份实现，要探就调 `probe(_:key:)`。
