import Foundation
import UIKit

private let logger = AppLogger(category: "AIChatVM")

// MARK: - Kernel Boot + Prompt Queue + Minis paths + Dynamic Max Tokens

extension AIChatViewModel {

    // MARK: - Kernel Boot

    func ensureKernelBooted() {
        guard kernelStatus == .notBooted else { return }
        kernelStatus = .booting

        Task {
            let bootStart = CFAbsoluteTimeGetCurrent()
            do {
                if !ISHKernel.shared.isBooted {
                    let installStart = CFAbsoluteTimeGetCurrent()
                    try RootfsManager.shared.installIfNeeded()
                    let installElapsed = (CFAbsoluteTimeGetCurrent() - installStart) * 1000
                    logger.info("[KernelBoot] installIfNeeded: \(String(format: "%.1f", installElapsed))ms")

                    // [T-fakefs-rebuild-storm] boot 之前先无条件修一次 meta.db。
                    //
                    // 为什么不能只靠「解压后校准」那一步：`installIfNeeded()`
                    // 在老用户已安装、版本戳又对得上时会**直接 return**，
                    // 一个字节都不碰 meta.db。而 1.77 恰恰会把 meta.db 弄成
                    // 「db_inode=0 + 可能缺 orphans」的状态 —— 这种用户升级到
                    // 本版时不会重装 rootfs，解压路径根本不会跑。
                    //
                    // 更要紧的是：一旦 meta.db 真的让内核在 fakefs_rebuild 里
                    // 撞上 die()，boot 就**永远不返回**（die_handler 把线程睡死），
                    // 下面的 -5 判断根本没机会执行。所以修复必须发生在
                    // boot **之前**，不能指望 boot 失败后补救。
                    //
                    // 成本很低：打开一个 SQLite 连接、查几张表、写一个整数。
                    // 表都齐的时候 changed=false，走完就退。
                    let preRepair = RootfsManager.shared.repairMetaDBIfNeeded()
                    logger.info("[KernelBoot] pre-boot meta.db check (changed=\(preRepair))")

                    let kernelStart = CFAbsoluteTimeGetCurrent()
                    let rootPath = RootfsManager.shared.rootfsPath.path
                    var err = ISHKernel.shared.boot(withRootPath: rootPath)
                    let kernelElapsed = (CFAbsoluteTimeGetCurrent() - kernelStart) * 1000
                    logger.info("[KernelBoot] kernel boot call: \(String(format: "%.1f", kernelElapsed))ms")

                    // [T-fakefs-rebuild-storm] -5 = -EIO。它在 fakefs_mount 里
                    // 有**三条**来源，前两轮只按其中一条修，所以一直打偏：
                    //
                    //   1. `realfs_mount()` —— host 的 data/ 目录打不开
                    //      （realpath / open(O_DIRECTORY) 失败，errno=EIO）
                    //   2. `fake_db_init()` 的 init_fail —— meta.db 层面的
                    //      SQLite 错误（pragma / 迁移 / prepare / db_inode 更新）
                    //   3. `mount_root` 里 realpath(source) 失败
                    //
                    // `errno_map()` 含 ERRCASE(EIO)，所以 host 的 EIO 会原样
                    // 变成 -5，三条最终长得一模一样。
                    //
                    // 同一段代码还有一条**不会**返回 -5 的失败路径，别搞混：
                    // fakefs_rebuild 里 create table paths_old / stats_old 走
                    // EXEC 宏，失败时调 die()；iOS 上 die_handler 被换成
                    // embedded_die_handler，只把 iSH 线程永久挂起、不崩进程。
                    // 那种情况表现为界面永远卡在「正在启用内核」，连错误码都看不到。
                    //
                    // 下面 boot 前那次 repairMetaDBIfNeeded() 已经把 1.78 漏掉的
                    // user_version 也一起修正了（构造内核迁移终态），所以这里
                    // 返回 -5 基本只剩「库/目录真坏了」或「磁盘满」两种可能。
                    if err == -5 {
                        logger.warning("[KernelBoot] boot 返回 -5（EIO）— 先修库再重试一次")
                        // isBooted 只有在 boot 全程成功末尾才置 YES；-5 来自
                        // mount_root → fake_db_init，位置在 become_first_process
                        // 之前，所以内核还是「没启动」的干净状态，可以重来。
                        // 但仍然显式确认一次：become_first_process 不可逆，
                        // 误判会让重试直接把 App 打崩。
                        guard !ISHKernel.shared.isBooted else {
                            logger.error("[KernelBoot] 内核已标记 booted，不再重试（避免二次 become_first_process）")
                            kernelStatus = .failed("Kernel boot failed: \(err)")
                            return
                        }
                        let repaired = RootfsManager.shared.repairMetaDBIfNeeded()
                        logger.info("[KernelBoot] repairMetaDB changed=\(repaired)")
                        if repaired {
                            let retryStart = CFAbsoluteTimeGetCurrent()
                            err = ISHKernel.shared.boot(withRootPath: rootPath)
                            let retryElapsed = (CFAbsoluteTimeGetCurrent() - retryStart) * 1000
                            logger.info("[KernelBoot] retry boot after repair: err=\(err) \(String(format: "%.1f", retryElapsed))ms")
                        }
                    }

                    if err < 0 {
                        // -5 时把「凭什么 -5」查清楚并显示出来。两轮修复都
                        // 因为看不到具体来源而打偏，这次让 App 自己说。
                        if err == -5 {
                            let diag = RootfsManager.shared.diagnoseKernelMountFailure()
                            kernelStatus = .failed("Kernel boot failed: \(err)\n\(diag)")
                        } else {
                            kernelStatus = .failed("Kernel boot failed: \(err)")
                        }
                        return
                    }
                    // Wire fakefs change events into the iCloud Sync v2
                    // SessionFile dirty pipeline. Must be done after boot
                    // (the C-side dispatch source is created by this call)
                    // and before any bind mount, so the first realfs op
                    // already has a consumer registered.
                    installSessionFileChangeTracker(kernel: ISHKernel.shared)

                    // Install per-session path-translate hook. Must run
                    // before any session task is spawned so the first
                    // /var/ai/* access already routes correctly.
                    MinisFsRouter.shared.installHook()
                }
                RootfsManager.shared.applyDefaultMountOverlay()
                Task { @MainActor in MirrorSpeedTestViewModel.shared.autoDetectOnceIfNeeded() }
                kernelStatus = .booted
                let totalElapsed = (CFAbsoluteTimeGetCurrent() - bootStart) * 1000
                logger.info("[KernelBoot] TOTAL: \(String(format: "%.1f", totalElapsed))ms")
            } catch {
                kernelStatus = .failed(error.localizedDescription)
                logger.error("[KernelBoot] error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Kernel failure self-service  [T-kernel-fail-selfservice]

    /// 失败界面「修复并重试」按钮的动作。
    ///
    /// 只做**库层面**的修复（不删 rootfs、不碰用户数据）：把 meta.db 拉回
    /// 内核迁移终态，然后重新 boot 一次。适用于「目录结构完好、只是库不一致」。
    ///
    /// 之所以敢在同一个进程里重试：`-5` 来自 `mount_root → fake_db_init`，
    /// 位置在 `become_first_process()` **之前** —— 内核还没成为 PID 1，
    /// 进程状态是干净的。而 `become_first_process` 之后就不可能再重来了，
    /// 那种情况 `bootWithRootPath` 会因为 `_isBooted` 直接返回 0，不会误进这里。
    func repairAndRetryKernelBoot() {
        guard !kernelRepairing else { return }
        kernelRepairing = true

        // Task 在这个 @MainActor 类里会继承主 actor 隔离，所以下面直接写
        // self.xxx 即可，不需要 MainActor.run。与 ensureKernelBooted() 一致。
        Task { [weak self] in
            guard let self else { return }
            let changed = RootfsManager.shared.repairMetaDBIfNeeded()
            logger.warning("[KernelRepair] manual repair done (changed=\(changed))")

            // 修完必须回到 notBooted 才能让 ensureKernelBooted 继续往下走。
            // 注意 reset 的是**状态机**，不是 rootfs。
            self.kernelRepairing = false
            // 顺手把「已读提示」清掉：这一轮是全新的尝试，如果又走到
            // .needsRelaunch，提示必须重新出现，不能被上次的已读状态吞掉。
            self.needsRelaunchAcknowledged = false
            self.kernelStatus = .notBooted
            self.ensureKernelBooted()
        }
    }

    /// 失败界面「重置内核环境」按钮的动作。
    ///
    /// [T-reset-keeps-userdata] 走 `reinstallKeepingUserData()`，
    /// **不是** `reset(keepUserData: true)`。
    ///
    /// 区别是实质性的，不是写法偏好：
    ///   · `reset(keepUserData:)` 只备份 `data/root`，备份完就撒手
    ///     （返回的 backupURL 要调用方自己接），而且**完全不管 `var/ai`**
    ///   · `var/ai` 底下是 workspace / attachments / skills / offloads，
    ///     是用户最要紧的一份数据
    ///
    /// 内核挂不上时，用户点这个按钮是为了**救回来**。如果它在过程中
    /// 悄悄丢了 `var/ai`，那比不修更糟 —— 之前界面上写着
    /// 「你的 ~ 和 /var/ai 里的文件会保留」，而旧实现保不住 `var/ai`，
    /// 那是假承诺。
    ///
    /// `reinstallKeepingUserData()` 做的是一整套：备份三项 → 删旧树 →
    /// 解压新 rootfs → 拷回 → 逐项登记进 meta.db。装完 rootfs 就是
    /// 「已安装」状态，用户下次启动直接 boot，不用再等一次解压。
    ///
    /// 但**本进程内仍然无法重新 boot**：`become_first_process` 不可逆，
    /// 而且 `-5` 之后内核对象的状态也不保证干净。所以这里不装作已经好了，
    /// 明确要求用户冷启动。
    func resetKernelEnvironment() {
        guard !kernelRepairing else { return }
        kernelRepairing = true
        // 又要走一轮，先把「已读提示」清掉 —— 否则这轮如果又成
        // .needsRelaunch，用户会看不到任何提示（被上次的已读吞掉）。
        needsRelaunchAcknowledged = false

        Task { [weak self] in
            guard let self else { return }
            var failure: String?
            do {
                // 走完整的那条路：备份 + 重装 + 恢复 + 登记。
                try RootfsManager.shared.reinstallKeepingUserData()
            } catch {
                failure = error.localizedDescription
                logger.error("[KernelRepair] reinstall failed: \(error.localizedDescription)")
            }

            self.kernelRepairing = false
            if let failure {
                // 重装失败时用户数据仍在（reinstallKeepingUserData 内部
                // 在装新的失败时会先 restoreBackup 再抛），所以这里
                // 只说「没修成」，不要说成「数据没了」。
                // 用 `.failed`（不是 needsRelaunch）：这次是真没弄好，
                // 界面该保留那两个按钮让用户再试。
                self.kernelStatus = .failed(
                    "重置没成功：\(failure)\n"
                    + "你的文件没有丢。可以再点一次，或到设置里反馈这行信息。")
            } else {
                // [T-needs-relaunch-state] 成功了，用 `.needsRelaunch`
                // 而不是 `.failed`。
                //
                // 数据层面已经全好了：rootfs 重建完、用户数据搬回并登记进
                // meta.db。唯一的限制是 become_first_process 不可逆 ——
                // 本进程内没法重新 mount，所以必须冷启动。
                //
                // 塞进 `.failed` 的后果是界面给用户看红色感叹号 + 红字 +
                // 两个「修复/重置」按钮，用户以为又失败了，很可能再点一次
                // 重置，白等 30 秒重新解压。这两种情况必须分开表达。
                self.kernelStatus = .needsRelaunch(
                    "内核环境已重建，用户数据已保留。\n"
                    + "请完全关闭并重新打开 App —— 下次启动会直接启用内核，不用再等解压。")
            }
        }
    }

    /// [T-needs-relaunch-state] 收起 `.needsRelaunch` 的全屏提示。
    ///
    /// 只置一个标志，**不动 kernelStatus**：
    ///   · 改成 `.notBooted` 会让 `ensureKernelBooted()` 又去 boot 一次，
    ///     而 `become_first_process` 不可逆，必然再失败、再把用户扔回红页
    ///   · 保持 `.needsRelaunch` 才能让 `Send` / `Rerun` 里的拦截继续生效
    ///     （`blocksKernelUse` 为 true），不会带着没起来的内核发消息
    ///
    /// 换句话说：提示可以收，限制不能松。
    func dismissNeedsRelaunchOverlay() {
        needsRelaunchAcknowledged = true
        logger.info("[KernelRepair] needsRelaunch 提示已收起（内核仍不可用，需冷启动）")
    }

    // MARK: - Prompt Queue

    /// Queue the current input text as a prompt to be injected into the running agent loop.
    /// The message immediately appears in the chat with a dashed border (isQueued=true).
    /// - Parameter silent: [T-p0-programmatic-prompt] skip the tap haptic; set
    ///   by `submitProgrammaticPrompt` for CLI / Shortcut / job origins.
    /// - Parameter overrideText: [T-programmatic-prompt-no-composer] the prompt
    ///   to queue, for callers that are not the composer. nil (the user's own
    ///   tap) means "take the draft", which is also the only case that clears
    ///   it. A programmatic caller passes its text here so the user's in-flight
    ///   draft is never read, written, or cleared.
    func enqueuePrompt(silent: Bool = false, deferUntilIdle: Bool = false,
                       overrideText: String? = nil) {
        let usingComposer = overrideText == nil
        let text = (overrideText ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, isProcessing else { return }
        if !silent {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        // [T-user-ask] §11.4: the user typing a new message while a question
        // waits cancels that question (dismissed, superseded_by_user_message)
        // and the message becomes the next turn. Job / programmatic prompts
        // (silent or deferred) are not the user answering and leave it alone.
        if !silent && !deferUntilIdle {
            supersedePendingUserAsk()
        }
        let pendingAttachments = attachments
        // [T-paste-live-bubble-card] Same birth-time card plan as send(): the
        // queued bubble keeps the [Pasted#N] literal in its text and is born
        // with the chip-style cards; the drain writes the files to the
        // planned ids.
        let pastePlanned = planPastedCards(for: text)
        var prompt = QueuedPrompt(text: text, attachments: pendingAttachments,
                                  pastePlan: pastePlanned.plan)
        prompt.deferUntilIdle = deferUntilIdle
        promptQueue.append(prompt)
        // Show in chat immediately with queued styling
        let chatMsg = ChatMessage(role: .user, content: text, isQueued: true)
        chatMsg.queuedPromptId = prompt.id
        chatMsg.inputAttachments = pendingAttachments
        chatMsg.attachments = pastePlanned.metas
        messages.append(chatMsg)
        scrollToBottomSignal.send()
        // Only the composer's own send empties the composer. A programmatic
        // prompt carried its text in `overrideText` and must leave the user's
        // draft exactly as they left it.
        if usingComposer { inputText = "" }
        attachments = []
        logger.info("Enqueued prompt (\(text.count)ch, \(pendingAttachments.count) attachments), queue size=\(self.promptQueue.count)")
        // [T-ios-queued-candidate-not-onscreen] Log the queued candidate text
        // (prefix 100) + a queue/messages snapshot so we can later correlate a
        // queued send against whether it ever rendered.
        logger.info("📋[QueueDiag] ENQUEUE candidate id=\(prompt.id.uuidString.prefix(8)) text(prefix100)=\"\(text.prefix(100))\"")
        dumpQueueSnapshot("after-enqueue")
    }

    /// Remove a queued prompt by ID and its corresponding chat message.
    func removeQueuedPrompt(id: UUID) {
        promptQueue.removeAll { $0.id == id }
        messages.removeAll { $0.queuedPromptId == id }
    }

    /// Withdraw a queued message from the chat before it gets injected into the agent loop.
    func withdrawQueuedMessage(_ messageId: UUID) {
        guard let msg = messages.first(where: { $0.id == messageId }), msg.isQueued,
              let promptId = msg.queuedPromptId else { return }
        promptQueue.removeAll { $0.id == promptId }
        messages.removeAll { $0.id == messageId }
        logger.info("Withdrew queued message, queue size=\(self.promptQueue.count)")
    }

    // MARK: - /var/ai/ Shared Directory
    //
    // Unified bidirectional file area between iOS and iSH:
    //   /var/ai/attachments/  — screenshots, images, media
    //   /var/ai/offloads/     — large tool outputs (migrated from /var/offloads/)
    //   /var/ai/workspace/    — general session working area
    //
    // Persistent storage: Library/MinisChat/minis/<sessionId>/{attachments,offloads,workspace}/
    // iSH-visible path:   /var/ai/{attachments,offloads,workspace}/  (session-unaware)
    //
    // On session load/switch, the current session's files are synced into the
    // iSH-visible directory so the model and shell commands always see /var/ai/.

    nonisolated static let minisLinuxBaseDir = "/var/ai"
    nonisolated static let minisAttachmentsLinuxDir = "/var/ai/attachments"
    nonisolated static let minisOffloadsLinuxDir = "/var/ai/offloads"
    nonisolated static let minisWorkspaceLinuxDir = "/var/ai/workspace"
    nonisolated static let minisBrowserLinuxDir = "/var/ai/browser"
    nonisolated static let minisMemoryLinuxDir = "/var/ai/memory"
    nonisolated static let minisSkillsLinuxDir = "/var/ai/skills"
    nonisolated static let minisSharedLinuxDir = "/var/ai/shared"
    nonisolated static let minisMcpServersLinuxDir = "/var/ai/mcp-servers"
    nonisolated static let minisMountsLinuxDir = "/var/ai/mounts"

    /// iOS persistent base for all minis data (Library/MinisChat/minis/).
    nonisolated static var minisPersistentBase: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return lib.appendingPathComponent("MinisChat/minis", isDirectory: true)
    }

    /// Persistent storage directory for a specific session's offloads.
    nonisolated static func minisOffloadsPersistentDir(for sid: String) -> URL {
        minisPersistentBase.appendingPathComponent(sid, isDirectory: true)
            .appendingPathComponent("offloads", isDirectory: true)
    }

    /// Persistent storage directory for a specific session's attachments.
    nonisolated static func minisAttachmentsPersistentDir(for sid: String) -> URL {
        minisPersistentBase.appendingPathComponent(sid, isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
    }

    /// Persistent storage directory for a specific session's uploaded attachments.
    static func minisUploadsDir(for sid: String) -> URL {
        minisAttachmentsPersistentDir(for: sid)
            .appendingPathComponent("uploads", isDirectory: true)
    }

    /// Downsample a freshly-captured `UIImage` (e.g. from the built-in camera)
    /// and encode it as JPEG. Unlike `resizedImageData(_:maxLongEdge:)` this
    /// ALWAYS re-encodes — the camera hands us a full-resolution UIImage
    /// (~12MP on recent iPhones), and saving it via `pngData()` /
    /// `jpegData(compressionQuality: 1.0)` produced 15–25 MB files
    /// (GH#33 / #565). Capping the long edge and using a normal JPEG quality
    /// brings a single photo down to ~1–3 MB while keeping it legible, matching
    /// what photo-library / screenshot attachments already weigh. If the image
    /// is already at/under `maxLongEdge` we skip the resize but still JPEG-encode.
    /// Returns nil only if the image has no backing `cgImage`.
    static func downsampledCameraJPEG(_ image: UIImage,
                                      maxLongEdge: CGFloat = 2560,
                                      quality: CGFloat = 0.82) -> Data? {
        guard image.cgImage != nil else {
            // No pixel buffer to measure — fall back to a plain JPEG encode so
            // we never silently drop the capture.
            return image.jpegData(compressionQuality: quality)
        }
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        let longest = max(pixelW, pixelH)
        guard longest > maxLongEdge else {
            // Already small enough — just compress, don't upscale.
            return image.jpegData(compressionQuality: quality)
        }
        let scale = maxLongEdge / longest
        let newSize = CGSize(width: (pixelW * scale).rounded(), height: (pixelH * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: quality)
    }

    /// Resize image so its longest edge is at most `maxLongEdge` pixels.
    /// Returns nil if the image is already within bounds.
    static func resizedImageData(_ data: Data, maxLongEdge: CGFloat = 2000) -> Data? {
        guard let image = UIImage(data: data), image.cgImage != nil else { return nil }
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        let longest = max(pixelW, pixelH)
        guard longest > maxLongEdge else { return nil }
        let scale = maxLongEdge / longest
        let newSize = CGSize(width: pixelW * scale, height: pixelH * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: 0.85)
    }

    /// Encode an image into a JPEG that fits under `targetMaxBytes`, falling
    /// back through progressively smaller max-edges and lower JPEG qualities.
    /// Returns the smallest acceptable encoding plus the mime type ("image/jpeg").
    /// When the input is already under target, returns the input data verbatim.
    /// When even the most aggressive pass still exceeds target, returns the
    /// best (smallest) encoding we managed — caller decides whether to drop
    /// the image or send it anyway. T-imgsize-13b7d81c.
    static func compressedImageDataUnderBudget(
        _ data: Data,
        targetMaxBytes: Int
    ) -> (data: Data, didCompress: Bool) {
        guard data.count > targetMaxBytes else { return (data, false) }
        // Re-encode passes ordered most-permissive → most-aggressive. Each
        // pass starts from the ORIGINAL bytes so we never compound JPEG
        // artifacts by re-encoding an already-encoded encoding.
        let passes: [(maxEdge: CGFloat, quality: CGFloat)] = [
            (2000, 0.80),
            (1600, 0.75),
            (1280, 0.70),
            (1024, 0.65),
            (800,  0.55),
            (640,  0.45),
        ]
        var best: Data = data
        for (edge, q) in passes {
            guard let encoded = jpegEncode(data, maxLongEdge: edge, quality: q) else { continue }
            if encoded.count < best.count { best = encoded }
            if encoded.count <= targetMaxBytes { return (encoded, true) }
        }
        return (best, true)
    }

    // MARK: - Dynamic Max Tokens

    /// Effective context window for the given model, respecting the bound
    /// group's context-limit override. The slider's "Unlimited" stop stores
    /// `Int.max` as a sentinel meaning "no override — use whatever the model
    /// declares natively". This keeps the slider visible (toggle stays ON,
    /// slider at the rightmost stop) without leaking Int.max as a real ceiling.
    ///
    /// The group limit is read LIVE from the store on every call — it used to
    /// be mirrored into an in-memory `activeContextLimitTokens` that was only
    /// refreshed on model/group re-bind, so editing the group's limit (or the
    /// model's context window) with a session open kept judging capacity by
    /// the stale mirror until the user re-picked the model. One live lookup
    /// (binding + group) per capacity check is cheap and always current.
    func effectiveContextWindow(for model: LLMModel) -> Int {
        resolvedContextWindow(for: model).window
    }

    /// The window plus whether it came from a user-chosen group cap, which
    /// `ContextPolicy` needs in order to pick proportional thresholds
    /// ([T-ctx-user-cap]).
    ///
    /// The cap is applied as `min(modelWindow, groupLimit)`, matching Android's
    /// `effectiveContextWindowTokens()`. A cap set ABOVE the model's native
    /// window is not a licence to overflow the model — it just means "no
    /// practical limit", so it must not raise the ceiling. `isUserCap` is
    /// therefore true only when the cap actually binds.
    func resolvedContextWindow(for model: LLMModel) -> (window: Int, isUserCap: Bool) {
        let native = model.contextWindowTokens
        guard let override = activeGroupContextLimit(), override > 0, override < Int.max else {
            return (native, false)
        }
        guard native > 0 else { return (override, true) }
        return override < native ? (override, true) : (native, false)
    }

    /// The bound group's context-limit override for the current session, or nil
    /// when the session is bound to a direct entry / has no binding / the group
    /// has no limit configured.
    private func activeGroupContextLimit() -> Int? {
        guard let sid = sessionId,
              let binding = ProviderConfigStore.shared.binding(for: sid),
              case .group(let gid, _) = binding.primarySource,
              let group = ProviderConfigStore.shared.group(for: gid) else { return nil }
        return group.contextLimitTokens
    }

    /// Hard ceiling on max_tokens we ever send to a provider, regardless of
    /// what the model itself claims. Some models advertise very large output
    /// windows; this bounds a single turn so it can't run away and burn the
    /// whole context budget. The final effective limit is
    /// min(globalMaxTokensCeiling, contextWindow - used, modelMaxTokens).
    ///
    /// Raised 64K → 128K: newer models (and the number-budget thinking tiers
    /// whose budget is carved out of max_tokens — Anthropic legacy high/xhigh/
    /// max, Qwen) were being clipped at 64K, squeezing high-effort thinking.
    static let globalMaxTokensCeiling: Int = 128_000

    /// Compute max output tokens that fits within the remaining context window.
    /// Returns `min(provider.defaultMaxTokens, contextWindow - inputTokens)`, floored at 1024.
    /// `lastContextTokens` is the API-reported input token count from the last call;
    /// when 0 (first call in a turn), falls back to char-based estimate.
    func dynamicMaxTokens(provider: any AgentProvider, model: LLMModel, lastContextTokens: Int = 0) -> Int {
        // Upper bound: prefer the user's configured value on this model.
        //
        // `model.maxOutputTokens` already combines `ModelEntry.baseModel.maxOutputTokens`
        // (API truth, may be nil) with `ModelEntry.overrides.maxOutputTokens` (user edit
        // in the model detail view). If the user set an override, it wins here —
        // previously this function only looked at `provider.defaultMaxTokens` and
        // silently ignored the override, which was the bug that made tiny per-model
        // limits have no effect on the actual request body.
        //
        // Fall back to provider.defaultMaxTokens only when neither the API nor the user
        // gave us a model-specific cap.
        //
        // Then clamp by the global ceiling so a model claiming 200K output never
        // actually causes us to request 200K.
        let modelOrProvider = model.maxOutputTokens ?? provider.defaultMaxTokens
        let upperBound = min(Self.globalMaxTokensCeiling, modelOrProvider)

        let contextWindow = effectiveContextWindow(for: model)
        guard contextWindow > 0 else { return upperBound }

        let inputTokens = lastContextTokens > 0 ? lastContextTokens : estimateContextTokens()
        let remaining = contextWindow - inputTokens

        // [T-ctx-overflow-hard-stop] The input ALREADY does not fit. The floor
        // below would quietly turn a negative `remaining` back into 1024 and the
        // oversized request would go out anyway — silently, since only the
        // `result != upperBound` line logged. Record it loudly: the send and
        // in-loop guards both treat overflow as `.needsCompact` now, so reaching
        // here means something bypassed them (a path that skips the check, or an
        // estimate that was under the ceiling when checked and over it by send
        // time). The clamp still returns the floor — refusing to send is the
        // guards' job, not this function's — but it no longer does so unnoticed.
        if remaining <= 0 {
            logger.warning("⚠️ dynamicMaxTokens: input \(inputTokens) tokens EXCEEDS context window \(contextWindow) (over by \(inputTokens - contextWindow)) — request would overflow; compaction guard should have fired")
        }

        // Floor: originally a fixed 1024, to guarantee enough room for a useful reply
        // when the context window is nearly full. If the user deliberately set a tiny
        // upper bound (e.g. 32 to test something), respect it — cap the floor to the
        // upper bound so we never inflate a deliberately small value.
        let floor = min(1024, upperBound)
        let clamped = max(remaining, floor)
        let result = min(upperBound, clamped)

        if result != upperBound {
            logger.info("📐 dynamicMaxTokens: \(result) (upperBound \(upperBound), remaining \(remaining), floor \(floor), window \(contextWindow), input \(inputTokens))")
        }
        // [T-maxtokens-override-receipt] One line per computation naming the
        // SOURCE of the upper bound. Field reports of "I changed Max Output
        // Tokens and the request still says 16384" have two very different
        // causes — the override never reaching this computation (code bug) vs
        // the user editing a different entry than the one the session is
        // bound to (data/UX issue). The 2026-07-21 audit traced every request
        // path (group loop, auto-retry, reminder/retry call sites) to
        // entry-merged models, so src=model here with the expected value
        // proves the chain; src=providerDefault on a model the user "edited"
        // means the bound entry has no override — check WHICH entry they edited.
        logger.info("📐 maxTokens=\(result) src=\(model.maxOutputTokens != nil ? "model(\(model.maxOutputTokens!))" : "providerDefault(\(provider.defaultMaxTokens))") ceiling=\(Self.globalMaxTokensCeiling) model=\(model.id)")
        return result
    }

}
