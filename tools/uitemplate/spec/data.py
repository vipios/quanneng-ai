# -*- coding: utf-8 -*-
"""模板数据源（假数据，字段名对齐 OpenMinis 源码里的真实模型）。

真机接入时 Swift 侧用 `__MS__.setData(json)` 覆盖整份 DATA，字段名必须与这里一致。
本文件只负责「没有后端时模板也能跑起来」，不承载业务逻辑。
"""

DATA = {
    # ── 设备 / 环境 ────────────────────────────────────────────────
    "device": {
        "model": "iPhone 16 Pro",
        "ios": "18.2",
        "jailbroken": True,
        "rootfs": "alpine-3.20.3",
        "rootfsSize": "1.24 GB",
        "arch": "arm64",
    },

    # ── 会话（抽屉骨架） ──────────────────────────────────────────
    "sessions": [
        {"id": "s1", "title": "越狱插件 dylib 注入分析", "pinned": True, "folder": "逆向",
         "time": "16:42", "day": "今天", "artifacts": 3, "model": "Claude Sonnet 4.5",
         "preview": "把 Tweak.xm 里的 %hook 换成……"},
        {"id": "s2", "title": "微信液态玻璃效果复现", "pinned": True, "folder": "逆向",
         "time": "15:08", "day": "今天", "artifacts": 12, "model": "GPT-5.1",
         "preview": "UIVisualEffectView 的 blur 半径对不上…"},
        {"id": "s3", "title": "中转站路由规则排错", "pinned": False, "folder": "运维",
         "time": "11:26", "day": "今天", "artifacts": 1, "model": "Gemini 3 Pro",
         "preview": "route-rules.json 第 47 行匹配不到…"},
        {"id": "s4", "title": "App Store 审核被拒申诉", "pinned": False, "folder": "杂事",
         "time": "昨天", "day": "昨天", "artifacts": 0, "model": "Claude Sonnet 4.5",
         "preview": "Guideline 2.5.2 说动态下发…"},
        {"id": "s5", "title": "iOS 26 玻璃材质适配", "pinned": False, "folder": "逆向",
         "time": "昨天", "day": "昨天", "artifacts": 5, "model": "GPT-5.1",
         "preview": "MACOS27GlassWorkaround 那段…"},
        {"id": "s6", "title": "Alpine 源换国内镜像", "pinned": False, "folder": "运维",
         "time": "周一", "day": "本周", "artifacts": 2, "model": "Gemini 3 Pro",
         "preview": "apk update 卡了 40 秒…"},
        {"id": "s7", "title": "读一份 418KB 的 HTML 设计稿", "pinned": False, "folder": "杂事",
         "time": "周一", "day": "本周", "artifacts": 0, "model": "Claude Sonnet 4.5",
         "preview": "把 318px 的抽屉拆成组件…"},
        {"id": "s8", "title": "pwn 题 tcache 打不动", "pinned": False, "folder": "逆向",
         "time": "周日", "day": "本周", "artifacts": 4, "model": "GPT-5.1",
         "preview": "free 两次后 unsorted bin 没…"},
    ],

    # ── 当前会话消息（对话页） ────────────────────────────────────
    "messages": [
        {"role": "user", "text": "把 Tweak.xm 里的 %hook 换成不依赖 CydiaSubstrate 的写法，"
                                 "我要能直接 dlopen 注入的那种。"},
        {"role": "assistant",
         "blocks": [
             {"k": "text", "text": "不依赖 CydiaSubstrate 就走 fishhook + 手动 method_setImplementation，"
                                   "三步：拿到目标类、换 IMP、留原始 IMP 做回滚。"},
             {"k": "tool", "name": "shell", "status": "ok", "title": "在沙箱里验证 fishhook 符号",
              "body": "$ nm -gU /usr/lib/libfishhook.dylib | head -3\n"
                      "0000000000003a20 T _rebind_symbols\n"
                      "0000000000003a88 T _rebind_symbols_image"},
             {"k": "code", "lang": "objc",
              "text": "static IMP g_orig = NULL;\n"
                      "static void my_setHidden(id self, SEL _cmd, BOOL v) {\n"
                      "    ((void(*)(id, SEL, BOOL))g_orig)(self, _cmd, v);\n"
                      "    NSLog(@\"[hook] setHidden:%d\", v);\n"
                      "}\n"
                      "Method m = class_getInstanceMethod(objc_getClass(\"UIView\"), @selector(setHidden:));\n"
                      "g_orig = method_setImplementation(m, (IMP)my_setHidden);"},
             {"k": "text", "text": "回滚就是 `method_setImplementation(m, g_orig)`。要不要我把注入入口也写成 "
                                   "constructor 段，省掉显式调用？"},
         ]},
        {"role": "user", "text": "要。顺便给我个 Makefile。"},
        {"role": "assistant",
         "blocks": [
             {"k": "tool", "name": "write_file", "status": "ok", "title": "写入 Makefile",
              "body": "patches/Makefile  ·  1.1 KB"},
             {"k": "text", "text": "写好了。`make` 出 dylib，`make install` 拷进 /usr/lib/TweakInject 并 "
                                   "killall -9 目标进程。"},
         ]},
    ],

    # ── 产物 ──────────────────────────────────────────────────────
    "artifacts": [
        {"id": "a1", "name": "Tweak.xm", "ext": "xm", "size": "2.4 KB",
         "session": "越狱插件 dylib 注入分析", "time": "16:40"},
        {"id": "a2", "name": "Makefile", "ext": "mk", "size": "1.1 KB",
         "session": "越狱插件 dylib 注入分析", "time": "16:41"},
        {"id": "a3", "name": "hook-notes.md", "ext": "md", "size": "6.8 KB",
         "session": "越狱插件 dylib 注入分析", "time": "16:42"},
        {"id": "a4", "name": "glass-diff.png", "ext": "png", "size": "418 KB",
         "session": "微信液态玻璃效果复现", "time": "15:02"},
        {"id": "a5", "name": "route-rules.json", "ext": "json", "size": "3.2 KB",
         "session": "中转站路由规则排错", "time": "11:20"},
        {"id": "a6", "name": "apk-镜像配置.conf", "ext": "conf", "size": "512 B",
         "session": "Alpine 源换国内镜像", "time": "周一"},
    ],

    # ── 服务商 ────────────────────────────────────────────────────
    "providers": [
        {"id": "p1", "name": "Anthropic", "kind": "官方 Key", "models": 6, "page": "provider-detail",
         "enabled": True, "state": "正常", "quota": "剩余 78%",
         "base": "https://api.anthropic.com", "auth": "API Key"},
        {"id": "p2", "name": "OpenAI", "kind": "官方 Key", "models": 9, "page": "provider-detail",
         "enabled": True, "state": "正常", "quota": "剩余 45%",
         "base": "https://api.openai.com/v1", "auth": "API Key"},
        {"id": "p3", "name": "自建中转站", "kind": "兼容层", "models": 14, "page": "provider-detail",
         "enabled": True, "state": "延迟偏高", "quota": "不限",
         "base": "https://relay.example.com/v1", "auth": "Bearer"},
        {"id": "p4", "name": "Gemini", "kind": "官方 Key", "models": 4, "page": "provider-detail",
         "enabled": False, "state": "未启用", "quota": "—",
         "base": "https://generativelanguage.googleapis.com", "auth": "API Key"},
    ],
    "modelGroups": [
        {"id": "g1", "page": "model-group-detail", "name": "写代码", "models": 5, "fallback": "Claude Sonnet 4.5",
         "members": ["Claude Sonnet 4.5", "GPT-5.1", "Gemini 3 Pro"]},
        {"id": "g2", "page": "model-group-detail", "name": "便宜快问", "models": 3, "fallback": "GPT-5.1 mini",
         "members": ["GPT-5.1 mini", "Claude Haiku 4.5"]},
        {"id": "g3", "page": "model-group-detail", "name": "长文本", "models": 2, "fallback": "Gemini 3 Pro",
         "members": ["Gemini 3 Pro", "Claude Sonnet 4.5"]},
    ],
    "usage": {
        "today": {"tokens": "1.82M", "cost": "¥ 12.40", "calls": 214},
        "week": {"tokens": "9.4M", "cost": "¥ 68.20", "calls": 1280},
        "month": {"tokens": "38.6M", "cost": "¥ 271.90", "calls": 5211},
        "series": [22, 48, 31, 66, 54, 79, 41, 88, 62, 74, 51, 69],
    },

    # ── 运行时 / 工具 ─────────────────────────────────────────────
    "tools": [
        {"id": "shell", "name": "Linux 沙箱 shell", "on": True, "group": "执行",
         "desc": "在设备上的 Alpine 里跑命令"},
        {"id": "browser", "name": "浏览器自动化", "on": True, "group": "执行",
         "desc": "打开网页、点击、取值"},
        {"id": "agents", "name": "子代理委派", "on": True, "group": "编排",
         "desc": "把任务派给子代理并行跑"},
        {"id": "files", "name": "文件读写", "on": True, "group": "数据",
         "desc": "工作区与挂载目录"},
        {"id": "health", "name": "健康数据", "on": False, "group": "设备",
         "desc": "读取与写入 HealthKit"},
        {"id": "calendar", "name": "日历", "on": True, "group": "设备",
         "desc": "查询与创建日程"},
        {"id": "reminders", "name": "提醒事项", "on": True, "group": "设备",
         "desc": "增删改提醒"},
        {"id": "contacts", "name": "通讯录", "on": False, "group": "设备",
         "desc": "只读检索联系人"},
        {"id": "clipboard", "name": "剪贴板", "on": True, "group": "设备",
         "desc": "读当前剪贴板内容"},
        {"id": "media", "name": "媒体控制", "on": True, "group": "设备",
         "desc": "播放、暂停、下一首"},
        {"id": "alarms", "name": "闹钟", "on": False, "group": "设备",
         "desc": "创建与修改闹钟"},
        {"id": "http", "name": "HTTP 请求", "on": True, "group": "网络",
         "desc": "任意 GET/POST"},
    ],
    "subAgents": [
        {"id": "sa1", "name": "researcher", "model": "Gemini 3 Pro", "on": True,
         "desc": "多源检索，只回结论与出处"},
        {"id": "sa2", "name": "coder", "model": "Claude Sonnet 4.5", "on": True,
         "desc": "改代码、跑测试，回 diff"},
        {"id": "sa3", "name": "reviewer", "model": "GPT-5.1", "on": False,
         "desc": "只做审查，不给实现"},
    ],

    # ── 技能 ──────────────────────────────────────────────────────
    "skills": [
        {"id": "k1", "name": "reverse-ios", "source": "内置", "on": True, "files": 14,
         "desc": "iOS 二进制逆向：类转储、hook、dylib 注入"},
        {"id": "k2", "name": "web-pentest", "source": "内置", "on": True, "files": 22,
         "desc": "Web 漏洞验证与 PoC"},
        {"id": "k3", "name": "alpine-ops", "source": "内置", "on": True, "files": 9,
         "desc": "沙箱内的包管理与服务"},
        {"id": "k4", "name": "paper-reader", "source": "GitHub", "on": False, "files": 6,
         "desc": "论文精读与批注"},
        {"id": "k5", "name": "doc-writer", "source": "GitHub", "on": True, "files": 31,
         "desc": "长文档写作与排版"},
    ],

    # ── MCP ───────────────────────────────────────────────────────
    "mcps": [
        {"id": "m1", "page": "mcp-detail", "name": "filesystem", "transport": "stdio", "on": True,
         "tools": 11, "cmd": "npx -y @modelcontextprotocol/server-filesystem /root"},
        {"id": "m2", "page": "mcp-detail", "name": "github", "transport": "http", "on": True,
         "tools": 24, "cmd": "https://mcp.github.example.com/sse"},
        {"id": "m3", "page": "mcp-detail", "name": "sqlite", "transport": "stdio", "on": False,
         "tools": 6, "cmd": "uvx mcp-server-sqlite --db notes.db"},
    ],
    "envVars": [
        {"k": "ANTHROPIC_BASE_URL", "v": "https://relay.example.com", "secret": False},
        {"k": "ANTHROPIC_API_KEY", "v": "sk-ant-••••••••••••3f2a", "secret": True},
        {"k": "HTTP_PROXY", "v": "http://127.0.0.1:7890", "secret": False},
        {"k": "EDITOR", "v": "vim", "secret": False},
    ],

    # ── 存储 ──────────────────────────────────────────────────────
    "storage": {
        "total": "64 GB", "used": "21.4 GB", "free": "42.6 GB",
        "items": [
            {"name": "根文件系统镜像", "size": "1.24 GB", "pct": 2},
            {"name": "会话与消息", "size": "486 MB", "pct": 1},
            {"name": "产物", "size": "3.18 GB", "pct": 5},
            {"name": "备份", "size": "9.60 GB", "pct": 15},
            {"name": "技能包", "size": "212 MB", "pct": 1},
            {"name": "日志", "size": "84 MB", "pct": 1},
        ],
    },
    "folders": [
        {"id": "f1", "name": "Obsidian 库", "path": "/On My iPhone/Obsidian", "rw": True},
        {"id": "f2", "name": "下载", "path": "/On My iPhone/Downloads", "rw": True},
        {"id": "f3", "name": "只读资料", "path": "/iCloud/资料", "rw": False},
    ],
    "mounts": [
        {"id": "mt1", "name": "NAS", "proto": "SMB", "host": "192.168.1.20",
         "path": "/volume1/share", "state": "已挂载"},
        {"id": "mt2", "name": "MacBook", "proto": "SFTP", "host": "10.0.0.7",
         "path": "/Users/me/code", "state": "未挂载"},
    ],

    # ── 备份 / 同步 ───────────────────────────────────────────────
    "backups": [
        {"id": "b1", "when": "今天 04:00", "size": "1.82 GB", "kind": "自动",
         "state": "成功", "files": 12480},
        {"id": "b2", "when": "昨天 04:00", "size": "1.79 GB", "kind": "自动",
         "state": "成功", "files": 12391},
        {"id": "b3", "when": "11-08 04:00", "size": "1.75 GB", "kind": "自动",
         "state": "部分跳过", "files": 12204},
    ],
    "sync": {
        "state": "已同步", "last": "3 分钟前", "device": "iPad Pro",
        "sessions": 24, "conflicts": 0,
    },

    # ── Rootfs ────────────────────────────────────────────────────
    "rootfs": {
        "version": "Alpine 3.20.3", "size": "1.24 GB", "pkgs": 412,
        "arch": "aarch64", "updated": "2026-11-06",
        "mirrors": [
            {"name": "阿里云", "url": "mirrors.aliyun.com", "ms": 38},
            {"name": "清华 TUNA", "url": "mirrors.tuna.tsinghua.edu.cn", "ms": 52},
            {"name": "官方", "url": "dl-cdn.alpinelinux.org", "ms": 214},
        ],
        "files": [
            {"name": "root", "dir": True, "page": "file-browser"}, {"name": "tmp", "dir": True, "page": "file-browser"},
            {"name": "usr", "dir": True, "page": "file-browser"}, {"name": "etc", "dir": True, "page": "file-browser"},
            {"name": "opt", "dir": True, "page": "file-browser"}, {"name": "workspace", "dir": True, "page": "file-browser"},
            {"name": ".profile", "dir": False, "size": "807 B"},
            {"name": "hook-notes.md", "dir": False, "size": "6.8 KB"},
        ],
        "terminal": [
            "$ apk add --no-cache objc4-headers 2>&1 | tail -2",
            "fetch https://mirrors.aliyun.com/alpine/v3.20/main/aarch64/APKINDEX.tar.gz",
            "OK: 412 packages installed",
            "$ clang -dynamiclib Tweak.m -o Tweak.dylib -framework Foundation",
            "$ ls -lh Tweak.dylib",
            "-rwxr-xr-x 1 root root 18K Nov 10 16:41 Tweak.dylib",
            "$ _",
        ],
    },

    # ── 日志 / 诊断 ───────────────────────────────────────────────
    "logs": [
        {"t": "16:42:03", "lvl": "info", "mod": "Agent", "msg": "tool loop finished, 3 steps"},
        {"t": "16:41:58", "lvl": "warn", "mod": "ISH", "msg": "syscall 452 retried (EAGAIN)"},
        {"t": "16:40:11", "lvl": "error", "mod": "Relay", "msg": "route-rules.json:47 no match"},
        {"t": "16:38:40", "lvl": "info", "mod": "Provider", "msg": "stream closed, 1204 tok"},
        {"t": "16:35:02", "lvl": "warn", "mod": "Memory", "msg": "pressure 62%, dropped cache"},
        {"t": "16:30:19", "lvl": "info", "mod": "Sync", "msg": "pushed 3 sessions"},
    ],
    "crashes": [
        {"when": "11-10 07:27", "kind": "EXC_BAD_ACCESS", "where": "AIChatView.swift:1842"},
        {"when": "11-09 21:04", "kind": "hang", "where": "ISH syscall loop"},
    ],

    # ── 闹钟 / 定时 ───────────────────────────────────────────────
    "alarms": [
        {"id": "al1", "time": "07:30", "label": "晨间时间线播报", "on": True,
         "days": "每天", "task": "抓 X 时间线 → 总结 → 语音"},
        {"id": "al2", "time": "09:00", "label": "备份检查", "on": False,
         "days": "周一至周五", "task": "读备份日志，失败则通知"},
    ],
}
