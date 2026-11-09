//
//  SettingsSheet.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  The settings screen presented from the home toolbar: its navigation
//  destinations and the top-level list linking to every settings page.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

// MARK: - Settings Sheet

private enum SettingsDestination: Hashable {
    case providers
    case providerDetail(instanceId: String)
    case modelGroups
    case modelGroupDetail(groupId: String)
    case usage
    case skills
    // [T-ios-assistant-header-open-soul]
    case soul
    // [T-tools-master-switch]
    case tools
    case memory
    case storage
    case mountedFolders
    case sharedFolders
    case logs
    // [T-minis-relay] 设备管理：中转站后台 / 路由器后台
    case relayAdmin
    case relayRouter
    case appearance
    case background
    case about
    case permissions
    case environments
    // [T-mcp-oauth-deeplink]
    case mcpIntegrations
    case mcpServerDetail(serverId: String)
}

struct SettingsSheet: View {
    @Binding var showTerminal: Bool
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var deepLink = DeepLinkCoordinator.shared
    @State private var navPath = NavigationPath()
    @State private var showFeedbackDialog = false

    var body: some View {
        NavigationStack(path: $navPath) {
            List {
                Section {
                    NavigationLink {
                        ProviderInstancesView()
                    } label: {
                        Label {
                            SettingsRowLabel(.providers, fallback: "Manage Providers")
                        } icon: {
                            if #available(iOS 26, *) {
                                Image(systemName: "key.circle.fill")
                            } else {
                                Image(systemName: "lock.circle.fill")
                            }
                        }
                    }
                    // 长按改名。defaultName 传解析后的字符串 —— 弹窗里
                    // 「原名」那行要显示「AI 服务商」而不是 key 原文。
                    .settingsRowRenameable(.providers,
                                           defaultName: AppLocalized("Manage Providers"))

                    NavigationLink {
                        ModelGroupsView()
                    } label: {
                        Label {
                            SettingsRowLabel(.modelGroups, fallback: "Model Groups")
                        } icon: {
                            Image(systemName: "gearshape.circle.fill")
                        }
                    }
                    .settingsRowRenameable(.modelGroups,
                                           defaultName: AppLocalized("Model Groups"))

                    NavigationLink {
                        UsageStatsView()
                    } label: {
                        Label {
                            SettingsRowLabel(.tokenUsage, fallback: "Token Usage")
                        } icon: {
                            Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                        }
                    }
                    .settingsRowRenameable(.tokenUsage,
                                           defaultName: AppLocalized("Token Usage"))
                } header: {
                    Text("LLM Providers")
                }

                // [T-minis-relay] 设备管理：在「外观」**上方**。
                // 这两个入口是「运维」性质，和外观（个性化）不是一类，
                // 放上面也符合「常用在上面」的习惯。
                Section {
                    NavigationLink {
                        RelayAdminView()
                    } label: {
                        Label {
                            SettingsRowLabel(.relayAdmin, fallback: "中转站后台")
                        } icon: {
                            Image(systemName: "server.rack")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.blue, in: Circle())
                        }
                    }
                    .settingsRowRenameable(.relayAdmin,
                                           defaultName: AppLocalized("中转站后台"))

                    NavigationLink {
                        RelayRouterView()
                    } label: {
                        Label {
                            SettingsRowLabel(.relayRouter, fallback: "路由器后台")
                        } icon: {
                            Image(systemName: "wifi.router.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.green, in: Circle())
                        }
                    }
                    .settingsRowRenameable(.relayRouter,
                                           defaultName: AppLocalized("路由器后台"))
                } header: {
                    Text("设备管理")
                }
                // footer 去掉了：说明文字在真机上占两行，用户明确要求
                // 这一块只留条目，不要小字。

                Section("Appearance") {
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        Label {
                            SettingsRowLabel(.appearance, fallback: "Appearance")
                        } icon: {
                            Image(systemName: "paintbrush.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.indigo, in: Circle())
                        }
                    }
                    .settingsRowRenameable(.appearance,
                                           defaultName: AppLocalized("Appearance"))
                }

                Section("Agent Runtime") {
                    // [T-tools-granular-switches] First row: per-tool switches.
                    NavigationLink {
                        ToolsSettingsView()
                    } label: {
                        Label {
                            SettingsRowLabel(.agentTools, fallback: "Agent Tools")
                        } icon: {
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.indigo, in: Circle())
                        }
                    }
                    .settingsRowRenameable(.agentTools,
                                           defaultName: AppLocalized("Agent Tools"))
                    // [T-sub-agents-v1] Directly under Agent Tools: the two pages
                    // are the tool surface (which tools exist) and the delegation
                    // surface (who runs a delegated task), so they read as a pair.
                    NavigationLink {
                        HelperSettingsView()
                    } label: {
                        Label {
                            SettingsRowLabel(.subAgents, fallback: "Sub Agents")
                        } icon: {
                            // [T-agent-icon] Same violet and glyph the agent block
                            // and tool sheet use in chat, so the settings row reads
                            // as the same feature. `glyph` is the bare figure pair
                            // meant for a caller that already draws the disc — the
                            // wider person.2.wave.2 reached the edge of the 21pt
                            // circle at this section's icon size.
                            Image(systemName: HelperAccent.glyph)
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(HelperAccent.color, in: Circle())
                        }
                    }
                    .settingsRowRenameable(.subAgents,
                                           defaultName: AppLocalized("Sub Agents"))
                    NavigationLink {
                        SkillsManagementView()
                    } label: {
                        Label {
                            SettingsRowLabel(.skills, fallback: "Skills")
                        } icon: {
                            Image(systemName: "puzzlepiece.extension")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.blue, in: Circle())
                        }
                    }
                    .settingsRowRenameable(.skills,
                                           defaultName: AppLocalized("Skills"))
                    NavigationLink {
                        SoulSettingsView()
                    } label: {
                        Label {
                            SettingsRowLabel(.soul, fallback: "Soul")
                        } icon: {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.pink, in: Circle())
                        }
                    }
                    .settingsRowRenameable(.soul,
                                           defaultName: AppLocalized("Soul"))
                    NavigationLink {
                        MemoryManagementView()
                    } label: {
                        Label {
                            SettingsRowLabel(.memory, fallback: "Memory")
                        } icon: {
                            Image(systemName: "brain.head.profile")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.purple, in: Circle())
                        }
                    }
                    .settingsRowRenameable(.memory,
                                           defaultName: AppLocalized("Memory"))
                    NavigationLink {
                        MCPIntegrationsView()
                    } label: {
                        Label {
                            SettingsRowLabel(.mcpIntegrations, fallback: "MCP Integrations")
                        } icon: {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.teal, in: Circle())
                        }
                    }
                    .settingsRowRenameable(.mcpIntegrations,
                                           defaultName: AppLocalized("MCP Integrations"))
                    NavigationLink {
                        EnvironmentVariablesView()
                    } label: {
                        Label {
                            SettingsRowLabel(.environmentVars, fallback: "Environment Variables")
                        } icon: {
                            Image(systemName: "terminal")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.green, in: Circle())
                        }
                    }
                    .settingsRowRenameable(.environmentVars,
                                           defaultName: AppLocalized("Environment Variables"))
                }

                Section("Storage") {
                    NavigationLink {
                        StorageManagementView()
                    } label: {
                        Label {
                            SettingsRowLabel(.storage, fallback: "Storage")
                        } icon: {
                            Image(systemName: "archivebox")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.blue, in: Circle())
                        }
                    }
                    .settingsRowRenameable(.storage,
                                           defaultName: AppLocalized("Storage"))
                    NavigationLink {
                        SharedFoldersSettingsView()
                    } label: {
                        Label {
                            SettingsRowLabel(.sharedFolders, fallback: "Shared Folders")
                        } icon: {
                            Image(systemName: "folder.fill.badge.person.crop")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.green, in: Circle())
                        }
                    }
                    .settingsRowRenameable(.sharedFolders,
                                           defaultName: AppLocalized("Shared Folders"))
                    NavigationLink {
                        MountedFoldersSettingsView()
                    } label: {
                        Label {
                            SettingsRowLabel(.mountedFolders, fallback: "Mount External Folders")
                        } icon: {
                            Image(systemName: "externaldrive.badge.plus")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.orange, in: Circle())
                        }
                    }
                    .settingsRowRenameable(.mountedFolders,
                                           defaultName: AppLocalized("Mount External Folders"))
                    if #available(iOS 17.0, *) {
                        NavigationLink {
                            // v2 is the default sync engine; legacy v1
                            // settings page is unreachable from here.
                            CloudSyncSettingsV2View()
                        } label: {
                            Label {
                                SettingsRowLabel(.iCloudSync, fallback: "iCloud Sync")
                            } icon: {
                                Image(systemName: "icloud")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white)
                                    .frame(width: 21, height: 21)
                                    .background(.cyan, in: Circle())
                            }
                        }
                        .settingsRowRenameable(.iCloudSync,
                                               defaultName: AppLocalized("iCloud Sync"))
                    }
                    NavigationLink {
                        BackupAndRestoreView()
                    } label: {
                        Label {
                            // Not just "Backup": this screen is both halves of
                            // the feature, and on a new device restore is the
                            // only one the user is looking for.
                            SettingsRowLabel(.backupRestore, fallback: "Backup & Restore")
                        } icon: {
                            // arrow.triangle.2.circlepath reads as a round trip
                            // rather than a one-way export.
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.indigo, in: Circle())
                        }
                    }
                    .settingsRowRenameable(.backupRestore,
                                           defaultName: AppLocalized("Backup & Restore"))

                    // [T-minis-gh-fallback] GitHub 账号 + 云端编译兜底。
                    //
                    // 放在「存储」分组的最下面 —— 它确实和存储是同一类事
                    // （把东西放到本机之外），但又不是用户天天点的，
                    // 所以排在本机存储相关项之后。
                    NavigationLink {
                        GitHubAccountView()
                    } label: {
                        Label {
                            SettingsRowLabel(.githubAccount, fallback: "GitHub 账号")
                        } icon: {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.black, in: Circle())
                        }
                    }
                    .settingsRowRenameable(.githubAccount,
                                           defaultName: AppLocalized("GitHub 账号"))
                }

                Section("Permissions") {
                    NavigationLink {
                        OffloadPermissionSettingsView()
                    } label: {
                        Label {
                            SettingsRowLabel(.permissions, fallback: "Permissions")
                        } icon: {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.red, in: Circle())
                        }
                    }
                    .settingsRowRenameable(.permissions,
                                           defaultName: AppLocalized("Permissions"))
                    if BiometricAuth.isAvailable {
                        NavigationLink {
                            FaceIDProtectionSettingsView()
                        } label: {
                            Label {
                                SettingsRowLabel(.faceID,
                                                 fallback: "\(BiometricAuth.biometryDisplayName) Protection")
                            } icon: {
                                // Match SF Symbol to the device's actual sensor — Touch ID
                                // devices showed a Face ID glyph here before.
                                Image(systemName: BiometricAuth.biometryIconName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white)
                                    .frame(width: 21, height: 21)
                                    .background(.teal, in: Circle())
                            }
                        }
                        .settingsRowRenameable(
                            .faceID,
                            defaultName: "\(BiometricAuth.biometryDisplayName) \(AppLocalized("Protection"))")
                    }
                }

                Section("Logs") {
                    NavigationLink {
                        LogManagementView()
                    } label: {
                        Label {
                            SettingsRowLabel(.logs, fallback: "Logs")
                        } icon: {
                            Image(systemName: "doc.text")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.gray, in: Circle())
                        }
                    }
                    .settingsRowRenameable(.logs,
                                           defaultName: AppLocalized("Logs"))
                }

                SelfUpdateSection()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: SettingsDestination.self) { dest in
                switch dest {
                case .providers:
                    ProviderInstancesView()
                case .providerDetail(let id):
                    ProviderInstanceDetailView(instanceId: id)
                case .modelGroups:
                    ModelGroupsView()
                case .modelGroupDetail(let id):
                    ModelGroupDetailView(groupId: id)
                case .usage:
                    UsageStatsView()
                case .skills:
                    SkillsManagementView()
                case .soul:
                    SoulSettingsView()
                case .tools:
                    ToolsSettingsView()
                case .memory:
                    MemoryManagementView()
                case .storage:
                    StorageManagementView()
                case .mountedFolders:
                    MountedFoldersSettingsView()
                case .sharedFolders:
                    SharedFoldersSettingsView()
                case .logs:
                    // Pull a one-shot tab hint from the deep link router
                    // (e.g. `?tab=config-audit`). LogManagementView clears
                    // its local state independently; the published value
                    // here is consumed once and reset to nil.
                    LogManagementView(initialTab: deepLink.pendingLogsTab ?? "logs")
                        .onAppear { deepLink.pendingLogsTab = nil }
                case .relayAdmin:
                    RelayAdminView()
                case .relayRouter:
                    RelayRouterView()
                case .appearance:
                    AppearanceSettingsView()
                case .background:
                    EnhancedBackgroundSettingsView()
                case .about:
                    AboutView()
                case .environments:
                    EnvironmentVariablesView()
                case .permissions:
                    OffloadPermissionSettingsView()
                // [T-mcp-oauth-deeplink] Detail = the list view told to open
                // the server's edit sheet on appear; a deleted/unknown server
                // just lands on the list (no crash, sensible fallback).
                case .mcpIntegrations:
                    MCPIntegrationsView()
                case .mcpServerDetail(let serverId):
                    MCPIntegrationsView(initialEditServerId: serverId)
                }
            }
            .onAppear {
                applyPendingDeepLink()
                // Legacy flags — kept so older call sites keep working.
                if deepLink.showEnvironmentVariables {
                    navPath.append(SettingsDestination.environments)
                    deepLink.showEnvironmentVariables = false
                }
                if deepLink.showPermissions {
                    navPath.append(SettingsDestination.permissions)
                    deepLink.showPermissions = false
                }
                // Restore the user's location after a language-change rebuild.
                // AppearanceSettingsView's language picker writes this flag
                // right before flipping `appLanguage`, knowing the root
                // `.id(appLanguage)` will tear the whole tree down. ContentView
                // re-opens the sheet on re-mount; here we push back to the
                // destination so the user lands where they were, now rendered
                // in the new language.
                if let dest = UserDefaults.standard.string(forKey: "pendingSettingsReopen") {
                    UserDefaults.standard.removeObject(forKey: "pendingSettingsReopen")
                    switch dest {
                    case "appearance":
                        navPath.append(SettingsDestination.appearance)
                    default:
                        break
                    }
                }
            }
            .onChange(of: deepLink.pendingSettingsTarget) { _ in
                applyPendingDeepLink()
            }
        }
        .preferredColorScheme(appearanceMode == 1 ? .light : appearanceMode == 2 ? .dark : nil)
        .appFontScale()
    }

    /// Translate `DeepLinkCoordinator.pendingSettingsTarget` into a
    /// NavigationStack push and clear the pending value. Called from
    /// `onAppear` (cold-start deep link) and `onChange` (deep link
    /// arriving while the sheet is already open).
    ///
    /// `.environments` keeps its existing prefill semantics — the
    /// environments view consumes `pendingEnvVarCreate` separately on
    /// appear, so we only have to navigate here.
    private func applyPendingDeepLink() {
        guard let target = deepLink.pendingSettingsTarget else { return }
        // Reset path so deep links are predictable: a deep link always
        // lands on the requested destination as the only stack entry,
        // not on top of whatever the user was browsing earlier.
        navPath = NavigationPath()
        switch target {
        case .home:
            break // already at Settings root
        case .providers:
            navPath.append(SettingsDestination.providers)
        case .providerDetail(let id):
            navPath.append(SettingsDestination.providers)
            navPath.append(SettingsDestination.providerDetail(instanceId: id))
        case .modelGroups:
            navPath.append(SettingsDestination.modelGroups)
        case .modelGroupDetail(let id):
            navPath.append(SettingsDestination.modelGroups)
            navPath.append(SettingsDestination.modelGroupDetail(groupId: id))
        case .usage:
            navPath.append(SettingsDestination.usage)
        case .skills:
            navPath.append(SettingsDestination.skills)
        case .soul:
            navPath.append(SettingsDestination.soul)
        case .tools:
            navPath.append(SettingsDestination.tools)
        case .memory:
            navPath.append(SettingsDestination.memory)
        case .storage:
            navPath.append(SettingsDestination.storage)
        case .mountedFolders:
            navPath.append(SettingsDestination.mountedFolders)
        case .sharedFolders:
            navPath.append(SettingsDestination.sharedFolders)
        case .logs:
            navPath.append(SettingsDestination.logs)
        case .appearance:
            navPath.append(SettingsDestination.appearance)
        case .background:
            navPath.append(SettingsDestination.background)
        case .about:
            navPath.append(SettingsDestination.about)
        case .permissions:
            navPath.append(SettingsDestination.permissions)
        case .environments:
            navPath.append(SettingsDestination.environments)
        case .mcpIntegrations:
            navPath.append(SettingsDestination.mcpIntegrations)
        case .mcpServerDetail(let id):
            navPath.append(SettingsDestination.mcpServerDetail(serverId: id))
        }
        deepLink.pendingSettingsTarget = nil
    }

    /// Compose the feedback mailto URL with a prefilled body that includes
    /// app version, iOS version, and a machine identifier, plus a prompt
    /// asking the user to attach a screenshot manually (mailto:// can't
    /// auto-attach). Using URLComponents so the subject and body go through
    /// proper URL encoding without hand-rolling addingPercentEncoding calls.
    fileprivate static func makeFeedbackEmailURL() -> URL? {
        let bundle = Bundle.main
        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let iosVersion = UIDevice.current.systemVersion
        let device = machineIdentifier()

        let body = """
        Please describe your feedback:


        ---
        App Version: \(appVersion) (\(build))
        iOS Version: \(iosVersion)
        Device: \(device)

        Screenshot (optional): Please attach a screenshot if relevant.
        """

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "dev@openminis.app"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Minis Feedback"),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }

    /// Build the GitHub Issue URL with a bilingual bug-report template
    /// pre-filled with platform / OS / app / device info. SwiftUI `Link`
    /// hands the URL to UIApplication.shared.open, which routes to Safari.
    fileprivate static func makeBugReportURL() -> URL? {
        let bundle = Bundle.main
        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let iosVersion = UIDevice.current.systemVersion
        let device = machineIdentifier()

        let body = """
        ## 📝 Problem Summary

        <!-- Briefly describe the issue you encountered -->


        ## 📱 Basic Information

        | Field | Value |
        |-------|-------|
        | Platform | iOS |
        | OS Version | iOS \(iosVersion) |
        | Minis Version | \(appVersion) (build \(build)) |
        | Device Model | \(device) |

        ## 🔁 Steps to Reproduce

        1.
        2.
        3.

        ## ❌ Error Details

        ```
        paste error here
        ```

        ## ✅ Expected Behavior



        ## 🗂️ Additional Information

        """

        // 提 issue 的目标是**我们自己的**仓库，不是原版。
        //
        // 原来这里硬写 github.com/OpenMinis/OpenMinis/issues/new，
        // 那是原版项目的 issue 页。发过去既没人管，也会让用户以为
        // 问题出在原版身上 —— 我们是独立版本线，报告该落在自己的
        // 更新源仓库。没配更新源时返回 nil，调用点会自动隐藏入口。
        guard SelfUpdate.isConfigured else { return nil }
        var components = URLComponents(string: "https://github.com/\(SelfUpdate.repo)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: "[Bug] "),
            URLQueryItem(name: "body", value: body),
        ]
        return components?.url
    }

    /// Returns the hardware model identifier, e.g. "iPhone16,2".
    /// `UIDevice.current.model` returns the generic "iPhone" / "iPad" and
    /// isn't useful in a bug report, so we fall back to utsname.
    private static func machineIdentifier() -> String {
        var sys = utsname()
        uname(&sys)
        let id = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        return id.isEmpty ? UIDevice.current.model : id
    }
}

#Preview {
    ContentView()
}
