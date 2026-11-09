//
//  GitHubAccountView.swift
//  Minis — 设置页「GitHub 账号」
//
//  ============================================================
//  这个页面回答三个问题，顺序也按这个来：
//    1. 登录了吗？          → 第一段
//    2. 云端编译能用了吗？  → 第二段（仓库配置 + 权限检查）
//    3. 什么时候会用它？    → 第三段（本机 / 云端的分工说明）
//
//  为什么单独讲第 3 点：用户要的是「GitHub 作为兜底」，
//  不是「什么都往云端推」。界面上必须把这条规则写死在那儿，
//  否则用起来会怀疑它是不是偷偷把什么都传上去了。
//  ============================================================
//
//  ⚠️ 登录用 Device Flow，所以界面要有「8 位码」这一步。
//     这个码是**给用户看的**，不是内部状态 —— 要能长按复制，
//     要能直接点开 GitHub 的输码页面。
//  ============================================================

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct GitHubAccountView: View {

    @ObservedObject private var store = GitHubStore.shared
    @State private var verifying = false
    @State private var verifyMessage = ""
    @State private var verifyOK: Bool?
    @State private var showSignOutConfirm = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            masterSwitchSection
            accountSection
            if store.signedIn {
                scopeSection
                repoSection
                routeSection
            }
            aboutSection
        }
        .navigationTitle("GitHub 账号")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.reloadFromDisk() }
        .alert("退出 GitHub 账号？", isPresented: $showSignOutConfirm) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) { store.signOut() }
        } message: {
            Text("只会清掉这台手机上保存的令牌。GitHub 那边的授权还在，要在网页上撤销请去 Settings → Applications。")
        }
    }

    // MARK: - 零、总开关
    //
    // [T-minis-gh-fallback-switch] 用户要求：「我打开了才有兜底方案，
    // 我不开他就没有这个选择项，AI 就不知道有这个功能了。」
    //
    // 所以这个 Toggle 不是「隐藏一个按钮」，它接的是 AgentToolSwitch，
    // 关掉时：工具不在 schema 里、提示词不提、派发器拒绝残留调用。
    // 三处同时生效，AI 侧确实不存在这个能力。
    //
    // 放在最上面，因为它决定下面几段有没有意义 —— 关着的时候填仓库、看
    // 权限都只是准备工作，不会真的发生任何事。footer 把这点说清楚。

    @ViewBuilder
    private var masterSwitchSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { store.fallbackEnabled },
                set: { store.setFallbackEnabled($0) }
            )) {
                // 一行标题，不带副标题、不带 footer。
                // 开关的语义在「智能体工具」页已经写清；这个页面是配置面，
                // 用户要的是拨一下就走，不是再读一遍解释。
                Text("云端编译兜底")
            }
            // 条件不齐时不许打开：打开了也只会让 AI 反复调一个必然失败的工具，
            // 白烧一轮对话。置灰比事后报错诚实 —— 这也是唯一的状态提示，
            // 不需要额外一行小字去解释「为什么拨不动」。
            .disabled(!store.fallbackEnabled && !store.canToggleFallback)
        }
    }

    // MARK: - 一、账号

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if !store.configured {
                // 配置缺失和用户操作错必须区分开
                configMissingRow
            } else if let dc = store.deviceCode {
                deviceCodeBlock(dc)
            } else if store.signedIn, let acct = store.account {
                signedInRow(acct)
            } else if store.polling {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.8)
                    Text("正在向 GitHub 请求验证码…").foregroundColor(.secondary)
                }
            } else {
                signInButton
            }

            if !store.loginError.isEmpty {
                Text(store.loginError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        } header: {
            Text("账号")
        } footer: {
            if store.configured && !store.signedIn && store.deviceCode == nil {
                Text("登录后，App 才能把你的代码推到自己的仓库并触发云端编译。不需要密码，GitHub 会给你一串 8 位码，在浏览器里输一次就行。")
            }
        }
    }

    private var configMissingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("还没有配置 Client ID", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundColor(.orange)
            Text("这是 App 的配置项，不是你的操作问题。要在 GitHub 上注册一个 OAuth App 并开启 Device Flow，把 Client ID 填到 `GitHubAuth.clientID`。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var signInButton: some View {
        Button {
            store.startSignIn()
        } label: {
            HStack {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                Text("登录 GitHub")
                Spacer()
                Image(systemName: "arrow.up.forward.app")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// 显示 8 位码。这是整个登录流程里唯一需要用户动手的一步。
    private func deviceCodeBlock(_ dc: GitHubDeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("在 GitHub 上输入这串码")
                .font(.subheadline.weight(.medium))

            // 码本身做大、做等宽、可长按复制
            Text(dc.userCode)
                .font(.system(size: 30, weight: .bold, design: .monospaced))
                .tracking(3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .textSelection(.enabled)

            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = dc.userCode
                } label: {
                    Label("复制码", systemImage: "doc.on.doc")
                        .font(.footnote)
                }
                .buttonStyle(.bordered)

                Button {
                    if let u = URL(string: dc.verificationURI) { openURL(u) }
                } label: {
                    Label("打开 GitHub", systemImage: "safari")
                        .font(.footnote)
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 8) {
                if store.polling {
                    ProgressView().scaleEffect(0.7)
                    Text("等你授权…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if store.secondsLeft > 0 {
                    Text("\(store.secondsLeft / 60):\(String(format: "%02d", store.secondsLeft % 60)) 后失效")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundColor(store.secondsLeft < 60 ? .red : .secondary)
                }
            }

            Button("取消", role: .cancel) {
                store.cancelSignIn()
            }
            .font(.footnote)
        }
        .padding(.vertical, 4)
    }

    private func signedInRow(_ acct: GitHubAccount) -> some View {
        HStack(spacing: 12) {
            // 头像。加载失败就退回一个占位图标 —— 不能因为拉不到图就不显示这一行
            AsyncImage(url: URL(string: acct.avatarURL ?? "")) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(acct.displayName)
                    .font(.subheadline.weight(.semibold))
                Text("@\(acct.login)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: - 二、权限

    private var scopeSection: some View {
        Section {
            scopeRow("推代码到仓库", scope: "repo", ok: store.account?.canPushCode ?? false)
            scopeRow("触发 Actions 编译", scope: "workflow", ok: store.account?.canTriggerWorkflow ?? false)

            Button {
                Task {
                    verifying = true
                    let r = await store.verifyToken()
                    verifyOK = r.ok
                    verifyMessage = r.message
                    verifying = false
                }
            } label: {
                HStack {
                    Text("测一下这个令牌")
                    Spacer()
                    if verifying { ProgressView().scaleEffect(0.7) }
                }
            }
            .disabled(verifying)

            if let ok = verifyOK, !verifyMessage.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(ok ? .green : .red)
                    Text(verifyMessage)
                        .font(.caption)
                        .foregroundColor(ok ? .secondary : .red)
                }
            }
        } header: {
            Text("权限")
        } footer: {
            if let missing = store.account?.missingScopes, !missing.isEmpty {
                Text("缺 \(missing.joined(separator: "、"))。少了这两项，推代码或触发编译会被 GitHub 拒绝。退出后重新登录，授权页会把缺的勾上。")
                    .foregroundColor(.orange)
            } else {
                Text("这两项是云端编译必须的。其它权限（删仓库、管理组织）故意没有申请。")
            }
        }
    }

    private func scopeRow(_ title: String, scope: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundColor(ok ? .green : .orange)
            Text(title)
            Spacer()
            Text(scope)
                .font(.caption)
                .monospaced()
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 三、仓库配置

    private var repoSection: some View {
        Section {
            HStack {
                Text("仓库")
                    .frame(width: 76, alignment: .leading)
                TextField("用户名/仓库名", text: $store.repoDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .monospaced()
                    .font(.callout)
            }
            HStack {
                Text("分支")
                    .frame(width: 76, alignment: .leading)
                TextField("main", text: $store.branchDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .monospaced()
                    .font(.callout)
            }
            HStack {
                Text("工作流")
                    .frame(width: 76, alignment: .leading)
                TextField("build.yml", text: $store.workflowDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .monospaced()
                    .font(.callout)
            }

            // 显式保存，不做「输入即保存」。
            //
            // 为什么不用 onChange 自动存：`saveRepoConfig()` 会把归一化后的值
            // 回写到 draft（把 `https://github.com/a/b` 截成 `a/b`），
            // 而回写又会触发 onChange —— 形成「改 → 存 → 回写 → 再存」的循环。
            // 加标志位去挡能修，但会让「用户在输入的中间态被悄悄改写」
            // 这件事更难理解。一个按钮，行为最直白。
            Button {
                store.saveRepoConfig()
            } label: {
                HStack {
                    Text("保存推送目标")
                    Spacer()
                    if store.repoDraft != store.persistedRepo
                        || store.branchDraft != store.persistedBranch
                        || store.workflowDraft != store.persistedWorkflow {
                        Text("未保存")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }
        } header: {
            Text("推送目标")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("仓库填 `用户名/仓库名` 就行，整条网址粘进来也可以（会自动截成两段）。这个仓库要提前建好，并在里面放好编译工作流。")
                Text("当前状态：\(store.cloudReadiness)")
                    .foregroundColor(store.canUseCloudBuild ? .green : .secondary)
            }
        }
    }

    // MARK: - 四、编译路由

    private var routeSection: some View {
        Section {
            HStack {
                Label("本机工具链", systemImage: "desktopcomputer")
                Spacer()
                if store.probingToolchain {
                    ProgressView().scaleEffect(0.7)
                } else if let tc = store.toolchain {
                    Text(tc.summary)
                        .font(.caption)
                        .foregroundColor(tc.canCompileNative ? .green : .orange)
                } else {
                    Text("未检测").font(.caption).foregroundColor(.secondary)
                }
            }

            if let d = store.lastDecision {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: d.isCloud ? "cloud.fill" : "desktopcomputer")
                            .font(.caption)
                            .foregroundColor(d.isCloud ? .blue : .green)
                        Text("上次走的是：\(d.route.label)")
                            .font(.caption.weight(.medium))
                    }
                    Text(d.reason)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("编译怎么走")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("**顺序**：本机能编就本机编 → 本机失败且是偶发问题就重试一次 → 还是不行才推到 GitHub。")
                Text("**不会**把源码本身有错的活推上云 —— 那只会花额度换一个一模一样的报错。")
            }
        }
    }

    // MARK: - 五、说明

    private var aboutSection: some View {
        Section {
            if store.signedIn {
                Button("退出登录", role: .destructive) {
                    showSignOutConfirm = true
                }
            }
        } header: {
            Text("关于")
        } footer: {
            Text("令牌用 AES-GCM 加密后只存在这台手机上，密钥与设备绑定 —— 换机或还原备份后需要重新登录。上传的只是你让它编译的那些文件，不会上传聊天记录或其它数据。")
        }
    }
}
