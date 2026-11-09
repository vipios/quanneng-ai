//
//  RelaySettingsView.swift
//  Minis — 中转站 / 路由器线路设置
//
//  四段：线路（两个地址）、后台密码、路由器密钥、诊断
//
//  设计原则：
//    · 地址只存 host，端口由线路决定 —— 界面上明确写出「不用填端口」，
//      用户填了也会被剥掉（RelayVault.cleanHost）
//    · 保存时立刻按新地址重判一次，用户改完马上能看到结果，
//      不用退出去再拉一下
//    · 密码留空 = 不修改，避免用户只想改地址却被清掉密码
//

import SwiftUI

struct RelaySettingsView: View {

    @ObservedObject private var store = RelayStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var homeHost = RelayVault.shared.homeHost
    @State private var awayHost = RelayVault.shared.awayHost
    @State private var newPass = ""
    @State private var newRouterKey = ""
    @State private var showAdvanced = false
    @State private var showLog = false
    @State private var verifyState: VerifyState = .idle
    /// 正在保存（保存里可能要验一次密码，不能让按钮连点）
    @State private var saving = false
    /// 保存被拒的原因。与 verifyState 分开：verifyState 是紧凑标签，
    /// 这里是完整一句，会被渲染成红色脚注。
    @State private var saveError = ""
    /// 已经记住密码时，默认不显示输入框；点「更换密码」才显示。
    @State private var changingPassword = false

    private enum VerifyState: Equatable {
        case idle
        case checking
        case ok
        case fail(String)
    }

    /// 密码是否已记住。
    /// 读的是 UserDefaults，SwiftUI 不会自己发现变化 ——
    /// 所以显式引用 store.vaultRevision 建立依赖：任何写 Vault 的地方
    /// 都会把它 +1，这里就会重算。
    ///
    /// 以前用的是本视图自己的 `vaultRev`，只在「本视图存成功」时自增。
    /// 可这个视图会被 sheet 复用，别处（比如上次留下的 sheet 实例）改了
    /// Vault，它不会知道 —— 界面还显示「还没填过」，其实早就存好了。
    private var remembered: Bool {
        _ = store.vaultRevision
        return RelayVault.shared.hasPassword
    }

    var body: some View {
        Form {
            routeSection
            passwordSection
            routerKeySection
            statusSection
            diagnosticsSection
        }
        .navigationTitle("线路设置")
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
                .disabled(saving)
            }
        }
        .sheet(isPresented: $showLog) {
            NavigationStack {
                RelayLogView()
            }
        }
    }

    // MARK: - 线路

    private var routeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("直连")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("直连地址", text: $homeHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 14, design: .monospaced))
            }
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("在外用的域名")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("example.dpdns.org", text: $awayHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 14, design: .monospaced))
            }
            .padding(.vertical, 2)
        } header: {
            Text("线路")
        } footer: {
            Text("App 会打 http://\(RelayVault.cleanHost(homeHost))/health，通了就是在家里走直连，不通就走域名。两个都只填主机名，**不用填端口**（直连固定 8080、域名走 443）。")
        }
    }

    // MARK: - 密码

    private var passwordSection: some View {
        Section {
            if remembered {
                // 已经记住了 —— 不再摆一个输入框在脸上让人以为要填。
                // 想换密码点「更换」，才会出现输入框。
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("密码已记住")
                            .font(.subheadline.weight(.medium))
                        Text("以后进后台、重启设备都不会再问你")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)

                if changingPassword {
                    SecureField("新密码", text: $newPass)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack(spacing: 12) {
                        Button("取消") {
                            changingPassword = false
                            newPass = ""
                            verifyState = .idle
                        }
                        .foregroundColor(.secondary)

                        Button {
                            Task { await verify() }
                        } label: {
                            verifyLabel(idleTitle: "验证新密码")
                        }
                        .disabled(verifyState == .checking || newPass.isEmpty)
                    }
                    .font(.footnote)
                } else {
                    // 两个动作层级差很多：「更换密码」是主动改配置，
                    // 「测一下」只是自检。以前两个都是 `.footnote` 蓝色
                    // 并排挨着，手指粗一点就点错 —— 点错「更换密码」
                    // 至少还只是多出一个输入框，点错「测一下」会立刻
                    // 发起一次网络请求，看着像界面自己抽风。
                    //
                    // 现在：主按钮靠左、自检靠右并且压成灰色小字，
                    // 中间用 Spacer 拉开，视觉上不再像一组并列选项。
                    HStack(alignment: .firstTextBaseline) {
                        Button {
                            changingPassword = true
                        } label: {
                            Text("更换密码").font(.footnote)
                        }

                        Spacer(minLength: 16)

                        Button {
                            Task { await verify() }
                        } label: {
                            HStack(spacing: 5) {
                                verifyLabel(idleTitle: "")
                                Text("测一下")
                            }
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        }
                        .disabled(verifyState == .checking)
                    }
                }
            } else {
                // 从没填过：这里才需要输入
                SecureField("输入后台密码（只需一次）", text: $newPass)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    Task { await verify() }
                } label: {
                    verifyLabel(idleTitle: "保存并验证")
                }
                .disabled(verifyState == .checking || newPass.isEmpty)
            }
        } header: {
            Text("后台密码")
        } footer: {
            if !saveError.isEmpty {
                Text(saveError)
                    .foregroundColor(.red)
            } else {
                Text(remembered
                     ? "密码用 AES-GCM 加密后只存在这台手机上。进后台、重启中转站、重启路由器都直接用它，不会再让你输入。"
                     : "只需输入这一次。存好之后进后台、重启设备都不会再问你。")
            }
        }
    }

    /// 验证结果的统一显示。
    ///
    /// idleTitle 必须由调用处给：以前这里写死成
    /// `Text(remembered ? "" : "保存并验证")`，于是「已记住 + 点了更换密码」
    /// 那条路径上按钮标题是空串 —— 一个看不见、但能点的按钮，
    /// 用户根本不知道新密码填完该点哪儿。
    @ViewBuilder
    private func verifyLabel(idleTitle: String) -> some View {
        switch verifyState {
        case .idle:
            Text(idleTitle)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("正在测…")
            }
        case .ok:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("密码可用")
            }
        case .fail(let m):
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                Text(m).lineLimit(2)
            }
        }
    }

    // MARK: - 路由器密钥

    private var routerKeySection: some View {
        Section {
            SecureField(RelayVault.shared.routerKey() == nil ? "与后台密码相同（默认）" : "留空则不修改",
                        text: $newRouterKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("路由器指令密钥")
        } footer: {
            Text("airboot 的 k 参数。历史配置里通常与后台密码相同，留空就用后台密码。只有两者不同时才需要单独填。")
        }
    }

    // MARK: - 当前状态

    private var statusSection: some View {
        Section {
            if let r = store.route {
                HStack {
                    Text("当前线路")
                    Spacer()
                    Text(r.label)
                        .foregroundColor(r.isLan ? .green : .orange)
                }
                HStack {
                    Text("正在使用")
                    Spacer()
                    Text(r.displayAddress)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                HStack {
                    Text("当前线路")
                    Spacer()
                    Text("正在判定…").foregroundColor(.secondary)
                }
            }

            HStack {
                Text("路由器")
                Spacer()
                switch store.routerOnline {
                case .some(true):  Text("在线").foregroundColor(.green)
                case .some(false): Text("没响应").foregroundColor(.red)
                case .none:        Text("—").foregroundColor(.secondary)
                }
            }

            Button {
                Task { await store.refresh() }
            } label: {
                HStack(spacing: 6) {
                    if store.busy { ProgressView().scaleEffect(0.7) }
                    Text("立刻重新判定")
                }
                .font(.footnote)
            }
            .disabled(store.busy)
        } header: {
            Text("现在")
        }
    }

    // MARK: - 诊断

    private var diagnosticsSection: some View {
        Section {
            Button {
                showLog = true
            } label: {
                HStack {
                    Text("判定日志")
                    Spacer()
                    Text("\(RelayLog.shared.dump.count) 条")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .font(.footnote)
            }
        } header: {
            Text("诊断")
        } footer: {
            Text("判定失败、走错线路时，先看这里。日志只记录探测地址与结果，不包含密码。")
        }
    }

    // MARK: - 动作

    private func verify() async {
        let p = newPass.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = p.isEmpty ? (RelayVault.shared.password() ?? "") : p
        guard !key.isEmpty else {
            verifyState = .fail("先输入密码")
            return
        }
        verifyState = .checking
        saveError = ""

        guard await canVerify(key) else {
            verifyState = .fail("密码不对，或连不上设备")
            return
        }

        verifyState = .ok

        // 验证通过就直接记住 —— 不要让用户「测通了还要再点一次保存」。
        // 只输入一次，这是需求。
        if !p.isEmpty {
            RelayVault.shared.save(password: p)
            newPass = ""
            changingPassword = false
            store.changePassword(p)
        }
        await store.refresh()
    }

    private func save() async {
        saving = true
        defer { saving = false }
        saveError = ""

        // 顺序很重要：**先落地址，再验密码**。
        //
        // 用户很可能一次改两样（家里换了网段 + 顺手换了密码）。
        // 如果先验证再写地址，验证打的是旧地址：
        //   · 旧地址已经不通 → 会误报「密码不对，没有保存」
        //   · 用户明明填的是对的，却被拦下来，还查不出原因
        // 所以地址先落，后面的验证与 refresh 都用新地址。
        RelayVault.shared.homeHost = homeHost
        RelayVault.shared.awayHost = awayHost

        let pass = newPass.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pass.isEmpty {
            // 先验再存。
            //
            // 以前这里是无条件 `save(password:)`：用户手滑打错一个字符也会被
            // 当成正确密码存下来，然后进后台只有一句「需要访问密钥」，
            // 页面本身没有任何提示 —— 用户根本不知道自己填错了。
            verifyState = .checking
            if await canVerify(pass) {
                RelayVault.shared.save(password: pass)
                newPass = ""
                verifyState = .ok
                store.changePassword(pass)
            } else {
                let msg = "连不上新地址，或密码不对 —— 密码没有保存。"
                verifyState = .fail(msg)
                saveError = msg
                // 地址已经写进去了（那是用户明确要改的），
                // 但不关面板，让他能看到失败原因并决定改回去还是改密码。
                return
            }
        }

        let rk = newRouterKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rk.isEmpty {
            // 走 store 而不是直写 Vault：store 要重算「配没配过」，
            // 还要 +1 vaultRevision 让其它页面重算（按钮小字、引导卡、WebView 注入）。
            store.changeRouterKey(rk)
            newRouterKey = ""
        }

        // 存完立刻按新地址重判一次，再关面板 ——
        // 用户改完地址马上能看到结果，不用退出去再拉一下。
        Task { await store.refresh() }
        dismiss()
    }

    /// 用**刚填的**地址验证密码，不看 store 的线路缓存。
    ///
    /// 必须这样：`store.route` 是上一次判定的结果，改了地址以后它还是旧的。
    /// 拿旧线路去验新密码，改地址的用户会一直被拦。
    /// 判据与 `RelayBackend.verifyKey` 一致：只有明确 401/403 才算密码错，
    /// 连不上不能算密码错 —— 所以两条地址各自尝试，任一通过即通过。
    private func canVerify(_ key: String) async -> Bool {
        var bases: [String] = []
        let h = RelayVault.cleanHost(homeHost)
        if !h.isEmpty { bases.append("http://\(h):8080") }
        let a = RelayVault.cleanHost(awayHost)
        if !a.isEmpty { bases.append("https://\(a)") }

        for base in bases {
            if await RelayBackend.verifyKey(base: base, key: key) { return true }
        }
        return false
    }
}

// MARK: - 判定日志

struct RelayLogView: View {
    @State private var lines: [String] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if lines.isEmpty {
                    Text("（暂无记录）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 20)
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("判定日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新") { lines = RelayLog.shared.dump }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("清空") {
                    RelayLog.shared.clear()
                    lines = []
                }
            }
        }
        .onAppear { lines = RelayLog.shared.dump }
    }
}
