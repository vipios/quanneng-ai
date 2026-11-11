#!/bin/bash
set -e

# ============================================================================
# Alpine Linux aarch64 Rootfs Preparation Script for iSH-ARM64
# ============================================================================
# This script downloads Alpine Linux minirootfs (aarch64) and converts it to
# iSH's fakefs format for use as a sandboxed ARM64 Linux environment.
#
# Repository: https://github.com/OpenMinis/ish-arm64 (branch: feature-arm64)
#
# Prerequisites:
#   - Python 3 with meson (pip3 install meson)
#   - Ninja (brew install ninja)
#   - libarchive (brew install libarchive)
#
# Usage:
#   ./prepare_alpine_rootfs.sh [version]
#
# Output:
#   deps/resources/alpine-rootfs/  - fakefs formatted rootfs
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISH_DIR="$SCRIPT_DIR/ish"
OUTPUT_DIR="$SCRIPT_DIR/resources"
CACHE_DIR="$SCRIPT_DIR/.cache"

# Alpine configuration - aarch64 for ARM64 emulation
ALPINE_VERSION="${1:-3.21}"
ALPINE_MINOR="0"
ALPINE_ARCH="aarch64"  # ARM64 for iSH-ARM64 emulation
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"

# [R58-预装工具链] 国内镜像优先。
#
# dl-cdn.alpinelinux.org 在国内经常几十 KB/s，一次要拉 100+ 个包，
# 用官方源会让 CI 多跑十几分钟、还容易半路超时留下半个 rootfs。
# 清华源实测稳定在 100~200 KB/s，本地跑得快，CI 上（美国节点）
# 也能直连，只是不如官方源快 —— 所以只用于本机，CI 仍走官方源。
ALPINE_MIRROR_CN="https://mirrors.tuna.tsinghua.edu.cn/alpine"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
    exit 1
}

# ============================================================================
# Check Prerequisites
# ============================================================================
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v curl &> /dev/null; then
        log_error "curl is required"
    fi

    if ! command -v meson &> /dev/null; then
        log_error "Meson is required. Install with: pip3 install meson"
    fi

    if ! command -v ninja &> /dev/null; then
        log_error "Ninja is required. Install with: brew install ninja"
    fi

    # Check for libarchive
    LIBARCHIVE_FOUND=0
    for dir in "/opt/homebrew/opt/libarchive" "/usr/local/opt/libarchive" "/usr"; do
        if [ -f "$dir/lib/libarchive.dylib" ] || [ -f "$dir/lib/libarchive.a" ] || [ -f "$dir/lib/libarchive.so" ]; then
            LIBARCHIVE_FOUND=1
            break
        fi
    done

    if [ $LIBARCHIVE_FOUND -eq 0 ]; then
        log_error "libarchive is required. Install with: brew install libarchive"
    fi

    log_success "Prerequisites check passed"
}

# ============================================================================
# Download Alpine minirootfs
# ============================================================================
download_alpine() {
    log_info "Downloading Alpine Linux $ALPINE_VERSION.$ALPINE_MINOR for $ALPINE_ARCH..."

    mkdir -p "$CACHE_DIR"

    local ROOTFS_FILE="alpine-minirootfs-${ALPINE_VERSION}.${ALPINE_MINOR}-${ALPINE_ARCH}.tar.gz"
    local ROOTFS_PATH="$CACHE_DIR/$ROOTFS_FILE"
    local ROOTFS_URL="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/${ROOTFS_FILE}"

    if [ -f "$ROOTFS_PATH" ]; then
        log_info "Using cached rootfs: $ROOTFS_FILE"
    else
        log_info "Downloading from $ROOTFS_URL"
        curl -L -o "$ROOTFS_PATH" "$ROOTFS_URL" --progress-bar

        if [ ! -f "$ROOTFS_PATH" ]; then
            log_error "Failed to download rootfs"
        fi
    fi

    log_success "Alpine rootfs ready: $(du -h "$ROOTFS_PATH" | cut -f1)"
}

# ============================================================================
# Build fakefsify tool
# ============================================================================
build_fakefsify() {
    log_info "Building fakefsify tool..."

    local BUILD_DIR="$ISH_DIR/build-native"

    # Check if already built
    if [ -x "$BUILD_DIR/tools/fakefsify" ]; then
        log_info "fakefsify already built"
        return
    fi

    mkdir -p "$BUILD_DIR"
    cd "$ISH_DIR"

    # Configure for native build (not cross-compile)
    if [ ! -f "$BUILD_DIR/build.ninja" ]; then
        log_info "Configuring native meson build..."
        # Deliberately no -Db_ndebug here (unlike build_ish.sh, which disables
        # asserts for release). This build produces only tools/fakefsify, a
        # host-side tool that runs on this Mac and never ships to a device, so
        # a failed assert is a loud build failure rather than a user crash —
        # which is what we want while generating a rootfs.
        meson setup "$BUILD_DIR" \
            --buildtype=release \
            -Dlog="" \
            -Dkernel=ish \
            -Dengine=asbestos \
            -Dguest_arch=arm64
    fi

    # Build only fakefsify
    log_info "Building fakefsify..."
    ninja -C "$BUILD_DIR" tools/fakefsify

    if [ ! -x "$BUILD_DIR/tools/fakefsify" ]; then
        log_error "Failed to build fakefsify"
    fi

    cd "$SCRIPT_DIR"
    log_success "fakefsify built successfully"
}

# ============================================================================
# Create fakefs rootfs
# ============================================================================
create_fakefs() {
    log_info "Creating fakefs rootfs..."

    local ROOTFS_FILE="alpine-minirootfs-${ALPINE_VERSION}.${ALPINE_MINOR}-${ALPINE_ARCH}.tar.gz"
    local ROOTFS_PATH="$CACHE_DIR/$ROOTFS_FILE"
    local FAKEFSIFY="$ISH_DIR/build-native/tools/fakefsify"
    local OUTPUT_ROOTFS="$OUTPUT_DIR/alpine-rootfs"

    # Remove existing rootfs
    if [ -d "$OUTPUT_ROOTFS" ]; then
        log_info "Removing existing rootfs..."
        rm -rf "$OUTPUT_ROOTFS"
    fi

    mkdir -p "$OUTPUT_DIR"

    # Convert to fakefs format
    log_info "Converting rootfs to fakefs format..."
    "$FAKEFSIFY" "$ROOTFS_PATH" "$OUTPUT_ROOTFS"

    if [ ! -d "$OUTPUT_ROOTFS/data" ] || [ ! -f "$OUTPUT_ROOTFS/meta.db" ]; then
        log_error "Failed to create fakefs rootfs"
    fi

    log_success "Fakefs rootfs created"
}

# ============================================================================
# Configure rootfs for iSH
# ============================================================================
configure_rootfs() {
    log_info "Configuring rootfs for iSH..."

    # [R58-预装工具链-修正] 同样改成操作暂存目录树，在 fakefsify 之前跑。
    #
    # 这里新建的 /etc/motd、/etc/inittab、/etc/resolv.conf、
    # /etc/apk/repositories 都是**新文件**。以前这段在 fakefsify 之后跑，
    # 新文件没进 meta.db 的 paths 表 —— 设备上等于不存在：
    # `cat /etc/resolv.conf` 会报 No such file or directory，DNS 直接不工作。
    #
    # 改动已有的 /etc/passwd、/etc/profile 不受影响（它们在表里已有记录），
    # 但一并挪过来更一致，也省得以后有人再踩一次。
    local ROOTFS_DATA="$OUTPUT_DIR/rootfs-staging"

    if [ ! -d "$ROOTFS_DATA" ]; then
        log_error "暂存目录不存在，preseed_toolchain 没跑？"
    fi

    # Create necessary directories
    mkdir -p "$ROOTFS_DATA/dev"
    mkdir -p "$ROOTFS_DATA/proc"
    mkdir -p "$ROOTFS_DATA/sys"
    mkdir -p "$ROOTFS_DATA/tmp"
    mkdir -p "$ROOTFS_DATA/run"
    mkdir -p "$ROOTFS_DATA/root"
    mkdir -p "$ROOTFS_DATA/home"

    # Configure /etc/passwd - set root shell
    if [ -f "$ROOTFS_DATA/etc/passwd" ]; then
        # Ensure root has /bin/sh as shell
        sed -i.bak 's|^root:.*|root:x:0:0:root:/root:/bin/sh|' "$ROOTFS_DATA/etc/passwd"
        rm -f "$ROOTFS_DATA/etc/passwd.bak"
    fi

    # Configure /etc/profile for better shell experience
    cat >> "$ROOTFS_DATA/etc/profile" << 'EOF'

# QuanNengAI iSH Configuration
export PS1='\u@quanNengAI:\w\$ '
export TERM=xterm-256color
export HOME=/root
export LANG=C.UTF-8
export CHARSET=UTF-8
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin

# Aliases
alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'

cd ~
EOF

    # Create /etc/motd
    cat > "$ROOTFS_DATA/etc/motd" << 'EOF'

  __  __ _       _        _    _ _
 |  \/  (_)_ __ (_)___   | |  (_) |_ ___
 | |\/| | | '_ \| / __|  | |  | | __/ _ \
 | |  | | | | | | \__ \  | |__| | ||  __/
 |_|  |_|_|_| |_|_|___/  |____|_|\__\___|

 Welcome to QuanNengAI Linux Shell
 Alpine Linux aarch64 on iSH-ARM64 Emulator

EOF

    # Configure /etc/inittab for single user mode (iSH handles tty)
    cat > "$ROOTFS_DATA/etc/inittab" << 'EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

    # Configure resolv.conf for DNS
    cat > "$ROOTFS_DATA/etc/resolv.conf" << 'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

    # Configure APK repositories
    cat > "$ROOTFS_DATA/etc/apk/repositories" << EOF
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community
EOF

    log_success "Rootfs configured"
}

# ============================================================================
# [R58-预装工具链] 把 ipa / dylib / deb 三条线要用的工具直接打进 rootfs
# ============================================================================
#
# 为什么要有这一步
# ---------------------------------------------------------------------------
# 之前 rootfs 是 Alpine minirootfs 裸包转的 fakefs，一个开发工具都没有。
# 于是每次任务模型都得现场 `apk add`，一轮 28 分钟、9 次失败，其中
# 最典型的是编译 ldid —— 要 clang + 完整构建链，现场装要十几分钟。
#
# 现在把这些包预先解进 rootfs，装完即用。
#
# 为什么不用 apk 命令
# ---------------------------------------------------------------------------
# CI 跑在 macOS 上，没有 apk；即使有也跑不了 aarch64 二进制（没 QEMU）。
# 但 .apk 本身只是**一层 gzip 包着的 tar**（里面有 .PKGINFO、.SIGN.RSA、
# usr/），Python 的 tarfile 直接就能解开，不需要 apk、不需要 chroot。
#
# 包清单怎么定的
# ---------------------------------------------------------------------------
# 只装 ipa / dylib / deb 三类活真正要用的，不做「全都要」：
#   · 编译器  clang18 + lld18 + musl-dev + binutils + make
#             lld18 里含 ld64.lld —— 那是 LLVM 的 Mach-O 链接器，
#             没有它编不出 iOS 格式的 dylib。
#   · Mach-O  llvm18 的 llvm-objdump / llvm-nm / llvm-lipo / llvm-readobj
#             注意这些工具在 /usr/lib/llvm18/bin/ 而不在 /usr/bin/，
#             后面会补软链。
#   · deb     dpkg + dpkg-dev + fakeroot（dpkg-deb 在 dpkg 包里）
#   · ipa     zip + unzip
#   · 通用    git curl wget bash coreutils findutils grep sed patch
#             tar xz gzip zstd file openssl python3
#
# 刻意**不装** g++（clang 编 C++ 够用，g++ 还要 36MB）。
#
# gcc 主包被屏蔽了（见 PRESEED_BLOCK），省 122.8MB。
# 它是 clang18 的硬依赖，但 clang18 实际只需要 gcc 提供的
# so:libgcc_s.so.1 —— 那个共享库由独立的 libgcc 包提供（0.1MB）。
# 也就是说 122.8MB 里 122.7MB 是 gcc 自己的 cc1/collect2 等二进制，
# 用 clang 的场合一个都用不上。屏蔽后 libgcc 仍会被正常拉进来，
# 依赖链不断。
#
# 体积（实测自 APKINDEX 的 S/I 字段）
# ---------------------------------------------------------------------------
#   S = 压缩后（apk 文件本身大小）  I = 安装后（解压到磁盘的大小）
#
#   全量 A：86 包  S=220.4MB  I=638.2MB
#   精简后：78 包  S=167.9MB  I=505.1MB   ← 屏蔽 gcc + 去掉 git
#
# 注意这两个数不是 ipa 的增量。zip 里装的是**解压后**的 data/ 目录，
# 所以真正影响 ipa 体积的是 I 那一列。之前按 S 估算过「增 164MB」，
# 口径错了，实际 pushed 出来的 zip 是 704MB。
#
# 已剔除的死重
# ---------------------------------------------------------------------------
# llvm18 包里带一个 llvm-exegesis（98.6MB），是 CPU 指令性能压测工具，
# 跟这三类活毫无关系。下面装完会把它删掉，直接省 93MB。

# 要装进 rootfs 的包。顺序无所谓，依赖闭包由脚本自己算。
PRESEED_PACKAGES=(
    # ── 编译 dylib ──
    clang18
    lld18
    musl-dev
    binutils
    make
    pkgconf
    # ── Mach-O 分析（llvm-objdump / nm / lipo / readobj）──
    llvm18
    # ── 打 deb ──
    dpkg
    dpkg-dev
    fakeroot
    # ── 打 ipa ──
    zip
    unzip
    # ── 通用 ──
    curl
    wget
    bash
    coreutils
    findutils
    grep
    sed
    patch
    diffutils
    tar
    xz
    gzip
    zstd
    file
    openssl
    python3
)

# 依赖闭包里遇到这些名字就跳过，不装。
#
# gcc：122.8MB，clang18 硬依赖它只为拿 so:libgcc_s.so.1，而
#      那个库由独立的 libgcc 包提供。屏蔽后依赖链自动改走 libgcc。
# git：6.7MB，这三类活（打 ipa / 编 dylib / 打 deb）不需要版本控制。
#      真要 clone 什么，curl 下 tar 包一样。
PRESEED_BLOCK=(
    gcc
    git
)

# 装完要删掉的文件/目录。相对 rootfs 的 data 根。
PRESEED_REMOVE=(
    # CPU 指令性能压测工具，98.6MB，与本项目无关
    "usr/lib/llvm18/bin/llvm-exegesis"
    # 上面那个工具的伴随文件
    "usr/lib/llvm18/bin/llvm-jitlink-executor"
    "usr/lib/llvm18/bin/lli-child-target"
)

# ldid 的下载地址。
#
# ldid 是 ipa 重签名 / 给二进制预签 entitlements 的工具，**Alpine 仓库里没有**
# （main + community 都查过）。Procursus 官方提供 Linux aarch64 预编译版，
# 已实测是 ELF64 aarch64 且**静态链接**（DT_NEEDED 为空），
# 所以直接丢进 /usr/local/bin 就能跑，不需要任何依赖库。
LDID_URL="https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus7/ldid_linux_aarch64"
LDID_SHA_HINT="2745416"   # 实测字节数，仅用于下载完整性检查

preseed_toolchain() {
    # [R58-预装工具链-修正] 这里改的是**解包后的 rootfs 目录树**，
    # 不是 fakefs 的 data 目录。
    #
    # 为什么：fakefsify 把所有路径写进 meta.db 的 paths 表，iSH 内核靠那张表
    # 认文件（stat 查不到就 ENOENT，readdir 查不到就跳过）。所以必须在
    # fakefsify 之前把文件准备好，不能事后往 data/ 里塞。
    #
    # 流程：minirootfs.tar.gz → 解包到 staging → 解入工具链 → 重新打包
    local ROOTFS_FILE="alpine-minirootfs-${ALPINE_VERSION}.${ALPINE_MINOR}-${ALPINE_ARCH}.tar.gz"
    local ROOTFS_PATH="$CACHE_DIR/$ROOTFS_FILE"
    local STAGING="$OUTPUT_DIR/rootfs-staging"

    if [ ! -f "$ROOTFS_PATH" ]; then
        log_error "minirootfs 不存在：$ROOTFS_PATH（download_alpine 没跑？）"
    fi

    log_info "预装工具链：${#PRESEED_PACKAGES[@]} 个顶层包"

    # ── 0. 解包 minirootfs 到暂存目录 ──
    if [ -d "$STAGING" ]; then
        rm -rf "$STAGING"
    fi
    mkdir -p "$STAGING"
    log_info "解包 minirootfs 到暂存目录…"
    # 这里同样不加 --no-same-permissions：minirootfs 里的 /bin/busybox、
    # /bin/sh、/sbin/* 全靠执行位活着，抹掉之后整个 rootfs 起不来。
    tar xzf "$ROOTFS_PATH" -C "$STAGING" --no-same-owner \
        || log_error "minirootfs 解包失败"

    local ROOTFS_DATA="$STAGING"

    # ── 1. 拿到索引，算出完整依赖闭包 ──
    #
    # 这一步必须做：手写包清单一定会漏依赖，漏了的后果是
    # 「命令找不到共享库」—— 在设备上表现为 segfault，极难查。
    local MIRROR="$ALPINE_MIRROR"
    if ! curl -fsI --max-time 12 "${MIRROR}/v${ALPINE_VERSION}/main/${ALPINE_ARCH}/APKINDEX.tar.gz" >/dev/null 2>&1; then
        log_warning "官方源连不上或太慢，改用清华镜像"
        MIRROR="$ALPINE_MIRROR_CN"
    fi

    local IDX_DIR="$CACHE_DIR/apkindex"
    mkdir -p "$IDX_DIR"

    local repo
    for repo in main community; do
        local tarball="$IDX_DIR/${repo}.tar.gz"
        if [ ! -f "$tarball" ]; then
            log_info "拉取 $repo 索引…"
            curl -fsSL --retry 3 --max-time 180 \
                -o "$tarball" \
                "${MIRROR}/v${ALPINE_VERSION}/${repo}/${ALPINE_ARCH}/APKINDEX.tar.gz" \
                || log_error "拉取 $repo 索引失败"
        fi
        mkdir -p "$IDX_DIR/$repo"
        tar xzf "$tarball" -C "$IDX_DIR/$repo" APKINDEX 2>/dev/null || true
    done

    local MAIN_IDX="$IDX_DIR/main/APKINDEX"
    local COMM_IDX="$IDX_DIR/community/APKINDEX"
    [ -f "$MAIN_IDX" ] || log_error "main 索引缺失"
    [ -f "$COMM_IDX" ] || log_error "community 索引缺失"

    # ── 2. 解依赖，产出「包名 版本 仓库」清单 ──
    #
    # 用 Python 写而不是 bash：这是图遍历 + 虚拟包（so:/cmd:）解析，
    # bash 做不了，硬做出来也没人敢改。
    local PLAN="$CACHE_DIR/preseed-plan.txt"
    python3 - "$MAIN_IDX" "$COMM_IDX" "$PLAN" "${PRESEED_BLOCK[*]}" \
        "${PRESEED_PACKAGES[@]}" <<'PYEOF'
import sys

main_idx, comm_idx, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
# [R58-瘦身] 第 4 个参数是空格分隔的屏蔽名单，之后的才是根包。
# 屏蔽 = 依赖图里遇到就跳过，且跳过之后它的依赖也不再展开。
BLOCK = set(sys.argv[4].split())
roots = sys.argv[5:]

def parse(path, repo):
    pkgs, cur = {}, {}
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line.strip():
                if cur.get('P'):
                    cur['repo'] = repo
                    pkgs[cur['P']] = cur
                cur = {}
                continue
            if len(line) < 2 or line[1] != ':':
                continue
            cur[line[0]] = line[2:]
    if cur.get('P'):
        cur['repo'] = repo
        pkgs[cur['P']] = cur
    return pkgs

allp = {}
allp.update(parse(comm_idx, 'community'))
allp.update(parse(main_idx, 'main'))     # main 覆盖 community

# 虚拟包索引：so:libLLVM.so.18.1 / cmd:python3 / 包名本身
prov = {}
for name, p in allp.items():
    prov.setdefault(name, []).append(name)
    for pv in (p.get('p') or '').split():
        prov.setdefault(pv.split('=')[0], []).append(name)

def resolve(dep):
    dep = dep.split('>=')[0].split('=')[0].split('~')[0].split('<')[0].strip()
    if not dep or dep not in prov:
        return None
    # [R58-瘦身] 候选里剔掉屏蔽的包。
    # 例：clang18 硬依赖 gcc，屏蔽 gcc 后这里返回 None，
    # 该依赖被当成「已满足」不再展开 —— 而 so:libgcc_s.so.1 这条
    # 虚拟依赖仍能解析到 libgcc 包，所以库不会缺。
    cands = [c for c in prov[dep] if c not in BLOCK]
    if not cands:
        return None
    # 同名真包优先，其次 main 仓，最后按名字长度（短的更可能是主包）
    for c in cands:
        if c == dep:
            return c
    return sorted(cands, key=lambda n: (allp[n]['repo'] != 'main', len(n)))[0]

seen, queue, missing = {}, [], []
for r in roots:
    if r in BLOCK:
        continue
    t = resolve(r)
    if t:
        queue.append(t)
    else:
        missing.append(r)

while queue:
    n = queue.pop()
    if n in seen or n in BLOCK:
        continue
    p = allp.get(n)
    if not p:
        missing.append(n)
        continue
    seen[n] = p
    for d in (p.get('D') or '').split():
        if d.startswith('!'):       # !name 是冲突声明，不是依赖
            continue
        t = resolve(d)
        if t and t not in seen and t not in BLOCK:
            queue.append(t)
        elif not t:
            # 被屏蔽导致的「解析不到」不算缺依赖，不打进 missing
            bare = d.split('>=')[0].split('=')[0].split('~')[0].split('<')[0].strip()
            if bare not in BLOCK:
                missing.append(d)

if BLOCK:
    sys.stderr.write('已屏蔽: %s\n' % ' '.join(sorted(BLOCK)))
if missing:
    sys.stderr.write('未解析的依赖: %s\n' % sorted(set(missing))[:10])

# [R58-瘦身] 屏蔽 gcc 之后必须确认 libgcc 还在闭包里。
#
# 链路是这样：clang18 → gcc → so:libgcc_s.so.1。屏蔽 gcc 后第一环断了，
# 但 clang18 自己也直接依赖 so:libgcc_s.so.1，所以正常情况 libgcc 会由
# 那条边带进来。这里再兜一层 —— 万一哪天 Alpine 改了依赖关系，
# 少了 libgcc 会表现为「clang 能启动但一链接就报错」，非常难查。
if 'gcc' in BLOCK and 'libgcc' not in seen:
    p = allp.get('libgcc')
    if p:
        seen['libgcc'] = p
        sys.stderr.write('兜底：显式补入 libgcc（gcc 被屏蔽，但共享库不能缺）\n')

with open(out_path, 'w', encoding='utf-8') as f:
    for n, p in sorted(seen.items()):
        f.write('%s\t%s\t%s\t%s\n' % (n, p.get('V', ''), p['repo'], p.get('S', '0')))

total = sum(int(p.get('S', 0)) for p in seen.values())
installed = sum(int(p.get('I', 0)) for p in seen.values())
sys.stderr.write('闭包: %d 包  压缩 %.0f MB  解压 %.0f MB\n'
                 % (len(seen), total / 1048576, installed / 1048576))
PYEOF

    [ -f "$PLAN" ] || log_error "依赖求解失败，没生成计划文件"
    log_success "依赖闭包：$(wc -l < "$PLAN" | tr -d ' ') 个包"

    # ── 3. 逐个下载并解压进 rootfs ──
    #
    # 顺序无关：.apk 之间没有安装脚本依赖（Alpine 的 pre/post-install
    # 只做用户组、缓存这类事，对静态可执行文件无影响）。
    # tr iggers 目录会被跳过 —— 那些脚本要在 aarch64 上跑，这里跑不了，
    # 也不需要（本 rootfs 不做 apk 包管理，工具都是现成的）。
    local PKG_CACHE="$CACHE_DIR/apk"
    mkdir -p "$PKG_CACHE"

    local idx=0 total_n
    total_n=$(wc -l < "$PLAN" | tr -d ' ')
    local failed=()

    while IFS=$'\t' read -r name ver repo _size; do
        [ -z "$name" ] && continue
        idx=$((idx + 1))

        # 目录结构里没有下划线包名的坑，直接用原名
        local apk_file="$PKG_CACHE/${name}-${ver}.apk"
        local url="${MIRROR}/v${ALPINE_VERSION}/${repo}/${ALPINE_ARCH}/${name}-${ver}.apk"

        if [ ! -s "$apk_file" ]; then
            if ! curl -fsSL --retry 3 --max-time 300 -o "$apk_file" "$url"; then
                log_warning "[$idx/$total_n] 下载失败：$name-$ver"
                failed+=("$name")
                rm -f "$apk_file"
                continue
            fi
        fi

        # 解压。--no-same-owner 必须有：CI 上是普通用户，
        # 包里记录的 uid/gid 在这里没意义，强行还原会报权限错。
        #
        # [R58-预装工具链-修正] 这里**刻意不加** --no-same-permissions。
        # 那个开关的本意是「别去还原权限」，但它连带把执行位也吃掉了 ——
        # 装进去的 clang / ld.lld / python3 / ldid 全是 0644，
        # 在设备上表现为 Permission denied，而且不报「缺文件」，
        # 很容易被误判成别的问题（之前就是这样，查了半天路径）。
        #
        # 不用 --no-same-permissions 会不会因为权限报错？
        # 不会：rootfs 是当前用户自己的目录，包里记录的 0444/0555 之类
        # 都能正常写入（我们不是 root，但目标文件本来就归自己）。
        if ! tar xzf "$apk_file" -C "$ROOTFS_DATA" \
                --no-same-owner 2>/dev/null; then
            log_warning "[$idx/$total_n] 解压失败：$name-$ver"
            failed+=("$name")
            continue
        fi

        if [ $((idx % 20)) -eq 0 ]; then
            log_info "  [$idx/$total_n] 已解压 $name"
        fi
    done < "$PLAN"

    if [ ${#failed[@]} -gt 0 ]; then
        # 不直接失败：少几个非关键包（比如 wget）不影响主链路。
        # 但要把名字打出来，免得 CI 绿着而工具其实缺了。
        log_warning "有 ${#failed[@]} 个包没装上：${failed[*]}"
    fi

    # ── 4. 删掉用不上的大文件 ──
    local rel
    for rel in "${PRESEED_REMOVE[@]}"; do
        if [ -e "$ROOTFS_DATA/$rel" ]; then
            rm -f "$ROOTFS_DATA/$rel"
            log_info "  已剔除 $rel"
        fi
    done

    # ── 5. 补软链：llvm18 的工具不在 /usr/bin ──
    #
    # Alpine 把 LLVM 工具装在 /usr/lib/llvm18/bin/，PATH 里没有这一层。
    # 模型按常识敲 `llvm-objdump` 会得到 command not found —— 直觉上
    # 会以为工具没装、转头去 apk add，白跑一轮。
    # 这里给每个工具在 /usr/bin 建一个相对软链。
    local llvm_bin="$ROOTFS_DATA/usr/lib/llvm18/bin"
    if [ -d "$llvm_bin" ]; then
        mkdir -p "$ROOTFS_DATA/usr/bin"
        local tool
        for tool in "$llvm_bin"/*; do
            [ -f "$tool" ] || continue
            local base
            base=$(basename "$tool")
            # 相对软链：/usr/bin/llvm-nm -> ../lib/llvm18/bin/llvm-nm
            # 用相对路径而不是绝对路径 —— rootfs 最终会被搬到 App 沙盒里，
            # 绝对路径在那边不成立。
            ln -sf "../lib/llvm18/bin/$base" "$ROOTFS_DATA/usr/bin/$base" 2>/dev/null || true
        done
        log_info "  已为 llvm18 工具补 $(ls "$llvm_bin" | wc -l | tr -d ' ') 个软链"
    fi

    # ── 5b. 可执行位兜底 ──
    #
    # 上一步去掉 --no-same-permissions 之后，正常情况权限是对的。
    # 但 tar 的权限还原依赖 umask 和文件系统，CI 环境不是我们能控制的，
    # 所以这里再扫一遍：把 /usr/bin、/usr/sbin、/usr/local/bin 以及
    # llvm18 目录下所有普通文件补上执行位。
    #
    # 为什么敢无脑 chmod +x：这三个目录里本来就不该有不可执行的数据文件。
    # 真放错地方了，多一个执行位也不会有副作用（没人会去执行一个 .txt）。
    local exec_dir
    for exec_dir in "$ROOTFS_DATA/usr/bin" \
                    "$ROOTFS_DATA/usr/sbin" \
                    "$ROOTFS_DATA/usr/local/bin" \
                    "$ROOTFS_DATA/usr/lib/llvm18/bin" \
                    "$ROOTFS_DATA/bin" "$ROOTFS_DATA/sbin"; do
        [ -d "$exec_dir" ] || continue
        find "$exec_dir" -maxdepth 1 -type f -exec chmod 755 {} + 2>/dev/null || true
    done
    log_info "  已补齐可执行位"

    # ── 6. 放 ldid ──
    #
    # 这是 ipa 重签名的命门，Alpine 仓库里没有，只能用预编译版。
    # 已实测：ELF64 / aarch64 / 静态链接（无 DT_NEEDED），放进去即可运行。
    local ldid_path="$ROOTFS_DATA/usr/local/bin/ldid"
    mkdir -p "$ROOTFS_DATA/usr/local/bin"

    local ldid_cache="$CACHE_DIR/ldid_linux_aarch64"
    if [ ! -s "$ldid_cache" ]; then
        log_info "下载 ldid…"
        # 直连 GitHub 在大陆常断，失败就换加速线路重试
        local u
        for u in "$LDID_URL" \
                 "https://ghfast.top/$LDID_URL" \
                 "https://gh-proxy.com/$LDID_URL"; do
            if curl -fsSL --retry 2 --max-time 120 -o "$ldid_cache" "$u"; then
                break
            fi
        done
    fi

    if [ -s "$ldid_cache" ]; then
        cp "$ldid_cache" "$ldid_path"
        chmod 755 "$ldid_path"
        local sz
        sz=$(wc -c < "$ldid_path" | tr -d ' ')
        if [ "$sz" != "$LDID_SHA_HINT" ]; then
            log_warning "ldid 大小异常（$sz 字节，预期 $LDID_SHA_HINT）—— 可能是错误页，已删除"
            rm -f "$ldid_path"
        else
            log_success "ldid 已就位（$((sz / 1024)) KB，静态链接）"
        fi
    else
        # 不当作致命错误：ldid 只影响 ipa 重签名，
        # 少了它 deb 和 dylib 两条线照常能用。
        log_warning "ldid 没下载成功。ipa 重签名会不可用，其余功能不受影响。"
    fi

    # ── 7. 收尾自检 ──
    #
    # 这一步只是把「该有的东西在不在」打出来，缺了不中断构建 ——
    # 少一个 wget 不该让整轮 30 分钟白跑。
    # 但一定要打印：CI 绿着而工具其实缺了，是最难查的情况。
    local missing_tools=()
    local t
    # git / gcc 已屏蔽，不再检查它们。
    for t in clang clang++ ld.lld ld64.lld make ar as objcopy strip \
             dpkg dpkg-deb fakeroot zip unzip curl python3 \
             tar zstd file openssl \
             llvm-objdump llvm-nm llvm-objcopy llvm-strip llvm-lipo; do
        # 软链也要能解析到真实文件才算存在
        if [ ! -e "$ROOTFS_DATA/usr/bin/$t" ] && [ ! -e "$ROOTFS_DATA/usr/local/bin/$t" ]; then
            missing_tools+=("$t")
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_warning "以下工具没找到：${missing_tools[*]}"
    else
        log_success "  工具自检通过（26 项全在）"
    fi

    # gcc 被屏蔽了，但要确认 libgcc 的共享库还在 —— clang 链接时要用
    local gccs
    gccs=$(find "$ROOTFS_DATA/usr/lib" "$ROOTFS_DATA/lib" -name 'libgcc_s.so*' 2>/dev/null | head -1)
    if [ -n "$gccs" ]; then
        log_success "  libgcc_s 在位（gcc 主包已屏蔽，仅保留共享库）"
    else
        log_warning "  libgcc_s 缺失！clang 能启动但链接会失败"
    fi

    # ldid 单独报 —— 它的失败语义与上面不同（只影响 ipa 重签名）
    if [ -x "$ROOTFS_DATA/usr/local/bin/ldid" ]; then
        log_success "  ldid 可执行"
    else
        log_warning "  ldid 缺失或不可执行，ipa 重签名会失败"
    fi

    log_success "工具链已解入暂存目录"
}

# ============================================================================
# Repack rootfs tar
# ============================================================================
#
# 把暂存目录重新打包成 tar.gz，覆盖原始 minirootfs。
# create_fakefs 读的就是这个路径，所以下游一行都不用改。
#
# 必须放在 configure_rootfs 之后 —— 那一步还在往暂存目录里写配置文件。
repack_rootfs() {
    local ROOTFS_FILE="alpine-minirootfs-${ALPINE_VERSION}.${ALPINE_MINOR}-${ALPINE_ARCH}.tar.gz"
    local ROOTFS_PATH="$CACHE_DIR/$ROOTFS_FILE"
    local STAGING="$OUTPUT_DIR/rootfs-staging"

    if [ ! -d "$STAGING" ]; then
        log_error "暂存目录不存在，没法打包"
    fi

    # 用 -C "$STAGING" . 而不是把 staging 目录本身打进去 —— 否则 tar 里
    # 会多一层 rootfs-staging/，fakefsify 会把它当成根的第一个子目录，
    # 整棵树的路径全错位。
    local REPACKED="$CACHE_DIR/${ROOTFS_FILE}.repacked"
    log_info "重新打包 rootfs（含工具链）…"
    tar czf "$REPACKED" -C "$STAGING" . || log_error "重新打包失败"

    if [ ! -s "$REPACKED" ]; then
        log_error "打包产物为空"
    fi

    mv -f "$REPACKED" "$ROOTFS_PATH"
    rm -rf "$STAGING"

    log_success "rootfs 已更新：$(du -h "$ROOTFS_PATH" | cut -f1)"
}

# ============================================================================
# Create ZIP Archive
# ============================================================================
create_zip_archive() {
    log_info "Creating ZIP archive..."

    local ROOTFS_DIR="$OUTPUT_DIR/alpine-rootfs"
    local ZIP_FILE="$OUTPUT_DIR/alpine-rootfs.zip"

    # Remove existing zip
    rm -f "$ZIP_FILE"

    # [R58-瘦身] 用 -9 最高压缩级别。默认级别对 .so 这类文件压不动，
    # 而这里装的是整套编译工具链，值得多花几十秒换几 MB。
    # 不存符号链接指向的内容（-y），保持 rootfs 结构原样。
    cd "$OUTPUT_DIR"
    zip -9 -r -y "alpine-rootfs.zip" "alpine-rootfs" \
        -x "*.db-shm" \
        -x "*.db-wal" \
        > /dev/null

    cd "$SCRIPT_DIR"

    if [ ! -f "$ZIP_FILE" ]; then
        log_error "Failed to create ZIP archive"
    fi

    log_success "ZIP archive created: $(du -h "$ZIP_FILE" | cut -f1)"
}

# ============================================================================
# Print Summary
# ============================================================================
print_summary() {
    local ROOTFS_DIR="$OUTPUT_DIR/alpine-rootfs"
    local ZIP_FILE="$OUTPUT_DIR/alpine-rootfs.zip"

    echo ""
    echo "============================================================"
    echo -e "${GREEN}🎉 Alpine Rootfs Preparation Complete!${NC}"
    echo "============================================================"
    echo ""
    echo "Output files:"
    echo "  📁 $ROOTFS_DIR"
    echo "  📦 $ZIP_FILE"
    echo ""
    echo "Sizes:"
    echo "  Data:     $(du -sh "$ROOTFS_DIR/data" | cut -f1)"
    echo "  Database: $(du -h "$ROOTFS_DIR/meta.db" | cut -f1)"
    echo "  ZIP:      $(du -h "$ZIP_FILE" | cut -f1)"
    echo ""
    echo "To use in MinisApp:"
    echo "  1. Add alpine-rootfs.zip to Xcode project resources"
    echo "  2. Extract to Documents on first launch"
    echo "  3. Use mount_root(&fakefs, path_to_data)"
    echo ""
    echo "============================================================"
}

# ============================================================================
# Clean
# ============================================================================
clean() {
    log_info "Cleaning..."

    rm -rf "$OUTPUT_DIR/alpine-rootfs"
    rm -rf "$ISH_DIR/build-native"
    rm -rf "$CACHE_DIR"

    log_success "Clean completed"
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo ""
    echo "============================================================"
    echo "  Alpine Linux aarch64 Rootfs Preparation for iSH-ARM64"
    echo "  Version: $ALPINE_VERSION.$ALPINE_MINOR ($ALPINE_ARCH)"
    echo "============================================================"
    echo ""

    check_prerequisites
    download_alpine
    build_fakefsify
    # [R58-预装工具链-修正] 这四步的顺序是关键，不能随便调。
    #
    # 原来的顺序是 create_fakefs → configure → preseed → zip，往 fakefs 的
    # data/ 目录里直接写文件。这个做法是错的，而且错得很隐蔽：
    #
    # iSH 内核不按目录项找文件，它按 meta.db 的 paths 表查 inode：
    #   · fakefs_stat()   → path_read_stat() 查不到就返回 ENOENT
    #   · fakefs_readdir() → path_get_inode()==0 时 goto retry 跳过该条目
    #
    # 也就是说手工塞进 data/ 的文件，在设备上 `ls` 看不见、`stat` 报不存在、
    # 执行当然也找不到。文件实实在在地躺在 App 沙盒里，但内核不认。
    #
    # 现在的顺序：
    #   1. preseed_toolchain  解包 minirootfs → staging，把 86 个包解进去
    #   2. configure_rootfs   往同一个 staging 写 profile / motd / resolv.conf
    #   3. repack_rootfs      把 staging 打回 tar.gz
    #   4. create_fakefs      一次 fakefsify，所有路径一次性写进 meta.db
    #
    # 前三步都在 tar 层面动手，fakefsify 只跑一次、看到的就是完整目录树。
    preseed_toolchain
    configure_rootfs
    repack_rootfs
    create_fakefs
    create_zip_archive
    print_summary
}

# Parse arguments
case "${1:-}" in
    clean)
        clean
        exit 0
        ;;
    --help|-h)
        echo "Usage: $0 [version|clean]"
        echo ""
        echo "Arguments:"
        echo "  version    Alpine version (default: 3.21)"
        echo "  clean      Remove all generated files"
        echo ""
        echo "Examples:"
        echo "  $0           # Use default version 3.21"
        echo "  $0 3.18      # Use Alpine 3.18"
        echo "  $0 clean     # Clean all files"
        exit 0
        ;;
    *)
        main
        ;;
esac
