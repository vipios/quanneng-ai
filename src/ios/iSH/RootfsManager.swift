//
//  RootfsManager.swift
//  MinisApp
//
//  Manages Alpine Linux rootfs installation and paths
//

import Foundation
import Compression
import SQLite3

class RootfsManager {
    static let shared = RootfsManager()
    private let logger = AppLogger(category: "RootfsManager")

    /// [T-mcp-cli-help-and-readonly-ios] Guest path of the bundled minis-mcp-cli
    /// Python lib. Its files are mounted read-only (see applyDefaultMountOverlay).
    private static let mcpCliLibDir = "/usr/local/lib/minis-mcp-cli"
    private static let mcpCliLibPrefix = "/usr/local/lib/minis-mcp-cli/"

    /// [T-rootfs-reset-terminal-crash] Set once `reset()` deletes the rootfs
    /// directory from disk. The `ISHKernel` singleton boots exactly once per
    /// process and irreversibly becomes PID 1 via `become_first_process()`, so
    /// after a reset it is still `isBooted == true` but its fakefs is mounted
    /// against a `data/`/`meta.db` tree that no longer exists on disk. Reusing
    /// that stale mount (skipping install+boot because `isBooted` is true)
    /// crashes on the next `executeCommand`. Once this flag is set, the terminal
    /// must refuse to start a shell until the app is relaunched — there is no
    /// in-process way to un-boot or re-mount the kernel. Never cleared within a
    /// process lifetime; it is reset naturally on the next cold launch.
    private(set) var didResetWhileBooted = false

    private init() {}

    var rootfsPath: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("alpine-rootfs")
    }

    var dataPath: URL {
        return rootfsPath.appendingPathComponent("data")
    }

    /// Current rootfs architecture tag — change this when switching guest arch
    private let currentArch = "aarch64"

    private var archTagPath: URL {
        return rootfsPath.appendingPathComponent(".arch")
    }

    // MARK: - [T-rootfs-never-updated] 工具链版本标记

    /// 已装 rootfs 里记录的版本戳。guest 内的路径是
    /// `/etc/quanneng-rootfs-version`，由 `deps/prepare_alpine_rootfs.sh`
    /// 在打包时写入（内容形如 `3.20.3-1a2b3c4d5e6f7a8b`）。
    ///
    /// 注意这个文件在**两处**，用途不同，别搞混：
    ///   · guest 里 `data/etc/quanneng-rootfs-version` —— 打包时写进去的，
    ///     给用户和脚本看的，会跟着 zip 走
    ///   · 宿主上 `.quanneng-rootfs-version`（rootfs 根目录）—— 安装时
    ///     照抄一份，专供 `installIfNeeded()` 在 **boot 之前** 判断用
    ///
    /// 为什么不直接读 guest 里那份：那要先 boot 内核，而 `installIfNeeded()`
    /// 恰恰在 boot 之前跑。boot 之后再判断就晚了 —— 内核一旦
    /// become_first_process 就无法卸载重挂，删了 rootfs 会直接崩（见
    /// `didResetWhileBooted` 那段注释）。
    private var versionTagPath: URL {
        return rootfsPath.appendingPathComponent(".quanneng-rootfs-version")
    }

    /// bundle 里这份 rootfs 的版本戳。首次访问时从 zip 里读一次并缓存。
    ///
    /// 为什么不跟宿主上的比「文件是否相同」而要读这个：我们要判断的是
    /// 「bundle 里这份和已装的那份是不是同一批工具链」。读 zip 里那一行
    /// 文字是成本最低的可靠办法 —— 不用解压 145MB。
    private static var cachedBundleStamp: String?

    /// 从 `alpine-rootfs.zip` 里读出 `/etc/quanneng-rootfs-version` 的内容。
    /// 读不到（老 zip 没这个文件）返回 nil。
    private func bundleRootfsStamp() -> String? {
        if let cached = Self.cachedBundleStamp { return cached }

        guard let zipURL = Bundle.main.url(forResource: "alpine-rootfs", withExtension: "zip"),
              let archive = ZIPArchive(url: zipURL) else {
            return nil
        }
        let wanted = "alpine-rootfs/data/etc/quanneng-rootfs-version"
        for entry in archive.entries where entry.path == wanted {
            guard let data = try? archive.extractData(for: entry) else { return nil }
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            Self.cachedBundleStamp = text
            return text
        }
        return nil
    }

    /// 宿主上已装那份的版本戳。读不到返回 nil。
    private func installedRootfsStamp() -> String? {
        guard let text = try? String(contentsOf: versionTagPath, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 工具链版本对不对得上（bundle 里的 vs 已装的）。
    ///
    /// 三种情况都算「对得上」，不重装：
    ///   · 两边戳相同 —— 正常
    ///   · bundle 里没有戳（老 zip）—— 没有依据，不动，别把用户 rootfs 白删一遍
    ///   · 已装那份没有戳但 bundle 有 —— **算对不上**，要重装
    ///     （这正是从 1.70 升上来的情形：老 rootfs 没有这个文件）
    private var toolchainVersionMatches: Bool {
        guard let bundleStamp = bundleRootfsStamp() else { return true }
        guard let installed = installedRootfsStamp() else { return false }
        return installed == bundleStamp
    }

    var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: dataPath.path) else { return false }
        // Check architecture matches
        guard let tag = try? String(contentsOf: archTagPath, encoding: .utf8) else { return false }
        return tag.trimmingCharacters(in: .whitespacesAndNewlines) == currentArch
    }

    /// Why `isInstalled` came back false, as a short loggable string.
    ///
    /// [T-rootfs-arch-tag-observability] `isInstalled` collapses several very
    /// different situations into one `false`, and the caller that acts on it
    /// (`installIfNeeded`) then deletes the whole rootfs. When that happened on
    /// a test device on 2026-08-21, the logs could not say WHICH condition had
    /// tripped — the rootfs had booted fine hours earlier, so the arch tag went
    /// missing at some point in between and nothing recorded it. This
    /// distinguishes the cases so the next occurrence is diagnosable rather
    /// than another forensic reconstruction.
    private func archTagDiagnostic() -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dataPath.path) { return "data-dir-missing" }
        if !fm.fileExists(atPath: archTagPath.path) { return "arch-file-missing" }
        do {
            let raw = try String(contentsOf: archTagPath, encoding: .utf8)
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if tag.isEmpty { return "arch-file-empty" }
            return tag == currentArch ? "ok(\(tag))" : "arch-mismatch(found=\(tag) want=\(currentArch))"
        } catch {
            // Exists but unreadable — permissions, or a partially written file.
            return "arch-file-unreadable(\(error.localizedDescription))"
        }
    }

    /// Get the existing rootfs directory out of the way so a fresh copy can be
    /// installed at `rootfsPath`.
    ///
    /// [T-rootfs-undeletable-blocks-install] Tries a plain recursive delete
    /// first, and if that fails, MOVES the tree aside instead of giving up.
    ///
    /// Why the fallback is necessary: a recursive delete has to traverse every
    /// entry, so one unreachable entry anywhere in the tree fails the whole
    /// operation. Observed on a device on 2026-08-21 — a leftover test tree
    /// under `data/root/` nested ~10 levels of 80-character directory names
    /// deep pushed absolute paths past PATH_MAX (1024), and `removeItem` failed
    /// with POSIX 63 ENAMETOOLONG ("File name too long"), surfaced by
    /// Foundation as the thoroughly misleading "the file name
    /// \"alpine-rootfs\" is invalid". Because the old code let that error
    /// propagate, `installIfNeeded()` aborted BEFORE unzipping, so the rootfs
    /// could never be reinstalled: every launch retried the same delete, hit
    /// the same error, and iSH stayed permanently unbootable. Reinstalling from
    /// the UI did not help either — that button calls this very function.
    ///
    /// `rename(2)` only touches the directory ENTRY, never the contents, so it
    /// is unaffected by anything pathological inside — depth, name length, or
    /// permissions. Moving the tree aside therefore succeeds where deleting it
    /// cannot, and the install can proceed. We then attempt a best-effort
    /// cleanup of the moved-aside tree; if that also fails the tree is left in
    /// place (leaking disk) rather than blocking the user, and is logged so it
    /// can be reclaimed later.
    private func discardOldRootfs() throws {
        // [T-reset-keeps-userdata] 删之前登记「这棵树正在被删」。
        //
        // 本方法有三条调用路径，其中两条发生在内核**已经 boot 过**的时候：
        //   · `reset()`            —— 明确的重置动作
        //   · `reinstallKeepingUserData()` —— 失败界面的「重置内核环境」
        // 只有安装换代那条发生在 boot 之前。
        //
        // 内核一旦 become_first_process，它的 fakefs 就挂在这棵树上。
        // 树被删掉之后挂载点失效，终端若还复用（因为 isBooted 是 true
        // 就跳过 boot），下一次 executeCommand 会直接崩。
        // `didResetWhileBooted` 就是给这条路径兜底的：置位后终端会拒绝
        // 启动 shell，直到用户重启 App。
        //
        // 放在这里而不是各调用方自己写，是为了「新增调用方时不会再漏」。
        if ISHKernel.shared.isBooted {
            didResetWhileBooted = true
            logger.warning("[Rootfs] rootfs 被删除时内核已 booted —— 终端停用到重启")
        }

        let fm = FileManager.default
        do {
            try fm.removeItem(at: rootfsPath)
            return
        } catch {
            let ns = error as NSError
            logger.warning(
                "[Rootfs] delete failed for \(rootfsPath.path) — "
                + "domain=\(ns.domain) code=\(ns.code) "
                + "underlying=\(String(describing: ns.userInfo[NSUnderlyingErrorKey])) "
                + "desc=\(error.localizedDescription). Falling back to move-aside."
            )
        }

        // Same parent directory: rename(2) cannot cross filesystems, and a
        // Documents -> tmp move would risk EXDEV on some configurations.
        let parent = rootfsPath.deletingLastPathComponent()
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = parent.appendingPathComponent(".alpine-rootfs-broken-\(stamp)")
        do {
            try fm.moveItem(at: rootfsPath, to: aside)
            logger.warning("[Rootfs] moved undeletable rootfs aside to \(aside.lastPathComponent); install will continue")
        } catch {
            // Nothing left to try: we can neither delete nor move the old tree,
            // so installing on top of it would produce a mixed-version rootfs.
            // Fail loudly rather than silently corrupting it.
            logger.error("[Rootfs] move-aside ALSO failed for \(rootfsPath.path): \(error.localizedDescription)")
            throw error
        }

        // Best-effort reclaim. Expected to fail for exactly the reason the
        // original delete did; that is acceptable — correctness (a working
        // rootfs) matters more than the disk this leaks.
        //
        // [review] Also retry EVERY previously stranded tree, not just the one
        // we just created. The name is timestamped, so each occurrence makes a
        // new directory; without this sweep a device that hits this repeatedly
        // accumulates one full rootfs copy per occurrence with nothing ever
        // reclaiming them. A retry is worth attempting because the usual reason
        // the delete failed is a path that is too long *from this container's
        // prefix* — after an app container migration the prefix changes, and a
        // tree that was undeletable before can become deletable.
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
        where name.hasPrefix(".alpine-rootfs-broken-") {
            let stranded = parent.appendingPathComponent(name)
            if (try? fm.removeItem(at: stranded)) != nil {
                logger.info("[Rootfs] reclaimed stranded \(name)")
                continue
            }
            let bytes = (try? stranded.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0
            logger.warning(
                "[Rootfs] could not reclaim \(name) (~\(bytes) bytes); "
                + "left on disk. Delete it from the guest shell (paths are short there) "
                + "or via Files if space is needed."
            )
        }
    }

    // MARK: - [T-rootfs-never-updated] 保留用户数据的重装

    /// 要保留的用户数据，相对 `data/` 的路径。
    ///
    /// 只留这两个：
    ///   · `root`   —— 用户 home。模型在这里放脚本、临时工程、~/.config
    ///   · `var/ai` —— 共享目录。workspace / attachments / skills / offloads
    ///                全在它下面，是最要紧的一份。
    ///
    /// 刻意**不含** `/tmp`、`/var/cache`、`/usr` 这些：它们要么是一次性的，
    /// 要么属于 rootfs 本体，留着反而把新旧工具链混在一起。
    private static let preservedUserDataPaths = ["root", "var/ai", "var/minis"]

    /// 换 rootfs 但把用户数据搬过去。
    ///
    /// 为什么不复用 `reset(keepUserData:)`：那个方法只备份 `root`，
    /// 而且备份完就结束了 —— 恢复要靠调用方自己再调 `restoreUserData()`，
    /// 中间还得手动补 `meta.db`。这条路径还要恢复 `var/ai`（那个才是
    /// 最要紧的），所以单独写一份更清楚。
    ///
    /// 步骤（顺序不能调）：
    ///   1. 把这些目录拷到临时区
    ///   2. 删掉整棵旧 rootfs
    ///   3. 调 `installIfNeeded` 装新的 —— 递归调用，此时 isInstalled 为 false，
    ///      会走完整的解压 + 写 .arch 流程
    ///   4. 把临时区的东西拷回来
    ///   5. **把拷回来的每个路径登记进 meta.db**
    ///      —— 少了这步，文件在沙盒里但 fakefs 看不见：`ls` 里没有、
    ///      `stat` 报不存在。之前预装工具链时踩过一模一样的坑。
    ///
    /// 失败策略：备份失败就**放弃重装**并返回，宁可继续用旧 rootfs。
    /// 反过来说，绝不能为了换新工具链把用户数据搞丢。
    ///
    /// [T-reset-keeps-userdata] 访问级别是 internal 而不是 private，
    /// 因为失败界面「重置内核环境」也要走这条路 —— 见
    /// `resetKernelEnvironment()` 的说明。不要改成「调用方自己
    /// backup + reset + restore」：那等于把这段容易出错的顺序逻辑
    /// 复制到第二个地方。
    func reinstallKeepingUserData() throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("rootfs-upgrade-\(Int(Date().timeIntervalSince1970))",
                                    isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        var backedUp: [(name: String, url: URL)] = []
        for name in Self.preservedUserDataPaths {
            let src = dataPath.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = staging.appendingPathComponent(name, isDirectory: true)
            do {
                try fm.createDirectory(at: dst.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: src, to: dst)
                backedUp.append((name, dst))
                logger.info("[Rootfs] backed up \(name) for upgrade")
            } catch {
                // 备份不了就别升级了 —— 数据比新工具链重要。
                logger.error("[Rootfs] failed to back up \(name): \(error.localizedDescription) — aborting upgrade, keeping old rootfs")
                try? fm.removeItem(at: staging)
                return
            }
        }

        // 2. 删旧 rootfs
        //
        // [T-reset-keeps-userdata] 删之前必须登记「内核可能已经挂着这棵树」。
        // 这条路现在有两个调用方：
        //   · 版本戳变化时的自动换代（boot 之前，内核一定没起来）
        //   · 失败界面的「重置内核环境」（boot **已经失败过**）
        // 后者的内核状态不像前者那样干净：`-5` 只说明 mount 失败，不代表
        // 内核对象里没有任何残留。一旦它其实已经 booted，而我们把这棵树删了，
        // 终端还会复用那个失效的挂载并在下一次 executeCommand 时崩掉。
        // `reset()` 对这件事有保护，这里同样要有 —— 所以挪进 `discardOldRootfs`
        // 统一处理，而不是让每个调用方自己记得写。
        try discardOldRootfs()

        // 3. 装新的。这里递归调用自己在语义上有点绕，但能保证「装」的逻辑
        //    只有一份 —— 解压、写 .arch、建 var/ai 子目录、写版本戳全在那边。
        //    此刻 rootfsPath 已不存在，isInstalled == false，不会无限递归。
        //
        //    解压失败时用户数据还在 staging 里，必须先恢复回去再抛 ——
        //    否则用户就是「工具链没换成，数据也没了」，最坏的结果。
        do {
            try installIfNeeded()
        } catch {
            logger.error("[Rootfs] install during upgrade failed: \(error.localizedDescription) — restoring user data")
            let restored = restoreBackup(backedUp)
            if restored { try? fm.removeItem(at: staging) }
            throw error
        }

        // 4. 拷回来。有没恢复成功的就保留 staging，别把数据一起删了。
        let allRestored = restoreBackup(backedUp)
        if allRestored {
            try? fm.removeItem(at: staging)
        } else {
            logger.error("[Rootfs] some user data could not be restored — kept \(staging.path) for manual recovery")
        }
        logger.info("[Rootfs] toolchain upgrade complete (dataRestored=\(allRestored))")
    }

    /// 把备份搬回 rootfs 并登记进 meta.db。抽出来是因为成功路径和
    /// 安装失败路径都要用。
    ///
    /// ⚠️ `mergeCopy` 是**移动**语义，搬走的就从 staging 里消失了。
    /// 所以任何一项恢复失败，都要立刻把 staging 整个留下 ——
    /// 否则失败那一项的数据会随着 `removeItem(at: staging)` 一起丢掉。
    /// 返回 false 表示「有东西没恢复成功，别删 staging」。
    @discardableResult
    private func restoreBackup(_ backedUp: [(name: String, url: URL)]) -> Bool {
        var allOK = true
        for (name, src) in backedUp {
            let dst = dataPath.appendingPathComponent(name, isDirectory: true)
            do {
                // 新 rootfs 里可能有同名目录（如 var/ai 的几个子目录），
                // 用 merge 语义：逐项搬，遇到已存在的就替换。
                try mergeCopy(from: src, to: dst)
                // 登记进 meta.db —— 不登记等于没拷：
                // 文件在沙盒里但 fakefs 看不见，ls 里没有、stat 报不存在。
                registerSubtreeInMetaDB(hostRoot: dst)
                logger.info("[Rootfs] restored \(name)")
            } catch {
                allOK = false
                logger.error("[Rootfs] failed to restore \(name): \(error.localizedDescription) — data still in \(src.path)")
            }
        }
        return allOK
    }

    /// 把 `src` 目录的内容合并进 `dst`（`dst` 可以已存在）。
    private func mergeCopy(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        let children = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)
        for child in children {
            let target = dst.appendingPathComponent(child.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                try? fm.removeItem(at: target)
            }
            try fm.moveItem(at: child, to: target)
        }
    }

    func installIfNeeded() throws {
        if FileManager.default.fileExists(atPath: rootfsPath.path) && !isInstalled {
            logger.warning("[Rootfs] arch tag missing or mismatched — will delete and reinstall \(currentArch). archTag=\(archTagDiagnostic()) path=\(rootfsPath.path)")
            try discardOldRootfs()
        }

        // [T-rootfs-never-updated] 已装但工具链版本对不上 → 换代。
        //
        // 这条必须在 `isInstalled` 那个 return **之前**判，否则永远走不到：
        // 老用户 `isInstalled` 一直是 true（data/ 在、.arch 是 aarch64），
        // 于是新 ipa 里的 rootfs.zip 一辈子不解压，dpkg/xz/zstd 永远缺。
        if isInstalled && !toolchainVersionMatches {
            let installed = installedRootfsStamp() ?? "（无标记，老 rootfs）"
            let bundled = bundleRootfsStamp() ?? "（bundle 无标记）"
            logger.warning("[Rootfs] toolchain version changed — reinstalling. installed=\(installed) bundled=\(bundled)")
            try reinstallKeepingUserData()
            // 重装完成后往下走正常安装流程（此时 isInstalled 已为 false）
        }

        if isInstalled {
            // [R53-终端提示符改名] rootfs 只装一次、之后不更新 —— 老用户
            // 的 /etc/profile 里还是旧提示符 \u@minis。这里幂等修补：
            // 检测到旧值就替换成 quanNengAI，成本是一次几 KB 的文件读写。
            patchProfilePromptIfNeeded()
            // [R56-var/ai 迁移] 老版本把共享目录建在 /var/minis，改名
            // /var/ai 后要把它搬过去，否则老用户的 workspace/attachments/
            // skills 等真实数据会「消失」。幂等：/var/ai 已存在就不动。
            migrateVarMinisToVarAiIfNeeded()
            logger.info("[Rootfs] already installed (\(currentArch)) at \(rootfsPath.path)")
            return
        }

        guard let zipURL = Bundle.main.url(forResource: "alpine-rootfs", withExtension: "zip") else {
            throw NSError(
                domain: "RootfsManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "alpine-rootfs.zip not found in bundle"]
            )
        }

        logger.info("[Rootfs] installing from \(zipURL.path)")

        // Create destination directory
        try FileManager.default.createDirectory(
            at: rootfsPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Unzip using custom ZIP reader
        try unzipFile(at: zipURL, to: rootfsPath)

        // [T-meta-sidecar-heal] 解压完先清伴生文件，再校准。
        //
        // 包本身不带 `-shm` / `-wal`（prepare 脚本打包时 `-x "*.db-shm"`），
        // 所以这里通常删不到东西。但 `reinstallKeepingUserData()` 那条路是
        // 在**旧库刚被删、新库刚落地**的瞬间跑过来的 —— 此刻路径上任何一份
        // 上一代的 `-shm` 都会让这份全新的库直接 SQLITE_CORRUPT(11)。
        // 这里刚解出来的库是全新的，路径上不可能存在属于它的 `-wal`，
        // 所以无条件清是安全的。
        purgeMetaDBSidecars(aggressive: true)

        // [T-fakefs-rebuild-storm] 解压完立刻校准 meta.db 的 db_inode。
        //
        // 这一步必须在 boot **之前**做，而且是解压之后的第一件事：
        //   · 解压决定了 meta.db 最终的 st_ino，早于这里写的值都是错的
        //   · 内核 fake_db_init 拿 meta.db 里存的 db_inode 跟文件自己的
        //     st_ino 比，不等就调 fakefs_rebuild() 全表重建
        //   · 包里的 db_inode 恒为 0（fakefsify 写的），真 inode 永不为 0，
        //     所以不校准的话**每次首启都必然走一次全量重建**
        //
        // 全量重建本身不算错，但它是首启最脆弱的一段：几千条 fstatat 逐条走，
        // 中途被系统杀掉就留下 paths_old/stats_old 残表。而 fakefs_rebuild
        // 用的 EXEC 宏失败时调的是 die() —— 在 iOS 上 die_handler 被换成了
        // 「把 iSH 线程永久挂起」，于是界面就永远停在「正在启用内核」。
        // 让它一次都别重建，比事后补救可靠。
        calibrateMetaDBInode()

        // Write architecture tag so we detect mismatches on future launches
        try currentArch.write(to: archTagPath, atomically: true, encoding: .utf8)

        // [T-rootfs-never-updated] 把这份 rootfs 的版本戳记在 rootfs 根上，
        // 下次启动 `toolchainVersionMatches` 拿它跟 bundle 里那份比。
        //
        // 为什么要在宿主上再存一份（zip 里 `/etc/quanneng-rootfs-version`
        // 已经有一份）：判断发生在 boot **之前**，那时没法进 guest 读文件。
        // 宿主这份是给自己看的副本，guest 那份是给用户和脚本看的。
        if let stamp = bundleRootfsStamp() {
            try stamp.write(to: versionTagPath, atomically: true, encoding: .utf8)
            logger.info("[Rootfs] stamped toolchain version \(stamp)")
        } else {
            // bundle 里没有戳（旧 zip）。把旧戳清掉，免得下次误判成「版本相同」。
            try? FileManager.default.removeItem(at: versionTagPath)
            logger.info("[Rootfs] no version stamp in bundle (legacy zip) — version check disabled")
        }

        // Pre-create /var/ai/ shared directory structure
        let minisSubdirs = ["var/ai/attachments", "var/ai/offloads", "var/ai/workspace", "var/ai/skills", "var/ai/shared"]
        for subdir in minisSubdirs {
            let dirPath = dataPath.appendingPathComponent(subdir)
            try? FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)
        }

        // Flag fresh install so first-boot tasks (e.g. mirror auto-detect) can trigger.
        UserDefaults.standard.set(true, forKey: "rootfs.freshInstall")

        logger.info("[Rootfs] installation complete (\(currentArch)) at \(rootfsPath.path)")
    }

    /// [R56-var/ai 迁移] 把旧版根文件系统里的 /var/minis 目录搬到 /var/ai。
    ///
    /// 改名 /var/minis → /var/ai 后，老用户 rootfs 里已有的真实数据
    /// （workspace 里的工作文件、attachments 附件、skills 技能、
    /// offloads 输出等）还在旧路径下，挂载逻辑改去 /var/ai 就找不到了。
    /// 这里做一次启动时迁移：
    ///   · /var/ai 已存在 → 什么都不做（已经迁过 / 新装）
    ///   · /var/minis 不存在 → 什么都不做（全新安装，无旧数据）
    ///   · 两者都在 → 把 /var/minis 整体搬到 /var/ai（rename，原子且快）
    ///
    /// 注意：这里的路径是 fakefs 数据目录（data/var/minis、data/var/ai），
    /// 不是 Linux 里的 /var/minis 挂载点。bind-mount 的符号链接会由
    /// ISHExecutionCoordinator.performMount 在下次挂载时按新路径重建。
    private func migrateVarMinisToVarAiIfNeeded() {
        let fm = FileManager.default
        let oldDir = dataPath.appendingPathComponent("var/minis", isDirectory: true)
        let newDir = dataPath.appendingPathComponent("var/ai", isDirectory: true)

        // 新路径已存在 → 已迁过，跳过
        if fm.fileExists(atPath: newDir.path) {
            return
        }
        // 旧路径不存在 → 无旧数据，跳过
        guard fm.fileExists(atPath: oldDir.path) else {
            return
        }
        do {
            try fm.moveItem(at: oldDir, to: newDir)
            logger.info("[Rootfs][R56] 迁移完成 /var/minis → /var/ai")
        } catch {
            // move 失败（跨卷/权限）就退化成逐个拷贝，不丢数据。
            logger.warning("[Rootfs][R56] move 失败，退化为拷贝: \(error.localizedDescription)")
            // [R57-编译修复] 这里原来多套了一层 `do {` 却没有 `catch`，
            // 于是 `try fm.createDirectory` 变成「本作用域内未处理的 throw」，
            // 直接编译失败（RootfsManager.swift:257）。迁移本身是尽力而为，
            // 建目录失败也不该让整个函数抛出，改用 `try?` 并压平这层 do。
            try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)
            if let en = fm.enumerator(at: oldDir, includingPropertiesForKeys: nil) {
                while let src = en.nextObject() as? URL {
                    let rel = src.path.replacingOccurrences(of: oldDir.path, with: "")
                    guard !rel.isEmpty else { continue }
                    let dst = newDir.appendingPathComponent(rel)
                    if !fm.fileExists(atPath: dst.path) {
                        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? fm.copyItem(at: src, to: dst)
                    }
                }
            }
            logger.info("[Rootfs][R56] 拷贝迁移完成 /var/minis → /var/ai")
        }
    }

    /// [R53-终端提示符改名] 把已安装 rootfs 里 /etc/profile 的旧提示符
    /// `\u@minis` 修成 `\u@quanNengAI`。
    ///
    /// 幂等：新 rootfs（已是 quanNengAI）或 profile 不存在时直接返回，
    /// 不写文件。每次启动都跑一次，代价可忽略。
    private func patchProfilePromptIfNeeded() {
        let profilePath = dataPath.appendingPathComponent("etc/profile")
        guard let old = try? String(contentsOf: profilePath, encoding: .utf8) else { return }
        guard old.contains("@minis") else { return }
        let fixed = old
            .replacingOccurrences(of: "\\u@minis:", with: "\\u@quanNengAI:")
            .replacingOccurrences(of: "Welcome to MinisApp", with: "Welcome to QuanNengAI")
        guard fixed != old else { return }
        do {
            try fixed.write(to: profilePath, atomically: true, encoding: .utf8)
            logger.info("[Rootfs] /etc/profile 提示符已从 minis 改为 quanNengAI")
        } catch {
            logger.warning("[Rootfs] 写 /etc/profile 失败（保留旧提示符）: \(error.localizedDescription)")
        }
    }

    /// 解压完成后校准 `meta.db`，让首启不触发全量重建。
    ///
    /// 这是 `recovery` 入口：不返回「改没改」，只保证做完该做的事并留日志。
    /// 真正干活的是 `repairMetaDBIfNeeded()`。
    private func calibrateMetaDBInode() {
        let before = CFAbsoluteTimeGetCurrent()
        let changed = repairMetaDBIfNeeded()
        let elapsed = (CFAbsoluteTimeGetCurrent() - before) * 1000
        logger.info("[Rootfs] meta.db calibrated after unzip (changed=\(changed)) "
                    + "\(String(format: "%.1f", elapsed))ms")
    }

    // MARK: - [T-meta-sidecar-heal] meta.db 读不出来时的自救

    /// `meta.db` 的伴生文件后缀。
    ///
    /// 三者都不是用户数据，但危险程度完全不同：
    ///   · `-shm`     WAL 的共享内存索引，**纯派生**。删掉 SQLite 会从 `-wal`
    ///                重建，`-wal` 为空时它就是一段彻底无主的旧索引
    ///   · `-wal`     预写日志。**有内容的时候里面就是最近的提交**，
    ///                删了等于丢掉最后一次 checkpoint 之后的 guest 写入
    ///   · `-journal` 回滚日志，是未完成事务的撤销记录。删了等于让
    ///                一个写了一半的事务「生效」，必然把库搞坏
    ///
    /// 注意别把 `-shm` 想得太能干：换个新进程、文件原样摆着，
    /// SQLite 自己会从 `-wal` 重建索引，一份陈旧的 `-shm` **不会**
    /// 单独造成 `rc=11`（本地实测过）。它只是「反正没用，顺手清掉」。
    private static let metaDBSidecars = ["-shm", "-wal", "-journal"]

    /// 删掉 `meta.db` 的伴生文件。
    ///
    /// 调用前提：**当前进程里没有别的连接打开这个库**。我们只在 boot 之前
    /// （`repairMetaDBIfNeeded`）和解压刚结束、内核还没起来的时候调，
    /// 这个前提成立。
    ///
    /// - Parameter aggressive: `false` 走日常安全策略 —— `-shm` 一律删，
    ///   `-wal` 只删空文件，`-journal` 不碰；`true` 表示已经确认库读不出来、
    ///   准备整份替换，三个全删。
    /// - Returns: 删掉的 `后缀(字节数)`，只用于日志。
    @discardableResult
    private func purgeMetaDBSidecars(aggressive: Bool) -> [String] {
        // 内核已经 booted 时，它的 sqlite 连接就挂在这个库上，
        // 这时候删伴生文件等于跟一个活着的连接抢文件。直接放弃 ——
        // 这些文件在下次冷启动（内核一定没起来）时再治，那时才是安全的。
        if ISHKernel.shared.isBooted {
            logger.warning("[Rootfs] 内核已 booted，跳过清 meta.db 伴生文件")
            return []
        }
        let fm = FileManager.default
        let base = rootfsPath.appendingPathComponent("meta.db").path
        var removed: [String] = []
        for suffix in Self.metaDBSidecars {
            let path = base + suffix
            guard let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber else {
                continue
            }
            // 保守策略下只放过「有内容的 -wal」和「-journal」。
            let keep = !aggressive && suffix != "-shm" && size.intValue > 0
            if keep { continue }
            if (try? fm.removeItem(atPath: path)) != nil {
                removed.append("\(suffix)(\(size.intValue)B)")
            }
        }
        if !removed.isEmpty {
            logger.warning("[Rootfs] 清掉 meta.db 伴生文件: \(removed.joined(separator: " "))")
        }
        return removed
    }

    /// 内核 `fake_db_init()` 里那 17 条 `PREPARE_OR_FAIL` 的**原文**。
    ///
    /// 探针要复刻的是「内核挂载时到底会做什么」，所以这里一个字都不能改，
    /// 也不能「挑几条代表性的」。抄自 `fs/fake-db.c:396-413`，
    /// 只去掉了 C 里的换行拼接。
    ///
    /// 为什么必须逐条 prepare 而不是随便读个 pragma：`sqlite3_prepare_v2`
    /// 在编译阶段就要把表名/列名在 `sqlite_master` 里解析出来，
    /// 而「表被删了」「schema 根页被清零」这两种坏法**只有走 schema 才会暴露**。
    /// `PRAGMA user_version` 读的是第 1 页头部的固定偏移，根本不碰 schema ——
    /// 1.85 之前拿它当唯一判据，结果库烂成一半还是判「好的」，
    /// 自救直接跳过，冷启动继续 `-5`。
    private static let kernelPrepareStatements: [String] = [
        "begin deferred",
        "begin immediate",
        "commit",
        "rollback",
        "select inode from paths where path = ?",
        "select inode, stat from stats natural join paths where path = ?",
        "insert into stats (stat) values (?)",
        "insert or replace into paths values (?, last_insert_rowid())",
        "select stat from stats where inode = ?",
        "update stats set stat = ? where inode = ?",
        "insert or replace into paths (path, inode) values (?, ?)",
        "delete from paths where path = ?",
        "update or replace paths set path = change_prefix(path, ?, ?) "
            + "where (path >= ? and path < ?) or path = ?",
        "select path from paths where inode = ?",
        "delete from stats where inode = ? "
            + "and not exists (select 1 from paths where inode = stats.inode)",
        "insert or ignore into orphans (inode) values (?)",
        "delete from orphans where inode = ?",
    ]

    /// 试读一次 `meta.db`：打开 → 读 `user_version` → `quick_check` → 17 条 prepare。
    ///
    /// 四步的职责各不相同，少一步就会漏掉一类坏法：
    ///   1. 打开                 文件在不在、权限对不对、是不是被别的进程锁死
    ///   2. `PRAGMA user_version` 回报版本号（**只用来回报，不单独当判据**）
    ///   3. `PRAGMA quick_check`  把每个 btree 页真的读一遍 → 抓物理损坏
    ///   4. 17 条 prepare         逐条对齐内核对 schema 的要求 → 抓「表/列没了」
    ///
    /// 3 和 4 不能互相替代：`quick_check` 只查 btree 结构，一张**整表不存在**
    /// 的库在它眼里完全健康；反过来，表结构齐全但索引页被清零，
    /// 17 条 prepare 也照样全过（prepare 只读 schema，不读数据页）。
    ///
    /// 全部只读：`quick_check` 和 `prepare` 都不写任何字节。**不 step 那 13 条
    /// 带写操作的语句** —— 探针绝不能修改现场。
    private func probeMetaDBReadable() -> (ok: Bool, rc: Int32, uv: Int32, message: String) {
        let metaDBPath = rootfsPath.appendingPathComponent("meta.db").path
        var handle: OpaquePointer?
        let openRC = sqlite3_open_v2(metaDBPath, &handle, SQLITE_OPEN_READWRITE, nil)
        guard openRC == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            return (false, openRC, -1, "open rc=\(openRC)")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        /// 把一条语句 prepare 出来、立刻 finalize。返回 0 表示这一条内核也能过。
        func prepareOnly(_ sql: String) -> (rc: Int32, err: String) {
            var stmt: OpaquePointer?
            let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            if let stmt { sqlite3_finalize(stmt) }
            return rc == SQLITE_OK ? (0, "") : (rc, String(cString: sqlite3_errmsg(db)))
        }

        // ① user_version —— 单独失败就是硬失败（连第 1 页都读不出来）。
        var uv: Int32 = -1
        do {
            var stmt: OpaquePointer?
            let rc = sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil)
            guard rc == SQLITE_OK, let stmt else {
                if let stmt { sqlite3_finalize(stmt) }
                return (false, rc, -1, "uv:prepare rc=\(rc) \(String(cString: sqlite3_errmsg(db)))")
            }
            defer { sqlite3_finalize(stmt) }
            let stepRC = sqlite3_step(stmt)
            guard stepRC == SQLITE_ROW else {
                return (false, stepRC, -1, "uv:step rc=\(stepRC) \(String(cString: sqlite3_errmsg(db)))")
            }
            uv = sqlite3_column_int(stmt, 0)
        }

        // ② quick_check —— 物理结构
        if let bad = quickCheckFailure(db) {
            return (false, bad.rc, uv, "quick_check \(bad.text)")
        }

        // ③ 17 条 prepare —— 内核挂载时做的就是这个
        for sql in Self.kernelPrepareStatements {
            let r = prepareOnly(sql)
            if r.rc != 0 {
                // 只截前 32 个字符：整条 SQL 会把这行日志撑爆。
                return (false, r.rc, uv, "prepare[\(sql.prefix(32))] rc=\(r.rc) \(r.err)")
            }
        }
        return (true, 0, uv, "ok")
    }

    /// 跑一遍 `PRAGMA quick_check`：正常返回 nil，坏了返回 (错误码, 描述)。
    ///
    /// 为什么用 `quick_check` 而不是 `integrity_check`：后者会把**每一行**
    /// 和它对应的索引项逐条比对，5MB 的库要几百毫秒，放在启动路径上太贵。
    /// `quick_check` 只走 btree 结构本身，本地实测 5676 行的库 ~8ms，
    /// 抓的正是我们要抓的那类坏法（整页被清零 / 页链断掉 / 页头垃圾）。
    ///
    /// 注意返回形态：SQLite 发现损坏时**不一定**回一个错误码，
    /// 它更常见的做法是「正常返回若干行，每行是一句人话描述」。
    /// 所以判据是「读出来的行恰好只有一行 `ok`」，而不是「有没有抛错」。
    private func quickCheckFailure(_ db: OpaquePointer) -> (rc: Int32, text: String)? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            return (rc, "prepare rc=\(rc) \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [String] = []
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_DONE { break }
            guard stepRC == SQLITE_ROW else {
                return (stepRC, "step rc=\(stepRC) \(String(cString: sqlite3_errmsg(db)))")
            }
            if let cstr = sqlite3_column_text(stmt, 0) {
                // quick_check 的描述里带换行（"*** in database main ***\nTree 2 page 2: ..."）。
                // 这一行最后要塞进单行诊断串，换行会把 UI 撑成好几段，直接压平。
                rows.append(String(cString: cstr)
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if rows == ["ok"] { return nil }
        // 最多带两行出来，够定位就行。
        return (SQLITE_CORRUPT, rows.prefix(2).joined(separator: " / "))
    }

    /// 这个错误码是不是「库在文件层坏了」。
    ///
    /// 只用于**诊断措辞**（区分「读不出来」和「缺表」），不再用它决定要不要自救 ——
    /// 决定自救的是 `isLockContention`，见 `repairMetaDBIfNeeded`。
    ///
    /// 三个：
    ///   · 11 `SQLITE_CORRUPT`  库体/索引坏了（我们复现出来的就是这个）
    ///   · 26 `SQLITE_NOTADB`   根本不是 SQLite 文件
    ///   · 10 `SQLITE_IOERR`    读不出来（底层 I/O 错）
    private static func isFileLevelCorruption(_ rc: Int32) -> Bool {
        let primary = rc & 0xff
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB || primary == SQLITE_IOERR
    }

    /// 这次失败是不是「别人正拿着这个库」——只有这种情况不能动文件。
    ///
    /// `SQLITE_BUSY(5)` / `SQLITE_LOCKED(6)`：另一个连接（可能是刚 boot 失败、
    /// 连接还没回收的内核）正开着这个库。这时候删 `-shm`、挪 `meta.db`
    /// 是**从活着的连接脚下抽地板**，能把一个本来只是锁竞争的库彻底搞坏。
    ///
    /// 反过来，**除了这两个以外的任何失败都应该去救**：
    /// 早先的判据是白名单（只认 11/26/10），结果 0 字节的库、被清空 schema
    /// 的库报的是 `SQLITE_ERROR(1) no such table`，白名单放不进去 ——
    /// 自救直接被跳过，然后内核照样 `-5`。黑名单才是对的方向。
    private static func isLockContention(_ rc: Int32) -> Bool {
        let primary = rc & 0xff
        return primary == SQLITE_BUSY || primary == SQLITE_LOCKED
    }

    /// 把 `meta.db` 头 100 字节里几个决定性字段读出来，拼成一行进诊断串。
    ///
    /// 为什么值得单独写：`rc=11` 只说「坏了」，不说**怎么坏的**，而不同
    /// 坏法的处置完全不一样。头部这几个数字能直接分开：
    ///   · `pg=` 0 或不是 2 的幂 → 头部被写坏（已经不是合法的 SQLite 文件）
    ///   · 文件大小不是 `pg` 的整数倍 → **尾部有多余字节**，
    ///     典型成因是「覆写文件时没截断」
    ///   · `sz` 和 `pg*n` 对不上 → 页数被改过 / 文件被截断
    ///   · `wv=2` → 这份库是 WAL 模式，会带 `-shm` / `-wal`
    ///
    /// 全程只读，不创建任何文件 —— 诊断自己不能改现场。
    static func metaDBHeaderSummary(_ path: String) -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { return "头:读不到" }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 100)
        guard head.count >= 100 else { return "头:不足100B(\(head.count))" }

        // 全部按**大端**读：SQLite 头里除 `-shm` 外都是 network byte order。
        let base = head.startIndex
        func be16(_ off: Int) -> UInt16 {
            (UInt16(head[base + off]) << 8) | UInt16(head[base + off + 1])
        }
        func be32(_ off: Int) -> UInt32 {
            (UInt32(head[base + off]) << 24)
            | (UInt32(head[base + off + 1]) << 16)
            | (UInt32(head[base + off + 2]) << 8)
            | UInt32(head[base + off + 3])
        }

        // 头里 page_size 存成 16 位；写 1 表示 65536。
        let rawPageSize = Int(be16(16))
        let pageSize = rawPageSize == 1 ? 65536 : rawPageSize
        let writeVersion = head[base + 18]
        let readVersion = head[base + 19]
        let pageCount = Int(be32(28))
        // 别写成 `((try? ...)?\n[.size] as? NSNumber)` —— 把 `?` 断在行尾、
        // `[` 起下一行，Swift 会把它当成三元运算符 + 数组字面量去解析，
        // 报 `expected ',' separator`（1.86 的第一次 CI 就是这么挂的）。
        var fileSize = -1
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let sz = attrs[.size] as? NSNumber {
            fileSize = sz.intValue
        }

        var flags: [String] = []
        if pageSize <= 0 || (pageSize & (pageSize - 1)) != 0 { flags.append("页大小非法") }
        if fileSize >= 0, pageSize > 0, fileSize % pageSize != 0 { flags.append("非整除") }
        if pageSize > 0, pageCount > 0, pageCount * pageSize != fileSize {
            flags.append("页数×页大小≠文件大小")
        }
        let suffix = flags.isEmpty ? "" : " ⚠︎" + flags.joined(separator: "/")
        return "头:pg=\(pageSize) n=\(pageCount) sz=\(fileSize) wv=\(writeVersion) rv=\(readVersion)\(suffix)"
    }

    /// 把 `data/` 下**新库里没有的**路径登记进 `meta.db`（单连接 + 单事务）。
    ///
    /// 为什么不复用 `registerSubtreeInMetaDB`：那个函数每个路径都
    /// `sqlite3_open` / `close` 一次。用户数据目录（几千个文件）还能忍，
    /// 整棵 rootfs（5 万+ 路径）就是几万次开关库，慢到不能放在启动路径上。
    /// 这里一次 open、一个事务、两条预编译语句搞定。
    ///
    /// `onlyIfMissing` 为 true 时不覆盖已有行 —— 包里的库对 `/usr`、`/dev`
    /// 这些出厂路径存着**正确的 uid/gid/rdev**，重扫时不能拿宿主的值盖掉。
    ///
    /// - Returns: 新登记了多少个路径。
    @discardableResult
    private func enrollTreeIntoMetaDB(onlyIfMissing: Bool) -> Int {
        let fm = FileManager.default
        let metaDBPath = rootfsPath.appendingPathComponent("meta.db").path
        let dataPrefix = dataPath.standardized.path
        guard fm.fileExists(atPath: dataPrefix) else {
            logger.error("[Rootfs] enroll: data/ 不存在，跳过")
            return 0
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(metaDBPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db else { return 0 }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)

        var selStmt: OpaquePointer?
        var insStat: OpaquePointer?
        var insPath: OpaquePointer?
        defer {
            if let selStmt { sqlite3_finalize(selStmt) }
            if let insStat { sqlite3_finalize(insStat) }
            if let insPath { sqlite3_finalize(insPath) }
        }
        guard sqlite3_prepare_v2(db, "SELECT inode FROM paths WHERE path = ?",
                                 -1, &selStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "INSERT INTO stats (stat) VALUES (?)",
                                 -1, &insStat, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db,
                                 "INSERT OR REPLACE INTO paths (path, inode) "
                                 + "VALUES (?, last_insert_rowid())",
                                 -1, &insPath, nil) == SQLITE_OK else {
            logger.error("[Rootfs] enroll: 预编译失败 — \(String(cString: sqlite3_errmsg(db)))")
            return 0
        }

        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        var added = 0

        // 登记一个宿主路径。linuxPath 已经算好，避免重复做字符串处理。
        func enroll(hostPath: String, linuxPath: String) {
            if onlyIfMissing, let selStmt {
                bindPathBlob(selStmt, index: 1, path: linuxPath)
                let hit = sqlite3_step(selStmt) == SQLITE_ROW
                sqlite3_reset(selStmt)
                if hit { return }
            }

            // 16 字节 = iSH 的 `struct ish_stat { mode, uid, gid, rdev }`
            // （fs/fake-db.h，四个 uint32）。文件大小和 mtime 不在这里 ——
            // fakefs 每次都 `fstatat` 真文件去取，所以 db 里没有它们是对的。
            //
            // mode 必须从真文件读：写死 0644/0755 会让恢复回来的脚本丢掉
            // 可执行位（此前 `registerSubtreeInMetaDB` 就是这么干的）。
            // 高 4 位是文件类型（S_IFREG/S_IFDIR/S_IFCHR...），必须保留。
            //
            // 用 `lstat` 而不是 `stat`：`stat` 会跟随符号链接，把链接本身
            // 记成它指向的那个文件的类型，fakefs 就再也认不出这是链接了。
            var st = stat()
            let haveStat = lstat(hostPath, &st) == 0
            let rawMode = haveStat ? UInt32(st.st_mode) : 0
            let effectiveMode: UInt32 = haveStat ? (rawMode & 0o177777) : 0o100644
            // rdev 只对字符/块设备有意义。普通文件留着 0 —— 而 Darwin 和
            // Linux 的 dev_t 编码并不相同，所以只在我们真插新设备节点时
            // 才有这点偏差，包里的设备节点不会被覆盖（onlyIfMissing）。
            let isDevice = (rawMode & 0o170000) == 0o020000 || (rawMode & 0o170000) == 0o060000
            let rdev: UInt32 = (haveStat && isDevice)
                ? UInt32(truncatingIfNeeded: st.st_rdev) : 0

            var statBytes: [UInt8] = Array(repeating: 0, count: 16)
            for (i, value) in [effectiveMode, UInt32(0), UInt32(0), rdev].enumerated() {
                let le = value.littleEndian
                withUnsafeBytes(of: le) { src in
                    for b in 0..<4 { statBytes[i * 4 + b] = src[b] }
                }
            }
            guard let insStat, let insPath else { return }
            sqlite3_bind_blob(insStat, 1, statBytes, Int32(statBytes.count), Self.SQLITE_TRANSIENT)
            guard sqlite3_step(insStat) == SQLITE_DONE else {
                sqlite3_reset(insStat)
                return
            }
            sqlite3_reset(insStat)

            bindPathBlob(insPath, index: 1, path: linuxPath)
            if sqlite3_step(insPath) == SQLITE_DONE { added += 1 }
            sqlite3_reset(insPath)
        }

        func linuxPath(for hostPath: String) -> String? {
            if hostPath == dataPrefix { return "/" }
            guard hostPath.hasPrefix(dataPrefix + "/") else { return nil }
            return String(hostPath.dropFirst(dataPrefix.count))
        }

        guard let rootLinux = linuxPath(for: dataPrefix) else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return 0
        }
        enroll(hostPath: dataPrefix, linuxPath: rootLinux)

        // 迭代而不是递归：rootfs 里有 10 层以上的目录，递归容易把栈吃光。
        var stack: [String] = [dataPrefix]
        while let dir = stack.popLast() {
            guard let children = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in children {
                let child = dir + "/" + name
                guard let linux = linuxPath(for: child) else { continue }
                enroll(hostPath: child, linuxPath: linux)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue {
                    stack.append(child)
                }
            }
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        logger.info("[Rootfs] enroll: 登记 \(added) 个路径 (onlyIfMissing=\(onlyIfMissing))")
        return added
    }

    /// 从 bundle 的 `alpine-rootfs.zip` 里只抽出 `meta.db` 一份，换掉已经读不出来的那份。
    ///
    /// [T-meta-sidecar-heal] 为什么可以「只换 db、不动 `data/`」：
    ///   · `data/` 里是真实的文件内容，一个字节都不该动
    ///   · `meta.db` 只存「路径 → inode」和 16 字节的 `struct ish_stat`
    ///     （mode/uid/gid/rdev，见 iSH `fs/fake-db.h`）。文件大小、mtime
    ///     都是 fakefs 每次 `fstatat` 从真文件读的 —— 所以库里**没有**
    ///     任何重建不了的信息
    ///   · 包里的库描述的是「出厂时的系统文件」，那正是我们要的基准；
    ///     用户自己加的文件，最后由 `enrollTreeIntoMetaDB` 扫一遍补齐
    ///
    /// 这就是「重置内核环境」想达到的效果，但不用删 145MB 的树、
    /// 不用重新解压 30 秒，用户数据全程原地不动。
    ///
    /// 步骤顺序不能调：先备份坏库（判错了还能捞），再解出新库并**验证**，
    /// 验证过了才换，换完才清伴生文件。
    ///
    /// - Returns: 是否换成功（成功 = 新库可读且 `meta` 表恰好一行）。
    @discardableResult
    func restoreMetaDBFromBundle() -> Bool {
        let fm = FileManager.default
        guard let zipURL = Bundle.main.url(forResource: "alpine-rootfs", withExtension: "zip") else {
            logger.error("[Rootfs] meta.db 自救失败：bundle 里没有 alpine-rootfs.zip")
            return false
        }
        guard let archive = ZIPArchive(url: zipURL) else {
            logger.error("[Rootfs] meta.db 自救失败：zip 打不开")
            return false
        }
        let entryName = "alpine-rootfs/meta.db"
        guard let entry = archive.entries.first(where: { $0.path == entryName }) else {
            logger.error("[Rootfs] meta.db 自救失败：zip 里没有 \(entryName)")
            return false
        }

        let metaDBURL = rootfsPath.appendingPathComponent("meta.db")
        let stamp = Int(Date().timeIntervalSince1970)
        let incomingURL = rootfsPath.appendingPathComponent("meta.db.incoming-\(stamp)")

        // 1. 解到临时名，先验证，别把唯一一份能用的库覆盖掉。
        do {
            try extractEntryStreaming(entry, from: archive, to: incomingURL)
        } catch {
            logger.error("[Rootfs] meta.db 自救失败：解包出错 \(error.localizedDescription)")
            try? fm.removeItem(at: incomingURL)
            return false
        }

        // 验证：能打开、有 meta 表、meta 恰好一行。三条缺一不可 ——
        // 缺了任何一条，换上去只会把「读出来」换成「读出来但内核 die」。
        //
        // 用 READWRITE 而不是 READONLY：包里的库是 **WAL 模式**（头里 wv=2 rv=2），
        // 只读打开时 SQLite 没法 checkpoint，close 之后会在旁边留下
        // `xxx-shm` / `xxx-wal` 两个文件 —— 而这个 xxx 是临时名，
        // 换名之后它们就成了永远没人清的无主垃圾（每次自救留一对）。
        // 用读写打开，最后一个连接关闭时会自己 checkpoint 并删掉这两个。
        var db: OpaquePointer?
        var verified = false
        if sqlite3_open_v2(incomingURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
           let db {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT count(*) FROM meta", -1, &stmt, nil) == SQLITE_OK,
               let stmt {
                if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_int(stmt, 0) == 1 {
                    verified = true
                }
                sqlite3_finalize(stmt)
            }
        }
        if let db { sqlite3_close(db) }
        guard verified else {
            logger.error("[Rootfs] meta.db 自救失败：解出来的库自己就不合格")
            try? fm.removeItem(at: incomingURL)
            return false
        }

        // 2. 坏库挪到一边留档（大小 ≈1MB，留着不心疼）。
        let corruptURL = rootfsPath.appendingPathComponent("meta.db.corrupt-\(stamp)")
        if fm.fileExists(atPath: metaDBURL.path) {
            try? fm.moveItem(at: metaDBURL, to: corruptURL)
        }
        try? fm.moveItem(at: incomingURL, to: metaDBURL)

        // 临时名下面的伴生文件不可能属于最终这份库（名字都不一样），
        // 上面那次 move 也不会带它们走。显式清掉，别留成无主垃圾。
        for suffix in Self.metaDBSidecars {
            try? fm.removeItem(atPath: incomingURL.path + suffix)
        }

        // 3. 换完才清伴生文件 —— 旧 shm 属于旧库，留着必然配不上对。
        purgeMetaDBSidecars(aggressive: true)

        // 4. 把用户在 `data/` 里加的路径补登记进去（包里的库不认识它们）。
        let added = enrollTreeIntoMetaDB(onlyIfMissing: true)

        // 5. 只留最近两份坏库。
        //
        // 如果是「每次冷启动都坏」，自愈会一路重复，每份坏库 1~8MB，
        // 攒几十份就能把用户的沙盒吃掉 —— 而这里恰恰是在磁盘可能
        // 已经很紧张的时候跑的。留两份够查最近两次现场，多的一份不留。
        pruneArchivedCorruptMetaDBs(keep: 2)

        logger.warning("[Rootfs] meta.db 已从 bundle 还原（坏库留档 \(corruptURL.lastPathComponent)，"
                       + "补登记 \(added) 个路径）")
        return true
    }

    /// 只保留最近 `keep` 份 `meta.db.corrupt-<stamp>`，其余删掉。
    ///
    /// 文件名里的 stamp 是秒级时间戳，按名字倒序就是按时间倒序，
    /// 不用去读每个文件的创建时间（那还得处理时区/精度）。
    private func pruneArchivedCorruptMetaDBs(keep: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: rootfsPath.path) else { return }
        let archives = names
            .filter { $0.hasPrefix("meta.db.corrupt-") }
            .sorted(by: >)          // 降序：新的在前
        guard archives.count > keep else { return }
        for name in archives.dropFirst(keep) {
            if (try? fm.removeItem(atPath: rootfsPath.appendingPathComponent(name).path)) != nil {
                logger.info("[Rootfs] 清掉旧坏库留档 \(name)")
            }
        }
    }

    /// 把 `meta.db` 幂等地**直接构造成「内核迁移全部跑完」的终态**。
    ///
    /// [T-meta-terminal-state] 为什么不再「零散补漏」——
    ///
    /// 1.78 的做法是「补 orphans 表 + 清残表 + 校准 db_inode」，三件事各管一段。
    /// 它在设备上留下了一个**必死组合**：`orphans` 补上了，但 `user_version`
    /// 还是 3。内核 `fakefs_migrate` 接着跑 `migrations[3]`，那条 SQL 是
    /// `create table orphans (...)` —— **没有 `if not exists`**，撞车后走
    /// `EXEC` 宏调 `die()`；iOS 上 `die_handler` 是 `embedded_die_handler`，
    /// 只把 iSH 线程永久睡死，于是界面永远停在「正在启用内核」。
    ///
    /// 也就是说：**修的每一处都必须让整个库离内核期望的终态更近一步，
    /// 而不是只在某一段自洽。** 现在的做法是照着 `fs/fake-migrate.c` 把
    /// migrations[0..3] 的最终效果一次性构造出来，然后直接把
    /// `user_version` 推到 4 —— 内核看到 4 就整段跳过，那些非幂等 DDL
    /// 一次都不会执行。
    ///
    /// 每一步都是 `if [not] exists` 形式，重复调用无副作用（已实测三遍）。
    ///
    /// 注意：这里**不重建 data/ 目录树**，用户数据一个字节都不动。
    /// 只碰 meta.db 里的表结构和几个整数。
    @discardableResult
    func repairMetaDBIfNeeded() -> Bool {
        let metaDBPath = rootfsPath.appendingPathComponent("meta.db").path
        guard FileManager.default.fileExists(atPath: metaDBPath) else { return false }

        // ── 0. [T-meta-sidecar-heal] 打开之前的自救 ──
        //
        // 为什么必须在**打开之前**做：库里一旦被打开，SQLite 就会按它自己的
        // 判断去读/重建伴生文件，那时再删就是跟一个活着的连接抢文件。
        //
        // 关于设备上那串 `wal:prepare rc=11 / 表为空 / uv=-1`：
        // 11 是 `SQLITE_CORRUPT`，是**文件层损坏**，不是缺表。
        // 有一点必须说清楚 —— 我一度以为是「旧 `-shm` 残留」造成的，
        // 但那只能在**同一进程里、库被换过**的情况下复现出来；
        // 换个新进程、文件原样放着，SQLite 自己会从 `-wal` 重建索引，
        // 根本不会报 11。所以设备上的具体成因**还没坐实**。
        //
        // 这一段因此不押注在某一个成因上，改成三级：
        //   ① 清掉一定没用的伴生文件（无损，顺手）
        //   ② 还是读不出来 → 清光三个伴生文件再读（仍是无损的，只是更激进）
        //   ③ 还读不出来 → 说明坏在库体本身，从 bundle 换一份（见
        //      restoreMetaDBFromBundle，用户数据一个字节不动）
        // 三级都过不去才放弃。这三条对「怎么坏的」不敏感，这才是重点。
        purgeMetaDBSidecars(aggressive: false)

        // 只要「换过库」或「改过库」就让调用方重试 boot。
        // 早先只看 `changed`（uv / db_inode 有没有变），换库这条路没算进去 ——
        // 换完之后 uv 本来就是 4，边界上千一失手就是「库修好了但没重试」。
        var healed = false

        var attempt = probeMetaDBReadable()
        if !attempt.ok {
            logger.error("[Rootfs] repairMetaDB: 预检没通过（\(attempt.message)）")
        }
        if !attempt.ok, !Self.isLockContention(attempt.rc) {
            // 走到这里说明「库我们读不出来」，而**不是**别人正拿着它。
            // 除了锁竞争，其余失败都按「这份库不能用了」处理 —— 包括
            // 11/26/10（物理损坏）、1（`no such table`，0 字节库或 schema 被清空）、
            // 14（打不开）。理由：这些情况下内核一定 mount 不上，
            // 而换一份 db 是**无损**的（`data/` 一个字节不动，路径最后补登记）。
            // 反过来放行的代价是用户看到 `-5` 然后被赶去点「重置」删掉 145MB。
            //
            // 顺序：先清伴生文件（无损、能治「旧索引配不上新库」），
            // 还不行才换库体（也够快，< 1s）。
            purgeMetaDBSidecars(aggressive: true)
            attempt = probeMetaDBReadable()
            logger.warning("[Rootfs] repairMetaDB: 清伴生文件后重读 → "
                           + (attempt.ok ? "OK uv=\(attempt.uv)" : attempt.message))
            if !attempt.ok, restoreMetaDBFromBundle() {
                healed = true
                attempt = probeMetaDBReadable()
                logger.warning("[Rootfs] repairMetaDB: 从 bundle 还原后重读 → "
                               + (attempt.ok ? "OK uv=\(attempt.uv)" : attempt.message))
            }
            if !attempt.ok {
                logger.error("[Rootfs] repairMetaDB: meta.db 救不回来，放弃（\(attempt.message)）")
                return false
            }
        } else if !attempt.ok {
            // 锁竞争。**一个文件都不动** —— 从活着的连接脚下抽地板
            // 才是真能把库搞坏的做法。交给下面原来的逻辑尽力而为。
            logger.warning("[Rootfs] repairMetaDB: 库被占用（rc=\(attempt.rc)），只等不动文件")
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(metaDBPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db else {
            logger.warning("[Rootfs] repairMetaDB: 打不开 meta.db")
            return false
        }
        defer { sqlite3_close(db) }

        // 失败自愈路径上，内核可能刚打开过这个库（boot 走到 mount 才失败），
        // 残留的锁会让这里的 DDL 直接报 SQLITE_BUSY。等一会儿比立刻放弃好。
        sqlite3_busy_timeout(db, 3000)

        var changed = false

        // 先读 user_version。它决定「要不要做全表 sweep」——
        // uv 已经是 4 说明内核迁移早跑完了，orphans 增量清理已经接管，
        // 没必要每次启动都扫一遍 stats（内核注释里量过：1.5M 行约 0.3s）。
        // 类型注意：sqlite3_column_int 返回 Int32，所以这里也用 Int32，
        // 别声明成 Int —— 直接赋值会报 cannot assign Int32 to Int。
        var uvBefore: Int32 = -1
        var uvStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &uvStmt, nil) == SQLITE_OK,
           let uvStmt {
            if sqlite3_step(uvStmt) == SQLITE_ROW {
                uvBefore = sqlite3_column_int(uvStmt, 0)
            }
            sqlite3_finalize(uvStmt)
        }

        // ── 1. 按 `fs/fake-migrate.c` 的 migrations[0..3] 构造终态 ──
        //
        // 逐条对应内核那四条迁移的**最终效果**（不是它们的 SQL 原文）：
        //   migrations[0] → 有 index inode_to_path
        //   migrations[1] → 有 index、paths_new 只是中转表（跑完已 rename 掉）
        //   migrations[2] → 建了 trigger 又删掉，终态是**没有** trigger
        //   migrations[3] → 有 orphans 表 + 一次全表 sweep
        //
        // 全部写成幂等形式，重复调用无副作用。
        var terminalSteps: [(label: String, sql: String)] = [
            ("drop trigger delete_path", "DROP TRIGGER IF EXISTS delete_path"),
            ("drop paths_new",           "DROP TABLE IF EXISTS paths_new"),
            ("drop paths_old",           "DROP TABLE IF EXISTS paths_old"),
            ("drop stats_old",           "DROP TABLE IF EXISTS stats_old"),
            ("index inode_to_path",
             "CREATE INDEX IF NOT EXISTS inode_to_path ON paths (inode, path)"),
            ("table orphans",
             "CREATE TABLE IF NOT EXISTS orphans (inode integer primary key)"),
        ]
        if uvBefore < 4 {
            // 只有真正从 v3 及更早升上来才需要这一次 sweep。
            terminalSteps.append(
                ("sweep orphan stats",
                 "DELETE FROM stats WHERE NOT EXISTS "
                 + "(SELECT 1 FROM paths WHERE inode = stats.inode)"))
        }
        var terminalOK = true
        for step in terminalSteps {
            if sqlite3_exec(db, step.sql, nil, nil, nil) != SQLITE_OK {
                terminalOK = false
                logger.error("[Rootfs] repairMetaDB: \(step.label) 失败 — "
                             + String(cString: sqlite3_errmsg(db)))
            }
        }

        // 推 uv 之前必须先确认三张核心表真的在了。
        //
        // 这里是本文件最危险的一处「自作聪明」：上面 DDL 失败只记日志、
        // 继续往下走，然后无条件 `PRAGMA user_version = 4`。一旦
        // `create table orphans` 因为锁/IO 失败，就正好造出
        //   uv=4 + orphans 不存在
        // —— 内核 `fakefs_migrate` 看 uv 已到 4 整段跳过，接着
        // `PREPARE_OR_FAIL(orphan_note, "insert or ignore into orphans ...")`
        // 撞 `no such table` → `goto init_fail` → **-5**。
        // 也就是「修库这一步亲手把库弄成必死」，而且每启动一次就再犯一次，
        // 除了重装 rootfs 没有出路 —— 和用户报的「重置只能管一次」同形。
        //
        // 所以改成「验证通过才推」。验证用 prepare 而不是 count(*)：
        // 只要表在、列在就够，不需要真的扫数据。
        func tableReady(_ sql: String) -> Bool {
            var s: OpaquePointer?
            let r = sqlite3_prepare_v2(db, sql, -1, &s, nil)
            if let s { sqlite3_finalize(s) }
            return r == SQLITE_OK
        }
        // 只查内核真正依赖的四张表，不查 `db_inode` 这类列 ——
        // 列由内核自己的迁移补，这里多要求一条反而可能把老库卡在 uv=3。
        let coreTablesReady = tableReady("select inode from paths where path = ?")
            && tableReady("select stat from stats where inode = ?")
            && tableReady("select inode from orphans")
            && tableReady("select count(*) from meta")
        if !coreTablesReady || !terminalOK {
            logger.error("[Rootfs] repairMetaDB: 核心表/迁移终态没做成"
                         + "（terminalOK=\(terminalOK) coreTables=\(coreTablesReady)）"
                         + " —— 不推 user_version，避免造出「uv=4 但缺表」的必死组合")
            return healed
        }

        // ── 2. 把 `user_version` 推到 4 ──
        //
        // ★ 这一步是整段的关键，绝不能省。
        //
        // 内核 `fakefs_migrate` 是 `while (version < 4) EXEC(migrations[version])`，
        // 其中 migrations[2] 是 `drop trigger delete_path`（无 if exists）、
        // migrations[3] 是 `create table orphans`（无 if not exists）。
        // 只要 uv 停在 3、而上面任何一项已经是目标状态，内核就会在
        // `EXEC` 宏里 die() —— iOS 上表现为界面永久卡「正在启用内核」。
        //
        // 1.78 就是漏了这一步：补了 orphans 但不升 uv，等于亲手造出
        // 「uv=3 + orphans 已存在」这个必死组合（已用真实 meta.db 复现）。
        //
        // 上面已经把这 4 条迁移的效果全做完了，所以这里推 uv 完全安全 ——
        // 推到 4 之后内核整段跳过，那些非幂等 DDL 一次都不执行。
        if uvBefore != 4 {
            if sqlite3_exec(db, "PRAGMA user_version = 4", nil, nil, nil) == SQLITE_OK {
                changed = true
                logger.warning("[Rootfs] repairMetaDB: user_version \(uvBefore) → 4"
                               + "（内核据此跳过那 4 条非幂等迁移）")
            } else {
                logger.error("[Rootfs] repairMetaDB: 写 user_version 失败 — "
                             + String(cString: sqlite3_errmsg(db)))
            }
        }

        // 把 db_inode 写成 meta.db 自己的 st_ino。
        //
        // 这里写的值在**解压之后**读，所以和内核 mount 时看到的 st_ino 一致 ——
        // 首启就不会再走 fakefs_rebuild 那条脆弱路径。
        //
        // 注意：进程重启后 st_ino 不会变（APFS 里 inode 号稳定，解压才变），
        // 所以这个值能一直有效，不是「只管一次」。
        //
        // 用 stat(2) 而不是 attributesOfItem：后者拿 [.systemFileNumber] 是走
        // FileAttributeKey → NSNumber → UInt64 的桥接，出错时静默得 0
        // （这个文件里 [.size] 已经踩过一次）。ino_t 是 C 类型，直接读最稳。
        var st = stat()
        if stat(metaDBPath, &st) == 0, st.st_ino != 0 {
            let sql = "UPDATE meta SET db_inode = \(st.st_ino)"
            if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
                logger.info("[Rootfs] repairMetaDB: db_inode → \(st.st_ino)")
                // 写成功也算「动过库」。残表可能本来就没有（真损坏的情形），
                // 那时也要让调用方重试一次 —— 万一就是 db_inode 造成的。
                changed = true
            } else {
                logger.warning("[Rootfs] repairMetaDB: 写 db_inode 失败")
            }
        }

        // 顺手确认修完之后库确实可读。
        //
        // 这里原来用 `PRAGMA integrity_check`，改成 `quick_check` 有两个原因：
        //   · 开销：integrity_check 会把每行和它的索引项逐条比对，
        //     5MB 的库要几百毫秒，而这段跑在**每次启动**的 boot 之前
        //   · 判据重复：物理结构在上面 `probeMetaDBReadable` 里已经查过了，
        //     这里只是复查「刚才那几条 DDL 没把库写坏」，quick_check 足够
        if let bad = quickCheckFailure(db) {
            logger.error("[Rootfs] repairMetaDB: 修完 quick_check 报 \(bad.text)")
        }

        // 把 WAL 落盘并清空。
        //
        // 目的是让「内核接下来看到的那份库」是一个没有待重放帧的确定状态：
        // 上面这些 DDL 都写进了 `-wal`，内核 mount 时要先做一次 WAL 恢复
        // 才轮得到 `PRAGMA journal_mode=wal` —— 而设备上炸的正是那一条。
        // 少一步恢复就少一个失败点。此刻内核一定没起来，独占是安全的。
        if sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil) == SQLITE_OK {
            logger.info("[Rootfs] repairMetaDB: WAL 已 checkpoint(TRUNCATE)")
        }

        logger.info("[Rootfs] repairMetaDB done (changed=\(changed) healed=\(healed))")
        return changed || healed
    }

    /// 内核 mount 返回 -5（-EIO）时，把「凭什么 -5」查清楚。
    ///
    /// [T-boot-minus5-diagnose] 两轮修复都因为「不知道 -5 具体从哪来」而打偏。
    /// `-5` 在 `fakefs_mount` 里有三条来源，必须能分开：
    ///
    ///   1. `realfs.mount()` —— host 的 `data/` 目录本身打不开
    ///      （`realpath` 或 `open(O_DIRECTORY)` 失败，errno=EIO）
    ///   2. `fake_db_init()` 的 `init_fail` —— meta.db 层面的 SQLite 错误
    ///   3. `mount_root` 里 `realpath(source)` 失败 —— 目录不存在
    ///
    /// `errno_map()` 里有 `ERRCASE(EIO)`，所以 host 层 errno=EIO 会原样变成 -5。
    ///
    /// 这三条的处理办法完全不同：1 和 3 只能重装 rootfs，2 才是修库。
    /// 之前一律按 2 修，所以用户一直看到同一个 -5。
    ///
    /// 返回值的最后一段是「结论 + 该怎么办」，直接进错误提示，
    /// 用户截图就能带回来，不用专门导日志。
    func diagnoseKernelMountFailure() -> String {
        let fm = FileManager.default
        var facts: [String] = []
        var verdict: String? = nil

        // ── 1. 目录本身（对应来源 1 和 3）──
        let dataPathStr = dataPath.path
        var isDir: ObjCBool = false
        let dataExists = fm.fileExists(atPath: dataPathStr, isDirectory: &isDir)

        if !dataExists {
            facts.append("data/ 不存在")
            verdict = "rootfs 目录没了 → 需要在下面「重置内核环境」重装"
        } else if !isDir.boolValue {
            facts.append("data/ 不是目录")
            verdict = "data/ 被换成了文件 → 需要重置重装"
        } else {
            // open(O_DIRECTORY) 能不能成 —— 这是 realfs.mount 的真实动作。
            // 注意内核对 errno 的处理：ENOENT 会变成 -2 而不是 -5，只有
            // 真正 EIO 才是 -5，所以这里把 errno 原样报出来。
            let fd = open(dataPathStr, O_RDONLY | O_DIRECTORY)
            if fd >= 0 {
                close(fd)
                facts.append("data/ 可打开")
            } else {
                let e = errno
                facts.append("data/ 打不开 errno=\(e)")
                verdict = "目录在但打不开（errno=\(e)）→ 重装"
            }
        }

        // ── 2. 磁盘空间 ──
        // 磁盘满是最能解释「改了多少版都一样」的原因：SQLite 写 WAL、
        // open(O_DIRECTORY) 都可能直接返回 EIO → -5。
        if let attrs = try? fm.attributesOfFileSystem(forPath: rootfsPath.path),
           let free = attrs[.systemFreeSize] as? NSNumber {
            let freeMB = free.int64Value / (1024 * 1024)
            facts.append("剩余 \(freeMB)MB")
            if freeMB < 200 && verdict == nil {
                verdict = "磁盘只剩 \(freeMB)MB → 先清空间"
            }
        }

        // 顺带把遗留的 .alpine-rootfs-broken-* 数量报出来 —— 每份约 145MB，
        // 累积几份就够把盘吃满。
        if let siblings = try? fm.contentsOfDirectory(atPath:
                rootfsPath.deletingLastPathComponent().path) {
            let stranded = siblings.filter { $0.hasPrefix(".alpine-rootfs-broken-") }
            if !stranded.isEmpty {
                facts.append("遗留旧 rootfs \(stranded.count)份")
                if verdict == nil {
                    verdict = "有 \(stranded.count) 份删不掉的旧 rootfs 占着盘 → 重装时会自动重试清理"
                }
            }
        }

        // ── 3. meta.db（对应来源 2）──
        let metaDBPath = rootfsPath.appendingPathComponent("meta.db").path
        if !fm.fileExists(atPath: metaDBPath) {
            facts.append("meta.db 不存在")
            if verdict == nil { verdict = "meta.db 没了 → 需要重置重装" }
        } else {
            // ★ 量文件、读头，全部在**打开之前**做。
            //
            // 打开这个库本身就会创建/删除 `-wal`、`-shm`，打开之后再量
            // 量到的是「诊断自己刚弄出来的东西」，不是原始现场。
            // 之前那一版就是在 probe 之后量的，所以永远显示
            // `-wal=0B -shm=32768B` —— 那两条其实是 `PRAGMA journal_mode=wal`
            // 现场建出来的，白白误导了两轮。
            var sidecarFacts: [String] = []
            for suffix in ["-wal", "-shm", "-journal"] {
                let p = metaDBPath + suffix
                if let sz = (try? fm.attributesOfItem(atPath: p))?[.size] as? NSNumber {
                    sidecarFacts.append("\(suffix)=\(sz.intValue)B")
                }
            }
            facts.append("伴生:" + (sidecarFacts.isEmpty ? "无" : sidecarFacts.joined(separator: ",")))
            facts.append(Self.metaDBHeaderSummary(metaDBPath))

            var db: OpaquePointer?
            let rc = sqlite3_open_v2(metaDBPath, &db, SQLITE_OPEN_READWRITE, nil)
            if rc != SQLITE_OK || db == nil {
                facts.append("meta.db 打不开 rc=\(rc)")
                if verdict == nil { verdict = "meta.db 打不开 → 需要重置重装" }
                if let db { sqlite3_close(db) }
            } else if let db {
                sqlite3_busy_timeout(db, 3000)
                defer { sqlite3_close(db) }

                // 把内核 init 会做的事按顺序做一遍，谁先炸就是谁。
                // 这是唯一能确定 init_fail 具体落在哪一条的办法。
                //
                // ★ 只 prepare，**不 step**。
                // 这四条里有两条是写操作（`DELETE FROM orphans` / orphan-sweep），
                // 一条会改持久化状态（`PRAGMA journal_mode=wal`）。
                // 早先的版本对它们 `sqlite3_step()` 了，等于「诊断的时候
                // 顺手把用户的库改一遍」—— 诊断绝不能有副作用，
                // 尤其是库本来就坏着的时候，谁也不知道这一 step 会写坏什么。
                // 内核那 17 条也是 `sqlite3_prepare_v2` 就判失败，
                // 所以只看 prepare 的 rc 与内核的判据完全一致。
                var fileLevelBad = false
                func probe(_ label: String, _ sql: String, fatal: Bool = true) {
                    var stmt: OpaquePointer?
                    let r = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
                    if let stmt { sqlite3_finalize(stmt) }
                    if Self.isFileLevelCorruption(r) { fileLevelBad = true }
                    guard r == SQLITE_OK else {
                        facts.append("\(label):prepare rc=\(r)")
                        if fatal && verdict == nil {
                            verdict = "内核卡在「\(label)」→ 修库"
                        }
                        return
                    }
                }

                // 前两条是硬 pragma（失败直接 init_fail，返回 -5）
                probe("wal", "PRAGMA journal_mode=wal")
                probe("foreign_keys", "PRAGMA foreign_keys=true")

                // 迁移后无条件执行的两条（失败也是 init_fail）
                probe("orphan-sweep",
                      "DELETE FROM stats WHERE inode IN (SELECT inode FROM orphans) "
                      + "AND NOT EXISTS (SELECT 1 FROM paths WHERE inode = stats.inode)")
                probe("orphan-clear", "DELETE FROM orphans")

                // ★ 物理结构：坏在哪一页、怎么坏的，只有 quick_check 说得清。
                // 上一条设备报告只给了「wal:prepare rc=11 + 核心表缺失」，
                // 这三个字不足以区分「表被删」和「页被清零」，只能靠猜。
                if let bad = quickCheckFailure(db) {
                    fileLevelBad = true
                    facts.append("quick_check:\(String(bad.text.prefix(160)))")
                    if verdict == nil {
                        verdict = "meta.db 物理损坏（见 quick_check）→ 下次启动会自动从包内还原，用户数据不动"
                    }
                } else {
                    facts.append("quick_check:ok")
                }

                // 状态快照
                var tables: [String] = []
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'",
                                      -1, &stmt, nil) == SQLITE_OK, let stmt {
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        if let c = sqlite3_column_text(stmt, 0) {
                            tables.append(String(cString: c))
                        }
                    }
                    sqlite3_finalize(stmt)
                } else {
                    if Self.isFileLevelCorruption(sqlite3_errcode(db)) { fileLevelBad = true }
                    facts.append("sqlite_master 读不出来")
                }
                let tblSet = Set(tables)
                facts.append("表:\(tables.sorted().joined(separator: ","))")

                // 四张表各有多少行 —— 真读一遍数据页。
                // 「prepare 过了但 step 炸」这种坏法，只有这一条能抓住。
                var rowCounts: [String] = []
                for t in ["meta", "paths", "stats", "orphans"] where tblSet.contains(t) {
                    var cs: OpaquePointer?
                    guard sqlite3_prepare_v2(db, "SELECT count(*) FROM \(t)", -1, &cs, nil)
                            == SQLITE_OK, let cs else {
                        rowCounts.append("\(t)=?")
                        continue
                    }
                    let sr = sqlite3_step(cs)
                    rowCounts.append(sr == SQLITE_ROW
                                     ? "\(t)=\(sqlite3_column_int(cs, 0))"
                                     : "\(t)=r\(sr)")
                    if Self.isFileLevelCorruption(sr) { fileLevelBad = true }
                    sqlite3_finalize(cs)
                }
                if !rowCounts.isEmpty {
                    facts.append("行数:" + rowCounts.joined(separator: ","))
                }

                // 同 repairMetaDBIfNeeded：sqlite3_column_int 返回 Int32
                var uv: Int32 = -1
                var uvStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &uvStmt, nil) == SQLITE_OK,
                   let uvStmt {
                    if sqlite3_step(uvStmt) == SQLITE_ROW {
                        uv = sqlite3_column_int(uvStmt, 0)
                    }
                    sqlite3_finalize(uvStmt)
                }
                facts.append("uv=\(uv)")

                // 结构性缺件：这些是内核 init 里硬依赖的
                if !tblSet.contains("orphans") {
                    if verdict == nil { verdict = "缺 orphans 表 → 修库" }
                }
                if !tblSet.contains("paths") || !tblSet.contains("stats") {
                    facts.append("核心表缺失")
                    // 「表被删了」和「整个文件读不出来」在界面上看起来一样，
                    // 但 1.86 起两者的处置**已经统一**：都不需要重装。
                    // 缺表 → 换一份包里的 db + 重扫 data/ 补登记；
                    // 读不出来 → 同上。用户数据（data/）全程一个字节不动。
                    // 所以这里别再把人往「重置内核环境」上赶 ——
                    // 那条路会删掉整棵 145MB 的树，代价大得多。
                    if verdict == nil {
                        verdict = fileLevelBad
                            ? "meta.db 物理损坏 → 下次启动会自动从包内还原这份 db，用户数据不动，**不用点重置**"
                            : "核心表缺失 → 下次启动会自动从包内还原这份 db 并重扫 data/ 补登记，用户数据不动，**不用点重置**"
                    }
                }
                // 库读不出来但表名还列得出来（schema 在、数据页烂）
                if verdict == nil, fileLevelBad {
                    verdict = "meta.db 读不出来 → 下次启动会自动从包内还原，用户数据不动，**不用点重置**"
                }
            }
        }

        var out = facts.joined(separator: " · ")
        if let verdict {
            out += "\n→ " + verdict
        } else {
            out += "\n→ 各项自检都过，-5 可能来自 fakefs_rebuild 期间的瞬时错误"
        }
        logger.error("[Rootfs] -5 诊断: \(out)")
        return out
    }

    /// Reset (delete) the rootfs, forcing a fresh install on next launch
    /// - Parameter keepUserData: If true, backs up /root directory before deletion
    /// - Returns: URL of backup directory if keepUserData was true, nil otherwise
    @discardableResult
    func reset(keepUserData: Bool = false) throws -> URL? {
        logger.warning("[Rootfs] reset requested — deleting \(rootfsPath.path)")

        var backupURL: URL?

        if keepUserData {
            // Backup /root directory
            let userDataPath = dataPath.appendingPathComponent("root")
            if FileManager.default.fileExists(atPath: userDataPath.path) {
                let backupPath = FileManager.default.temporaryDirectory
                    .appendingPathComponent("rootfs-backup-\(Date().timeIntervalSince1970)")
                    .appendingPathComponent("root")

                try FileManager.default.createDirectory(
                    at: backupPath.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                try FileManager.default.copyItem(at: userDataPath, to: backupPath)
                backupURL = backupPath
                logger.info("[Rootfs] user data backed up to \(backupPath.path)")
            }
        }

        // Delete rootfs. Uses the same move-aside fallback as installIfNeeded:
        // a reset exists precisely to recover from a broken rootfs, so it must
        // not be the one operation that a broken rootfs can block.
        if FileManager.default.fileExists(atPath: rootfsPath.path) {
            try discardOldRootfs()
            logger.warning("[Rootfs] rootfs removed from \(rootfsPath.path)")
        }

        // 内核已 boot 但树被删掉的保护，现在由 `discardOldRootfs()` 统一处理
        // （[T-reset-keeps-userdata]）——它在删之前置 `didResetWhileBooted`。
        // 这里不再重复，免得两处各写一遍、以后新增调用方时漏掉。

        logger.info("[Rootfs] reset complete — installIfNeeded() will reinstall")

        return backupURL
    }

    /// Restore user data from a backup
    /// - Parameter backupURL: URL of backup created by reset(keepUserData: true)
    func restoreUserData(from backupURL: URL) throws {
        guard isInstalled else {
            throw NSError(
                domain: "RootfsManager",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Rootfs not installed. Run installIfNeeded() first."]
            )
        }

        let userDataPath = dataPath.appendingPathComponent("root")

        // Remove existing /root directory
        if FileManager.default.fileExists(atPath: userDataPath.path) {
            try FileManager.default.removeItem(at: userDataPath)
        }

        // Copy backup to rootfs
        try FileManager.default.copyItem(at: backupURL, to: userDataPath)

        logger.info("[Rootfs] user data restored from \(backupURL.path)")
    }

    /// Overlay default configuration files from the bundle onto the rootfs.
    /// Runs on every boot so app updates with new defaults take effect.
    func applyDefaultMountOverlay() {
        let totalStart = CFAbsoluteTimeGetCurrent()
        logger.info("[DefaultMount] applyDefaultMountOverlay() called")

        guard let overlayURL = Bundle.main.url(forResource: "default_mount", withExtension: nil) else {
            logger.info("[DefaultMount] No default_mount found in bundle")
            return
        }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: overlayURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return
        }

        var fileCount = 0
        var copyTotalMs: Double = 0
        var metaDbTotalMs: Double = 0
        while let fileURL = enumerator.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }

            // relativePath e.g. "/etc/pip/pip.conf"
            let relativePath = fileURL.path.replacingOccurrences(of: overlayURL.path, with: "")
            let destURL = dataPath.appendingPathComponent(relativePath)

            do {
                let copyStart = CFAbsoluteTimeGetCurrent()
                try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try fm.copyItem(at: fileURL, to: destURL)
                copyTotalMs += (CFAbsoluteTimeGetCurrent() - copyStart) * 1000
                fileCount += 1

                // Determine the fakefs mode. iOS strips POSIX execute bits
                // from some bundle resources during install, so reading
                // `attributesOfItem` is unreliable for the +x case. Fall
                // back to a path-based heuristic: anything shipped under
                // a standard *bin directory is forced to 0755 so scripts
                // like /usr/local/bin/minis-open are always executable.
                var posixMode: UInt16 = 0o644
                if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                   let num = attrs[.posixPermissions] as? NSNumber {
                    posixMode = num.uint16Value
                }
                let binDirs = ["/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/local/bin/", "/usr/local/sbin/"]
                if binDirs.contains(where: { relativePath.hasPrefix($0) }) {
                    posixMode = 0o755
                }
                // [T-mcp-cli-help-and-readonly-ios] The bundled minis-mcp-cli
                // Python lib is app-managed and shipped read-only so users
                // cannot tamper with it from inside iSH (e.g. `vi`). Register
                // these regular files as 0o444 (read-only) — iSH's access_check
                // then rejects writes in-guest. The host copy is unaffected, so
                // the every-boot overwrite still updates them on app upgrade.
                // Scoped to this lib subtree ONLY; the sh wrapper under
                // /usr/local/bin/ stays 0o755 (handled by binDirs above).
                if relativePath.hasPrefix(Self.mcpCliLibPrefix) {
                    posixMode = 0o444
                }
                let fakefsMode: UInt32 = 0o100000 | UInt32(posixMode)

                // Register in fakefs meta.db so iSH kernel can see the file
                let metaStart = CFAbsoluteTimeGetCurrent()
                ensureParentDirsInMetaDB(for: relativePath)
                ensureFakefsMetadata(for: relativePath, isDirectory: false, mode: fakefsMode)
                metaDbTotalMs += (CFAbsoluteTimeGetCurrent() - metaStart) * 1000
            } catch {
                logger.error("[DefaultMount] ERROR \(relativePath): \(error)")
            }
        }

        // [T-mcp-cli-help-and-readonly-ios] The per-file loop above stamped the
        // minis-mcp-cli lib FILES read-only (0o444), but ensureParentDirsInMetaDB
        // creates the containing directories with the default writable mode
        // (0o040755) — which would still let the guest create/delete files
        // inside them. Re-register the lib directories as 0o555 (read+execute,
        // no write) so the whole subtree is read-only to the guest. Idempotent:
        // ensureFakefsMetadata updates the stat row in place each boot.
        for dir in [Self.mcpCliLibDir, "\(Self.mcpCliLibDir)/transport", "\(Self.mcpCliLibDir)/utils"] {
            ensureFakefsMetadata(for: dir, isDirectory: true, mode: 0o040555)
        }

        // Remove PEP 668 EXTERNALLY-MANAGED marker so pip install works without
        // --break-system-packages. Safe in this embedded Alpine rootfs.
        let markerStart = CFAbsoluteTimeGetCurrent()
        removeExternallyManagedMarker()
        let markerMs = (CFAbsoluteTimeGetCurrent() - markerStart) * 1000

        let totalMs = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
        let avgCopyMs = fileCount > 0 ? copyTotalMs / Double(fileCount) : 0
        let avgMetaMs = fileCount > 0 ? metaDbTotalMs / Double(fileCount) : 0
        logger.info("[DefaultMount] Done. \(fileCount) file(s) overlaid in \(String(format: "%.1f", totalMs))ms — copy: \(String(format: "%.1f", copyTotalMs))ms (avg \(String(format: "%.2f", avgCopyMs))ms/file), metaDB: \(String(format: "%.1f", metaDbTotalMs))ms (avg \(String(format: "%.2f", avgMetaMs))ms/file), marker: \(String(format: "%.1f", markerMs))ms")
    }

    /// [T-aojit-restore] Copy the regular files of a bundle directory into the
    /// rootfs at `linuxDir` and register them in meta.db, the way
    /// applyDefaultMountOverlay does, so the guest can read them. Unlike the
    /// overlay this runs on demand, and the caller removes the files again
    /// from inside the guest (rm keeps meta.db in step).
    func stageFiles(from dir: URL, toLinuxDir linuxDir: String) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: dir.path) {
            let src = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let relativePath = "\(linuxDir)/\(name)"
            let dest = dataPath.appendingPathComponent(String(relativePath.dropFirst()))
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
            ensureParentDirsInMetaDB(for: relativePath)
            ensureFakefsMetadata(for: relativePath, isDirectory: false, mode: 0o100644)
        }
    }

    /// Remove the PEP 668 EXTERNALLY-MANAGED marker file from all Python versions.
    private func removeExternallyManagedMarker() {
        let fm = FileManager.default
        let usrLib = dataPath.appendingPathComponent("usr/lib")
        guard let contents = try? fm.contentsOfDirectory(atPath: usrLib.path) else { return }
        for entry in contents where entry.hasPrefix("python3") {
            let marker = usrLib.appendingPathComponent(entry).appendingPathComponent("EXTERNALLY-MANAGED")
            if fm.fileExists(atPath: marker.path) {
                try? fm.removeItem(at: marker)
                logger.info("[DefaultMount] removed EXTERNALLY-MANAGED from \(entry)")
            }
        }
    }

    // MARK: - Fakefs meta.db helpers

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindPathBlob(_ stmt: OpaquePointer, index: Int32, path: String) {
        let utf8 = Array(path.utf8)
        sqlite3_bind_blob(stmt, index, utf8, Int32(utf8.count), Self.SQLITE_TRANSIENT)
    }

    func ensureFakefsMetadata(for linuxPath: String, isDirectory: Bool, mode: UInt32? = nil) {
        let metaDBPath = rootfsPath.appendingPathComponent("meta.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(metaDBPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db else { return }
        defer { sqlite3_close(db) }

        // [T-meta-sidecar-heal] mode / rdev 从真文件读，别再写死。
        //
        // 原来这里是 `mode ?? (isDirectory ? 040755 : 0100644)`：只要是
        // 「恢复/登记一个已存在的文件」，权限一律被写成 0644 ——
        // 用户 `~` 下的脚本**全部丢掉可执行位**，`chmod +x` 过的安装脚本
        // 变成普通文本，`bash foo.sh` 报 Permission denied。
        // 设备路径 rdev 被写成 0 也一样：`/dev/null` 会变成普通文件。
        //
        // `struct ish_stat` 就 4 个 uint32（mode/uid/gid/rdev），
        // 文件大小和 mtime 不在这里 —— fakefs 每次 `fstatat` 真文件去取。
        var statBytes: [UInt8] = Array(repeating: 0, count: 16)
        var effectiveMode: UInt32 = mode ?? (isDirectory ? 0o040755 : 0o100644)
        var effectiveRdev: UInt32 = 0
        if mode == nil {
            let hostPath = dataPath.appendingPathComponent(
                linuxPath.hasPrefix("/") ? String(linuxPath.dropFirst()) : linuxPath).path
            var st = stat()
            // lstat：同上 — 符号链接要保留成链接，不能被跟随掉。
            if lstat(hostPath, &st) == 0 {
                // 高 4 位是文件类型（S_IFREG/S_IFDIR/S_IFCHR...），必须保留。
                effectiveMode = UInt32(st.st_mode) & 0o177777
                let typeBits = UInt32(st.st_mode) & 0o170000
                if typeBits == 0o020000 || typeBits == 0o060000 {
                    effectiveRdev = UInt32(truncatingIfNeeded: st.st_rdev)
                }
            }
        }
        for (i, value) in [effectiveMode, UInt32(0), UInt32(0), effectiveRdev].enumerated() {
            let le = value.littleEndian
            withUnsafeBytes(of: le) { src in
                for b in 0..<4 { statBytes[i * 4 + b] = src[b] }
            }
        }

        // If the path already exists, update its stat row in place so we can
        // refresh mode bits (e.g. when a newer app version ships an updated
        // default_mount file with different permissions).
        var checkStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT inode FROM paths WHERE path = ?", -1, &checkStmt, nil) == SQLITE_OK,
              let checkStmt else { return }
        defer { sqlite3_finalize(checkStmt) }

        bindPathBlob(checkStmt, index: 1, path: linuxPath)
        if sqlite3_step(checkStmt) == SQLITE_ROW {
            let existingInode = sqlite3_column_int64(checkStmt, 0)
            var updateStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE stats SET stat = ? WHERE inode = ?", -1, &updateStmt, nil) == SQLITE_OK,
                  let updateStmt else { return }
            defer { sqlite3_finalize(updateStmt) }
            sqlite3_bind_blob(updateStmt, 1, statBytes, Int32(statBytes.count), Self.SQLITE_TRANSIENT)
            sqlite3_bind_int64(updateStmt, 2, existingInode)
            sqlite3_step(updateStmt)
            return
        }

        var insertStatStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO stats (stat) VALUES (?)", -1, &insertStatStmt, nil) == SQLITE_OK,
              let insertStatStmt else { return }
        defer { sqlite3_finalize(insertStatStmt) }

        sqlite3_bind_blob(insertStatStmt, 1, statBytes, Int32(statBytes.count), Self.SQLITE_TRANSIENT)
        guard sqlite3_step(insertStatStmt) == SQLITE_DONE else { return }

        var insertPathStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO paths (path, inode) VALUES (?, last_insert_rowid())", -1, &insertPathStmt, nil) == SQLITE_OK,
              let insertPathStmt else { return }
        defer { sqlite3_finalize(insertPathStmt) }

        bindPathBlob(insertPathStmt, index: 1, path: linuxPath)
        sqlite3_step(insertPathStmt)
    }

    func ensureParentDirsInMetaDB(for linuxPath: String) {
        var current = (linuxPath as NSString).deletingLastPathComponent
        var dirs: [String] = []
        while current != "/" && !current.isEmpty {
            dirs.append(current)
            current = (current as NSString).deletingLastPathComponent
        }
        for dir in dirs.reversed() {
            ensureFakefsMetadata(for: dir, isDirectory: true)
        }
    }

    /// Remove a path (and, if it's a directory subtree, all of its descendants)
    /// from fakefs `meta.db`. Also drops orphaned `stats` rows. Safe to call on
    /// paths that don't exist in meta.db (it's a no-op in that case).
    func removeFakefsPath(_ linuxPath: String) {
        let metaDBPath = rootfsPath.appendingPathComponent("meta.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(metaDBPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db else { return }
        defer { sqlite3_close(db) }

        // Collect inodes of rows that will be deleted so we can drop their
        // stat rows too (meta.db has no FK cascade).
        var inodes: [Int64] = []
        let prefix = linuxPath.hasSuffix("/") ? linuxPath : linuxPath + "/"
        var selectStmt: OpaquePointer?
        if sqlite3_prepare_v2(db,
            "SELECT inode FROM paths WHERE path = ? OR substr(path, 1, ?) = ?",
            -1, &selectStmt, nil) == SQLITE_OK, let selectStmt {
            bindPathBlob(selectStmt, index: 1, path: linuxPath)
            sqlite3_bind_int(selectStmt, 2, Int32(Array(prefix.utf8).count))
            bindPathBlob(selectStmt, index: 3, path: prefix)
            while sqlite3_step(selectStmt) == SQLITE_ROW {
                inodes.append(sqlite3_column_int64(selectStmt, 0))
            }
            sqlite3_finalize(selectStmt)
        }
        if inodes.isEmpty { return }

        var deletePathsStmt: OpaquePointer?
        if sqlite3_prepare_v2(db,
            "DELETE FROM paths WHERE path = ? OR substr(path, 1, ?) = ?",
            -1, &deletePathsStmt, nil) == SQLITE_OK, let deletePathsStmt {
            bindPathBlob(deletePathsStmt, index: 1, path: linuxPath)
            sqlite3_bind_int(deletePathsStmt, 2, Int32(Array(prefix.utf8).count))
            bindPathBlob(deletePathsStmt, index: 3, path: prefix)
            sqlite3_step(deletePathsStmt)
            sqlite3_finalize(deletePathsStmt)
        }

        var deleteStatsStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM stats WHERE inode = ?", -1, &deleteStatsStmt, nil) == SQLITE_OK,
           let deleteStatsStmt {
            for inode in inodes {
                sqlite3_reset(deleteStatsStmt)
                sqlite3_bind_int64(deleteStatsStmt, 1, inode)
                sqlite3_step(deleteStatsStmt)
            }
            sqlite3_finalize(deleteStatsStmt)
        }
    }

    /// Register every existing file/directory under `hostRoot` into `meta.db`,
    /// using Linux paths relative to `dataPath`. Used after copying a directory
    /// subtree from the host filesystem (e.g. FileBrowser import/copy/move)
    /// so that the iSH kernel can see the new entries.
    func registerSubtreeInMetaDB(hostRoot: URL) {
        let fm = FileManager.default
        let dataPrefix = dataPath.standardized.path
        let rootStd = hostRoot.standardized.path
        guard rootStd == dataPrefix || rootStd.hasPrefix(dataPrefix + "/") else { return }

        func linuxPath(for hostPath: String) -> String? {
            if hostPath == dataPrefix { return "/" }
            guard hostPath.hasPrefix(dataPrefix + "/") else { return nil }
            return String(hostPath.dropFirst(dataPrefix.count))
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: rootStd, isDirectory: &isDir) else { return }
        guard let rootLinux = linuxPath(for: rootStd) else { return }

        ensureParentDirsInMetaDB(for: rootLinux)
        ensureFakefsMetadata(for: rootLinux, isDirectory: isDir.boolValue)
        guard isDir.boolValue else { return }

        var stack: [URL] = [URL(fileURLWithPath: rootStd)]
        while let dir = stack.popLast() {
            guard let children = try? fm.contentsOfDirectory(at: dir,
                                                             includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: []) else { continue }
            for child in children {
                let childStd = child.standardized.path
                guard let childLinux = linuxPath(for: childStd) else { continue }
                var childIsDir: ObjCBool = false
                fm.fileExists(atPath: childStd, isDirectory: &childIsDir)
                ensureFakefsMetadata(for: childLinux, isDirectory: childIsDir.boolValue)
                if childIsDir.boolValue {
                    stack.append(URL(fileURLWithPath: childStd))
                }
            }
        }
    }

    /// Get the size of the rootfs installation
    /// - Returns: Size in bytes
    func getRootfsSize() throws -> Int64 {
        guard FileManager.default.fileExists(atPath: rootfsPath.path) else { return 0 }

        var totalSize: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: rootfsPath, includingPropertiesForKeys: [.fileSizeKey])

        while let fileURL = enumerator?.nextObject() as? URL {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let fileSize = attributes[.size] as? Int64 {
                totalSize += fileSize
            }
        }

        return totalSize
    }

    private func unzipFile(at sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default

        guard let archive = ZIPArchive(url: sourceURL) else {
            throw NSError(
                domain: "RootfsManager",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to open zip archive"]
            )
        }

        // Find common prefix to strip (e.g., "alpine-rootfs/")
        let prefix = "alpine-rootfs/"

        for entry in archive.entries {
            var relativePath = entry.path

            // Strip the common prefix if present
            if relativePath.hasPrefix(prefix) {
                relativePath = String(relativePath.dropFirst(prefix.count))
            }

            // Skip empty paths (the root directory itself)
            guard !relativePath.isEmpty else { continue }

            let entryPath = destinationURL.appendingPathComponent(relativePath)

            // Create parent directories if needed
            let parentDir = entryPath.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDir.path) {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            // Extract entry
            if entry.isDirectory {
                try fileManager.createDirectory(at: entryPath, withIntermediateDirectories: true)
            } else {
                // [R58-大文件流式解压] 预装工具链后 rootfs 里有单个 132MB 的
                // libLLVM.so.18.1，而这里原来是「整个文件读进内存再写盘」。
                // 132MB 的 Data + 132MB 的解压目标缓冲同时驻留，在手机上是
                // 直接把自己送进 jetsam 的量级 —— 解压途中被系统杀掉，
                // rootfs 处于半装状态，arch tag 又没写，下次启动重来一遍。
                //
                // 改成按块解压：内存里同时只有一块，文件多大都不影响峰值。
                try extractEntryStreaming(entry, from: archive, to: entryPath)
            }
        }
    }

    /// 把一个 zip entry 流式解压到磁盘。
    ///
    /// 与 `ZIPArchive.extractData(for:)` 的区别只在这里不构造完整 Data：
    ///   · 未压缩（method 0）—— 直接把压缩流当原文按块抄写；
    ///   · deflate（method 8）—— 用 `compression_stream` 一块一块解。
    ///
    /// 为什么不用 `compression_decode_buffer`（原来那个）：
    /// 它要求目标缓冲一次性开到 `expectedSize` 那么大，等于又把整个文件
    /// 摆回了内存里。`compression_stream` 是增量的，块大小我们自己定。
    ///
    /// [R58-fix] 参数类型必须写全限定名 `ZIPArchive.Entry`：
    /// `Entry` 是嵌套在 `ZIPArchive` 里的类型，而本函数属于 `RootfsManager`
    /// （定义在 `ZIPArchive` 之前）。裸写 `Entry` 在 `RootfsManager` 作用域里
    /// 是找不到的 —— 上一版就是这样，CI 报
    ///   error: cannot find type 'Entry' in scope
    private func extractEntryStreaming(_ entry: ZIPArchive.Entry,
                                       from archive: ZIPArchive,
                                       to destination: URL) throws {
        let fm = FileManager.default

        // 先确保文件存在（上一步建目录时不会建文件），再拿写句柄。
        // 分两步是因为 `FileHandle(forWritingAtPath:)` 不创建文件。
        if !fm.fileExists(atPath: destination.path) {
            fm.createFile(atPath: destination.path, contents: nil)
        }
        guard let out = FileHandle(forWritingAtPath: destination.path) else {
            throw NSError(domain: "RootfsManager", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "创建文件失败：\(destination.lastPathComponent)"
            ])
        }

        // [T-meta-sidecar-heal] 先把长度截成 0 再写。
        //
        // `FileHandle(forWritingAtPath:)` 是**从偏移 0 覆写、不截断**：
        // 如果目标文件本来比要写的内容长，尾部那段旧字节会原样留下来。
        // 对一个普通 .so 来说这是「尾部多几 KB 垃圾」，而对 `meta.db`
        // 来说就是「SQLite 头说 284 页、文件却有 285 页」——
        // 下一步 `sqlite3_open` 直接 SQLITE_CORRUPT(11)，
        // 内核 `fake_db_init` 拿它挂载失败，用户看到的就是 `-5`。
        //
        // 正常路径上目标文件是不存在的（先整棵删树再解压），所以这条
        // 截断平时什么都不做；它的作用是堵住「目标已存在」这条边路。
        try? out.truncate(atOffset: 0)

        // 写入失败时要删掉半截文件再抛错。
        // 不删的话 rootfs 里会留一个大小不对的 .so / 可执行文件 ——
        // 那种文件不报错、只是运行时段错误，比直接失败难查得多。
        do {
            try archive.streamEntry(entry) { chunk in
                try out.write(contentsOf: chunk)
            }
        } catch {
            try? out.close()
            try? fm.removeItem(at: destination)
            throw error
        }
        try? out.close()

        // 权限放在关闭之后设：文件句柄还开着时改权限，
        // 某些文件系统上会被随后的 flush 覆盖回去。
        if (entry.unixMode & 0o111) != 0 {
            try? fm.setAttributes([.posixPermissions: entry.unixMode & 0o777],
                                  ofItemAtPath: destination.path)
        }
    }
}

// [R58-大文件流式解压] 流式解压过程中的错误。
//
// 单独定义而不是复用 NSError：这些错误的文案会直接进日志，
// 带上具体的方法号 / 状态码，下次真出问题时能一眼看出是哪一步。
private enum ZIPStreamError: LocalizedError {
    /// 本地文件头长度不足 —— zip 文件被截断或不是 zip
    case badHeader
    /// 压缩方法不是 stored(0) 也不是 deflate(8)
    case unsupportedMethod(UInt16)
    /// compression_stream_init 失败
    case streamInit(Int32)
    /// compression_stream_process 返回了错误
    case decodeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .badHeader:
            return "zip 本地文件头损坏"
        case .unsupportedMethod(let m):
            return "不支持的压缩方法 \(m)"
        case .streamInit(let s):
            return "解压流初始化失败（status=\(s)）"
        case .decodeFailed(let s):
            return "解压失败（status=\(s)）"
        }
    }
}

// Minimal ZIP archive reader with safe unaligned memory access
private class ZIPArchive {
    /// Own logger: this is a separate type from RootfsManager, and its failures
    /// (a corrupt archive, an unsupported compression method) are exactly the
    /// kind that must survive in the daily log file rather than vanishing into
    /// a print() the way the rootfs lifecycle messages used to.
    private let logger = AppLogger(category: "RootfsZIP")

    struct Entry {
        let path: String
        let isDirectory: Bool
        let compressedSize: Int
        let uncompressedSize: Int
        let compressionMethod: UInt16
        let localHeaderOffset: UInt64
        /// [R58-大文件流式解压] zip 里记录的文件模式位。
        ///
        /// 预装工具链后 rootfs 里带 `bin/ldid`、`bin/clang` 这些可执行文件，
        /// 靠它还原执行位。取 external attributes 的高 16 位 —— 这是 zip 的
        /// UNIX 扩展约定（低 16 位是 DOS 属性，那边没有权限概念）。
        /// 拿不到时按 0644 处理，宁可少个执行位也不要造出 0777。
        var unixMode: Int = 0o644
    }

    private let fileHandle: FileHandle
    private(set) var entries: [Entry] = []

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.fileHandle = handle

        do {
            try parseZipFile()
        } catch {
            logger.error("[RootfsZIP] parse error: \(error)")
            return nil
        }
    }

    deinit {
        try? fileHandle.close()
    }

    // Safe unaligned read helpers
    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        return UInt32(data[offset]) |
               (UInt32(data[offset + 1]) << 8) |
               (UInt32(data[offset + 2]) << 16) |
               (UInt32(data[offset + 3]) << 24)
    }

    private func parseZipFile() throws {
        fileHandle.seekToEndOfFile()
        let fileSize = fileHandle.offsetInFile

        // Search for End of Central Directory
        let searchSize: UInt64 = Swift.min(fileSize, 65557)
        fileHandle.seek(toFileOffset: fileSize - searchSize)
        let searchData = fileHandle.readDataToEndOfFile()

        guard let eocdOffset = findEOCD(in: searchData) else {
            throw NSError(domain: "ZIPArchive", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid ZIP"])
        }

        let eocdStart = Int(fileSize - searchSize) + eocdOffset

        fileHandle.seek(toFileOffset: UInt64(eocdStart))
        let eocdData = fileHandle.readData(ofLength: 22)
        guard eocdData.count == 22 else { throw NSError(domain: "ZIPArchive", code: 2, userInfo: nil) }

        let centralDirOffset = readUInt32(eocdData, at: 16)
        let entryCount = readUInt16(eocdData, at: 10)

        fileHandle.seek(toFileOffset: UInt64(centralDirOffset))

        for _ in 0..<entryCount {
            guard let entry = readCentralDirectoryEntry() else { break }
            entries.append(entry)
        }
    }

    private func findEOCD(in data: Data) -> Int? {
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        for i in stride(from: data.count - 22, through: 0, by: -1) {
            if data[i] == signature[0] && data[i+1] == signature[1] &&
               data[i+2] == signature[2] && data[i+3] == signature[3] {
                return i
            }
        }
        return nil
    }

    private func readCentralDirectoryEntry() -> Entry? {
        let headerData = fileHandle.readData(ofLength: 46)
        guard headerData.count == 46 else { return nil }

        let sig = readUInt32(headerData, at: 0)
        guard sig == 0x02014B50 else { return nil }

        let compressionMethod = readUInt16(headerData, at: 10)
        let compressedSize = readUInt32(headerData, at: 20)
        let uncompressedSize = readUInt32(headerData, at: 24)
        let fileNameLength = readUInt16(headerData, at: 28)
        let extraLength = readUInt16(headerData, at: 30)
        let commentLength = readUInt16(headerData, at: 32)
        let localHeaderOffset = readUInt32(headerData, at: 42)

        // [R58-大文件流式解压] external attributes 在偏移 38，高 16 位是
        // UNIX 模式位（含文件类型 + 权限）。同一条记录里低 16 位是 DOS 属性，
        // 那边没有权限概念，所以只取高 16 位。
        // 数据全为 0（部分打包器不写）时退回 0644，不当成 0000 ——
        // 0000 会让文件谁都读不了，等于把 rootfs 弄坏。
        let externalAttrs = readUInt32(headerData, at: 38)
        let rawMode = Int((externalAttrs >> 16) & 0xFFFF)
        let unixMode = (rawMode & 0o777) == 0 ? Int(0o644) : (rawMode & 0o777)

        let fileNameData = fileHandle.readData(ofLength: Int(fileNameLength))
        let fileName = String(data: fileNameData, encoding: .utf8) ?? ""

        fileHandle.seek(toFileOffset: fileHandle.offsetInFile + UInt64(extraLength + commentLength))

        return Entry(
            path: fileName,
            isDirectory: fileName.hasSuffix("/"),
            compressedSize: Int(compressedSize),
            uncompressedSize: Int(uncompressedSize),
            compressionMethod: compressionMethod,
            localHeaderOffset: UInt64(localHeaderOffset),
            unixMode: unixMode
        )
    }

    /// [R58-大文件流式解压] 按块把 entry 的内容喂给调用方。
    ///
    /// 这是 `extractData(for:)` 的增量版本，用来替代「整个文件进内存」。
    /// 之所以单独写一个而不是改 `extractData`：后者还有别的调用点
    /// （读 meta.db 这类小文件），改成流式会让那些地方变复杂。
    ///
    /// 分两条路：
    ///   · method 0（stored）—— zip 里存的就是原文，直接按块抄；
    ///   · method 8（deflate）—— `compression_stream` 增量解，
    ///     输出块大小固定 256KB，峰值内存与文件大小无关。
    func streamEntry(_ entry: Entry, sink: (Data) throws -> Void) throws {
        fileHandle.seek(toFileOffset: entry.localHeaderOffset)

        let localHeader = fileHandle.readData(ofLength: 30)
        guard localHeader.count == 30 else { throw ZIPStreamError.badHeader }

        let fileNameLen = readUInt16(localHeader, at: 26)
        let extraLen = readUInt16(localHeader, at: 28)
        fileHandle.seek(toFileOffset: fileHandle.offsetInFile + UInt64(fileNameLen + extraLen))

        var remaining = entry.compressedSize
        let readChunk = 256 * 1024

        // 未压缩：原样搬运
        if entry.compressionMethod == 0 {
            while remaining > 0 {
                let n = min(readChunk, remaining)
                let data = fileHandle.readData(ofLength: n)
                if data.isEmpty { break }
                remaining -= data.count
                try sink(data)
            }
            return
        }

        guard entry.compressionMethod == 8 else {
            throw ZIPStreamError.unsupportedMethod(entry.compressionMethod)
        }

        // deflate：增量解压
        //
        // 用 compression_stream 而不是 compression_decode_buffer：
        // 后者要求目标缓冲一次性开到「整个文件解压后」那么大（132MB），
        // 等于把整个文件又摆回内存里，这次改造就白做了。
        //
        // 结构体字段在 Swift 里是非 optional 的指针类型，不能写 nil，
        // 所以先分配一个 1 字节的占位再 init —— init 只写这四个字段，
        // 不读它们，占位在第一次 process 前就会被真正赋值覆盖。
        var placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { placeholder.deallocate() }

        var stream = compression_stream(
            dst_ptr: placeholder,
            dst_size: 0,
            src_ptr: UnsafePointer(placeholder),
            src_size: 0,
            state: nil
        )
        // COMPRESSION_ZLIB 在 Compression 框架里就是 compression_algorithm
        // 类型（不是 Int32），直接传即可，不需要转换。
        let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard initStatus == COMPRESSION_STATUS_OK else {
            throw ZIPStreamError.streamInit(initStatus.rawValue)
        }
        defer { compression_stream_destroy(&stream) }

        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: readChunk)
        defer { dstBuffer.deallocate() }

        // 错误用这个变量带出闭包 —— 不能在 withUnsafeBytes 里直接 throw，
        // 那样会把「已经产出到一半的文件」留在磁盘上却当成成功。
        var streamError: Error?
        var finished = false

        while remaining > 0 && !finished {
            let n = min(readChunk, remaining)
            let compressed = fileHandle.readData(ofLength: n)
            if compressed.isEmpty { break }
            remaining -= compressed.count

            compressed.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                stream.src_ptr = base
                stream.src_size = compressed.count

                // 一块输入可能产出多块输出，循环到这块被吃干净为止
                while true {
                    stream.dst_ptr = dstBuffer
                    stream.dst_size = readChunk
                    let status = compression_stream_process(&stream, 0)

                    switch status {
                    case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                        let produced = readChunk - stream.dst_size
                        if produced > 0 {
                            do {
                                try sink(Data(bytes: dstBuffer, count: produced))
                            } catch {
                                streamError = error
                                return
                            }
                        }
                        if status == COMPRESSION_STATUS_END {
                            finished = true
                            return
                        }
                        // OK 且这块输入已经用尽 → 去读下一块
                        if stream.src_size == 0 { return }
                    default:
                        streamError = ZIPStreamError.decodeFailed(status.rawValue)
                        return
                    }
                }
            }

            if streamError != nil { break }
        }

        if let e = streamError { throw e }
    }

    func extractData(for entry: Entry) throws -> Data? {
        fileHandle.seek(toFileOffset: entry.localHeaderOffset)

        let localHeader = fileHandle.readData(ofLength: 30)
        guard localHeader.count == 30 else { return nil }

        let fileNameLen = readUInt16(localHeader, at: 26)
        let extraLen = readUInt16(localHeader, at: 28)

        fileHandle.seek(toFileOffset: fileHandle.offsetInFile + UInt64(fileNameLen + extraLen))

        let compressedData = fileHandle.readData(ofLength: entry.compressedSize)

        if entry.compressionMethod == 0 {
            return compressedData
        } else if entry.compressionMethod == 8 {
            return decompressDeflate(compressedData, expectedSize: entry.uncompressedSize)
        } else {
            logger.error("[RootfsZIP] unsupported compression method: \(entry.compressionMethod)")
            return nil
        }
    }

    private func decompressDeflate(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }

        var decompressed = Data(count: expectedSize)
        let result = decompressed.withUnsafeMutableBytes { destPtr -> Int in
            data.withUnsafeBytes { srcPtr -> Int in
                let dstSize = expectedSize
                let status = compression_decode_buffer(
                    destPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    dstSize,
                    srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
                return status
            }
        }

        if result > 0 {
            decompressed.count = result
            return decompressed
        }
        return nil
    }
}
