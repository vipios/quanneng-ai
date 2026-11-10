# -*- coding: utf-8 -*-
"""界面规格：每个可到达界面在这里有一条定义，模板引擎照着渲染。

加界面 = 在这个文件里加一条 + 在 DRAWER/父页里加一个 nav 行，不需要碰引擎。
字段约定（build.py 会原样序列化进 ui.html）：

  screen = {
    "title": 导航标题, "sub": 次标题/说明, "sheet": True 表示模态弹出,
    "back": "返回目标页 id"（默认自动按栈回退）,
    "blocks": [ block, ... ]
  }

block 用下面的小写助手生成，全部是纯 dict。
"""


def _b(t, **kw):
    d = {"t": t}
    d.update(kw)
    return d


# ── 块助手 ────────────────────────────────────────────────────────

def hero(title, sub=""):
    return _b("hero", title=title, sub=sub)


def section(title="", rows=None, footer=""):
    return _b("section", title=title, rows=rows or [], footer=footer)


def nav(title, page, sub="", icon="", color="blue", badge="", value=""):
    return _b("row", kind="nav", title=title, page=page, sub=sub,
              icon=icon, color=color, badge=badge, value=value)


def val(title, value="", sub="", icon="", color="gray", mono=False):
    return _b("row", kind="value", title=title, value=value, sub=sub,
              icon=icon, color=color, mono=mono)


def tgl(title, bind, sub="", icon="", color="gray", badge=""):
    return _b("row", kind="toggle", title=title, bind=bind, sub=sub,
              icon=icon, color=color, badge=badge)


def seg(title, bind, options, sub="", footer=""):
    return _b("seg", title=title, bind=bind, options=options, sub=sub, footer=footer)


def slider(title, bind, lo=0, hi=100, step=1, unit="", sub=""):
    return _b("slider", title=title, bind=bind, lo=lo, hi=hi, step=step,
              unit=unit, sub=sub)


def fld(title, bind, ph="", secure=False, mono=False):
    return _b("field", title=title, bind=bind, ph=ph, secure=secure, mono=mono)


def pick(title, bind, options, sub=""):
    return _b("picker", title=title, bind=bind, options=options, sub=sub)


def btn(title, action, kind="plain", arg="", icon=""):
    return _b("btn", title=title, action=action, kind=kind, arg=arg, icon=icon)


def txt(text, size="body", muted=False):
    return _b("text", text=text, size=size, muted=muted)


def code(text, lang=""):
    return _b("code", text=text, lang=lang)


def stat(items):
    return _b("stat", items=[{"k": k, "v": v} for k, v in items])


def prog(label, pct, value="", color="blue"):
    return _b("prog", label=label, pct=pct, value=value, color=color)


def listblock(src, item, empty_title="空", empty_sub="", searchable=True,
              key="title", sub="", badge="", icon="", color="blue"):
    return _b("list", src=src, item=item, emptyTitle=empty_title,
              emptySub=empty_sub, searchable=searchable, key=key, sub=sub,
              badge=badge, icon=icon, color=color)


def empty(title, sub="", action="", action_title=""):
    return _b("empty", title=title, sub=sub, action=action,
              actionTitle=action_title)


def note(text):
    return _b("note", text=text)


def term(src):
    return _b("term", src=src)


def chatview():
    return _b("chat")


# ── 页面 ──────────────────────────────────────────────────────────

SCREENS = {}

# 1. 对话（根页面）
SCREENS["home"] = {
    "title": "对话", "root": True, "chrome": "chat",
    "blocks": [chatview()],
}

# 2. 设置根
SCREENS["settings"] = {
    "title": "设置", "sheet": True, "back": "",
    "blocks": [
        hero("设置", "AI 服务商、运行时、存储、权限、日志"),
        section("AI 服务商", [
            nav("AI 服务商", "providers", "4 个 · 2 条可用 Key", "key", "blue"),
            nav("模型组", "model-groups", "3 组 · 自动降级", "layers", "indigo"),
            nav("Token 用量", "usage", "本月 38.6M · ¥271.90", "chart", "orange"),
        ]),
        section("设备管理", [
            nav("中转站后台", "relay-admin", "在线 · 14 个模型", "server", "blue"),
            nav("路由器后台", "relay-router", "route-rules.json 已加载", "wifi", "green"),
        ], footer=""),
        section("外观", [
            nav("外观", "appearance", "深色 · 强调色 蓝", "brush", "indigo"),
            nav("背景与材质", "background", "液态玻璃 · 自动", "glass", "cyan"),
        ]),
        section("智能体运行时", [
            nav("工具开关", "agent-tools", "12 个工具 · 10 开", "wrench", "indigo"),
            nav("子代理", "sub-agents", "3 个 · 2 开", "people", "violet"),
            nav("技能", "skills", "5 个 · 4 开", "puzzle", "blue"),
            nav("灵魂", "soul", "人格与语气", "sparkles", "pink"),
            nav("记忆", "memory", "142 条 · 18.4 KB", "brain", "purple"),
            nav("MCP 集成", "mcp", "3 个服务器 · 41 个工具", "stack", "teal"),
            nav("环境变量", "env-vars", "4 条 · 1 条密钥", "terminal", "green"),
            nav("循环用模型", "agent-loop-models", "主循环 / 子任务 / 压缩", "refresh", "gray"),
        ]),
        section("存储", [
            nav("存储", "storage", "已用 21.4 GB / 64 GB", "archive", "blue"),
            nav("共享文件夹", "shared-folders", "3 个目录", "folder", "green"),
            nav("挂载外部文件夹", "mounted-folders", "2 个 · 1 个在线", "drive", "orange"),
            nav("iCloud 同步", "icloud-sync", "3 分钟前", "cloud", "cyan"),
            nav("备份与恢复", "backup", "今天 04:00 成功", "clock", "gray"),
            nav("GitHub 账号", "github", "vipios · 已授权", "github", "gray"),
        ]),
        section("权限", [
            nav("工具权限", "permissions", "12 项 · 4 项已拒", "shield", "red"),
            nav("Face ID 保护", "faceid", "已开启", "face", "green"),
        ]),
        section("日志", [
            nav("日志", "logs", "6 条近期 · 1 条 error", "doc", "gray"),
            nav("崩溃诊断", "crash-diagnostics", "2 份报告", "bug", "red"),
            nav("配置审计", "config-audit", "无冲突", "check", "green"),
        ]),
        section("版本与更新", [
            nav("版本", "version", "1.0 (build 37)", "info", "gray"),
            nav("检查更新", "check-update", "已是最新", "refresh", "blue"),
            nav("更新源", "update-source", "自有源 · GitHub", "globe", "gray"),
        ]),
        section("关于", [
            nav("关于", "about", "全能AI", "info", "gray"),
            nav("隐私政策", "privacy", "", "doc", "gray"),
            nav("反馈", "feedback", "邮件", "mail", "gray"),
        ]),
    ],
}

# 3. 服务商
SCREENS["providers"] = {
    "title": "AI 服务商",
    "blocks": [
        listblock("providers",
                  {"title": "@name", "sub": "@kind · @models 个模型 · @quota",
                   "badge": "@state", "icon": "key", "color": "blue"},
                  empty_title="还没有服务商", empty_sub="加一个 Key 就能开始",
                  searchable=False),
        section("", [btn("添加服务商", "nav", "filled", "provider-add", "plus")]),
        note("Key 只存在本机 Keychain，不经过任何中转。"),
    ],
}

SCREENS["provider-detail"] = {
    "title": "服务商详情",
    "blocks": [
        hero("自建中转站", "兼容层 · Bearer 鉴权"),
        section("连接", [
            val("接口地址", "https://relay.example.com/v1", mono=True),
            val("鉴权方式", "Bearer"),
            fld("API Key", "form.provider.key", "sk-…", secure=True, mono=True),
            nav("快速测试", "provider-test", "上次 218 ms", "bolt", "green"),
        ]),
        section("模型", [
            val("可用模型", "14 个"),
            nav("模型清单", "model-picker", "选择默认模型", "layers", "indigo"),
            nav("思考规则", "thinking-rules", "3 条", "brain", "purple"),
            nav("配额", "quota", "剩余 78%", "chart", "orange"),
        ]),
        section("", [
            btn("保存", "save", "filled"),
            btn("删除这个服务商", "confirm", "danger", "del-provider"),
        ]),
    ],
}

SCREENS["provider-add"] = {
    "title": "添加服务商",
    "blocks": [
        pick("类型", "form.provider.kind", ["Anthropic", "OpenAI", "兼容层", "Gemini"]),
        fld("名称", "form.provider.name", "自建中转站"),
        fld("接口地址", "form.provider.base", "https://…/v1", mono=True),
        fld("API Key", "form.provider.key", "sk-…", secure=True, mono=True),
        section("", [btn("保存并测试", "save", "filled")]),
    ],
}

SCREENS["provider-test"] = {    "title": "快速测试",
    "blocks": [
        hero("延迟 218 ms", "14 个模型全部可用"),
        section("", [
            val("首字节", "218 ms"),
            val("完整响应", "1.42 s"),
            val("模型", "Claude Sonnet 4.5"),
        ]),
        code("POST /v1/messages  200  application/json  1.4 KB", "http"),
        section("", [btn("再测一次", "action", "filled", "retest")]),
    ],
}

SCREENS["model-groups"] = {
    "title": "模型组",
    "blocks": [
        listblock("modelGroups",
                  {"title": "@name", "sub": "@models 个模型 · 默认 @fallback",
                   "icon": "layers", "color": "indigo"},
                  empty_title="还没有模型组"),
        section("", [btn("新建模型组", "action", "filled", "new-group", "plus")]),
        note("会话选「模型组」时按顺序降级：前一个失败自动换下一个。"),
    ],
}

SCREENS["model-group-detail"] = {
    "title": "写代码",
    "blocks": [
        fld("组名", "form.group.name", "写代码"),
        section("成员（按降级顺序）", [
            val("1", "Claude Sonnet 4.5", "Anthropic · 主"),
            val("2", "GPT-5.1", "OpenAI · 备"),
            val("3", "Gemini 3 Pro", "Gemini · 备"),
        ]),
        section("", [btn("添加成员", "action", "plain", "add-member", "plus")]),
    ],
}

SCREENS["model-picker"] = {
    "title": "选择模型",
    "blocks": [
        listblock("providers",
                  {"title": "@name", "sub": "@models 个模型", "icon": "key", "color": "blue"},
                  searchable=True, key="name"),
        note("点一行即切换当前会话模型，抽屉与输入框的模型标签会跟着变。"),
    ],
}

SCREENS["thinking-rules"] = {
    "title": "思考规则",
    "blocks": [
        section("", [tgl("自动延长思考", "prefs.thinking.auto", "复杂问题时放宽 token 预算")]),
        slider("思考预算", "prefs.thinking.budget", 0, 32000, 1000, " tok"),
        section("关键词触发", [
            val("命中词", "证明、为什么、设计一下"),
            val("规则数", "3"),
        ]),
    ],
}

SCREENS["agent-loop-models"] = {
    "title": "循环用模型",
    "blocks": [
        pick("主循环", "prefs.loop.main", ["Claude Sonnet 4.5", "GPT-5.1", "Gemini 3 Pro"]),
        pick("子任务", "prefs.loop.sub", ["GPT-5.1 mini", "Claude Haiku 4.5"]),
        pick("压缩摘要", "prefs.loop.compact", ["GPT-5.1 mini", "Gemini 3 Pro"]),
    ],
}

SCREENS["usage"] = {
    "title": "Token 用量",
    "blocks": [
        stat([("今天", "1.82M"), ("本周", "9.4M"), ("本月", "38.6M")]),
        _b("bars", series="usage.series", label="近 12 天"),
        section("", [
            val("今日花费", "¥ 12.40"),
            val("本周花费", "¥ 68.20"),
            val("本月花费", "¥ 271.90"),
            val("调用次数", "5,211"),
        ]),
        section("按模型", [
            prog("Claude Sonnet 4.5", 62, "23.9M"),
            prog("GPT-5.1", 28, "10.8M", "green"),
            prog("Gemini 3 Pro", 10, "3.9M", "orange"),
        ]),
    ],
}

SCREENS["relay-admin"] = {
    "title": "中转站后台",
    "blocks": [
        hero("在线", "relay.example.com · 14 个模型 · 3 个通道"),
        stat([("今日请求", "1,284"), ("成功率", "99.2%"), ("平均延迟", "1.8 s")]),
        section("通道", [
            val("anthropic-1", "正常 · 并发 4/16", "优先级 1"),
            val("openai-1", "正常 · 并发 2/16", "优先级 2"),
            val("backup", "待机", "优先级 9"),
        ]),
        section("", [
            btn("测速全部通道", "action", "plain", "relay-speed", "bolt"),
            btn("打开管理页", "action", "plain", "relay-open", "globe"),
        ]),
    ],
}

SCREENS["relay-router"] = {
    "title": "路由器后台",
    "blocks": [
        seg("路由模式", "prefs.relay.mode", ["自动", "按域名", "全部走中转", "全部直连"]),
        fld("中转地址", "prefs.relay.base", "http://192.168.1.1:8080", mono=True),
        fld("路由器账号", "prefs.relay.user", "admin"),
        fld("路由器密码", "prefs.relay.pass", "••••••", secure=True),
        section("规则", [
            val("规则文件", "route-rules.json", "47 行 · 8 条规则", mono=True),
            val("最后加载", "16:40:11"),
            nav("查看匹配日志", "logs", "1 条 error", "doc", "gray"),
        ]),
        section("", [btn("重新加载规则", "action", "filled", "reload-rules", "refresh")]),
    ],
}

SCREENS["appearance"] = {
    "title": "外观",
    "blocks": [
        seg("主题", "prefs.theme", ["跟随系统", "浅色", "深色"]),
        _b("swatches", title="强调色", bind="prefs.accent"),
        seg("字号", "prefs.textSize", ["小", "标准", "大", "特大"]),
        seg("行密度", "prefs.density", ["紧凑", "标准", "宽松"]),
        section("", [
            tgl("圆角材质", "prefs.material", "iOS 26 液态玻璃"),
            tgl("降低动效", "prefs.reduceMotion", "关闭抽屉与页面转场动画"),
        ]),
        section("预览", [
            val("示例行", "在这里看到的效果就是全局效果", "字体与密度实时生效", "brush", "indigo"),
        ]),
    ],
}

SCREENS["background"] = {
    "title": "背景与材质",
    "blocks": [
        seg("材质", "prefs.bg.material", ["纯色", "毛玻璃", "液态玻璃", "图片"]),
        slider("模糊半径", "prefs.bg.blur", 0, 60, 1, " px"),
        slider("不透明度", "prefs.bg.alpha", 40, 100, 1, " %"),
        seg("深浅", "prefs.bg.tone", ["跟随主题", "偏亮", "偏暗"]),
    ],
}

SCREENS["agent-tools"] = {
    "title": "工具开关",
    "blocks": [
        listblock("tools",
                  {"title": "@name", "sub": "@desc", "toggle": "prefs.tools.@id",
                   "badge": "@group"},
                  searchable=True, empty_title="没有工具"),
        note("关掉的工具在对话里不会出现，也不会被模型调用。开关状态同步到输入框上方的工具徽章。"),
    ],
}

SCREENS["sub-agents"] = {
    "title": "子代理",
    "blocks": [
        listblock("subAgents",
                  {"title": "@name", "sub": "@desc · @model",
                   "toggle": "prefs.subAgents.@id"},
                  searchable=False, empty_title="没有子代理"),
        section("", [btn("新建子代理", "action", "plain", "new-subagent", "plus")]),
    ],
}

SCREENS["skills"] = {
    "title": "技能",
    "blocks": [
        listblock("skills",
                  {"title": "@name", "sub": "@desc", "badge": "@source",
                   "toggle": "prefs.skills.@id"},
                  searchable=True, empty_title="没有技能", empty_sub="放一个 SKILL.md 进来"),
        section("", [
            nav("从 GitHub 安装", "skills-install", "粘贴仓库地址", "download", "blue"),
            btn("重新扫描", "action", "plain", "rescan-skills", "refresh"),
        ]),
    ],
}

SCREENS["skills-install"] = {
    "title": "安装技能",
    "blocks": [
        fld("仓库地址", "form.skill.url", "https://github.com/…/skill", mono=True),
        section("", [btn("拉取并安装", "action", "filled", "install-skill")]),
        note("只支持含 SKILL.md 的仓库或子目录。"),
    ],
}

SCREENS["soul"] = {
    "title": "灵魂",
    "blocks": [
        pick("人格", "prefs.soul.persona", ["海鸥（默认）", "严谨工程师", "安静助手"]),
        seg("语气", "prefs.soul.tone", ["直接", "中性", "温和"]),
        slider("啰嗦程度", "prefs.soul.verbosity", 0, 100, 5, ""),
        section("", [tgl("保留口头禅", "prefs.soul.catchphrase", "「你要整点薯条吗」")]),
        _b("textarea", title="自定义补充", bind="prefs.soul.extra",
           ph="想让它在什么情况下改变行为？"),
    ],
}

SCREENS["memory"] = {
    "title": "记忆",
    "blocks": [
        stat([("条数", "142"), ("体积", "18.4 KB"), ("最后写入", "14:20")]),
        listblock("artifacts",
                  {"title": "@name", "sub": "@session · @time", "badge": "@size"},
                  searchable=True, key="name", empty_title="没有记忆条目"),
        section("", [
            btn("导出为 Markdown", "action", "plain", "export-memory", "download"),
            btn("清空全部", "confirm", "danger", "clear-memory"),
        ]),
    ],
}

SCREENS["mcp"] = {
    "title": "MCP 集成",
    "blocks": [
        listblock("mcps",
                  {"title": "@name", "sub": "@transport · @tools 个工具",
                   "toggle": "prefs.mcp.@id"},
                  searchable=False, empty_title="没有 MCP 服务器"),
        section("", [
            nav("添加服务器", "mcp-form", "手填或粘贴 JSON", "plus", "teal"),
            btn("导入 JSON", "action", "plain", "mcp-import", "download"),
        ]),
    ],
}

SCREENS["mcp-detail"] = {
    "title": "filesystem",
    "blocks": [
        val("传输", "stdio"),
        val("命令", "npx -y @modelcontextprotocol/server-filesystem /root", mono=True),
        val("工具", "11 个"),
        section("工具清单", [
            val("read_file", "读文件", mono=True),
            val("write_file", "写文件", mono=True),
            val("list_directory", "列目录", mono=True),
            val("search_files", "按模式搜", mono=True),
        ]),
        section("", [btn("测试连接", "action", "filled", "mcp-test")]),
    ],
}

SCREENS["mcp-form"] = {
    "title": "添加 MCP 服务器",
    "blocks": [
        fld("名称", "form.mcp.name", "filesystem"),
        pick("传输", "form.mcp.transport", ["stdio", "http", "sse"]),
        fld("命令 / 地址", "form.mcp.cmd", "npx -y …", mono=True),
        _b("textarea", title="或粘贴 JSON", bind="form.mcp.json",
           ph='{"mcpServers":{"fs":{"command":"npx","args":["-y","…"]}}}'),
        section("", [btn("保存", "save", "filled")]),
    ],
}

SCREENS["env-vars"] = {
    "title": "环境变量",
    "blocks": [
        listblock("envVars",
                  {"title": "@k", "sub": "@v", "mono": True, "badge": "secret"},
                  searchable=False, key="k", empty_title="没有变量"),
        section("", [btn("添加变量", "action", "plain", "new-env", "plus")]),
        note("密钥类变量在沙箱里以环境变量注入，不写进 shell 历史。"),
    ],
}

SCREENS["storage"] = {
    "title": "存储",
    "blocks": [
        hero("已用 21.4 GB", "共 64 GB · 剩 42.6 GB"),
        prog("整体", 33, "21.4 GB / 64 GB"),
        section("占用明细", []),
        _b("storageItems", src="storage.items"),
        section("", [
            btn("清理缓存", "action", "plain", "purge-cache", "trash"),
            btn("管理根文件系统", "nav", "plain", "rootfs", "archive"),
        ]),
    ],
}

SCREENS["shared-folders"] = {
    "title": "共享文件夹",
    "blocks": [
        listblock("folders",
                  {"title": "@name", "sub": "@path", "badge": "读写"},
                  searchable=False, empty_title="没有共享目录"),
        section("", [btn("添加文件夹", "action", "plain", "add-folder", "plus")]),
    ],
}

SCREENS["mounted-folders"] = {
    "title": "挂载外部文件夹",
    "blocks": [
        listblock("mounts",
                  {"title": "@name", "sub": "@proto · @host@path", "badge": "@state"},
                  searchable=False, empty_title="没有挂载"),
        section("", [nav("添加挂载", "mount-detail", "SMB / SFTP / WebDAV", "plus", "orange")]),
    ],
}

SCREENS["mount-detail"] = {
    "title": "NAS",
    "blocks": [
        pick("协议", "form.mount.proto", ["SMB", "SFTP", "WebDAV", "NFS"]),
        fld("主机", "form.mount.host", "192.168.1.20", mono=True),
        fld("路径", "form.mount.path", "/volume1/share", mono=True),
        fld("账号", "form.mount.user", ""),
        fld("密码", "form.mount.pass", "••••••", secure=True),
        section("", [
            btn("挂载", "action", "filled", "mount-now"),
            btn("卸载", "action", "danger", "unmount"),
        ]),
    ],
}

SCREENS["icloud-sync"] = {
    "title": "iCloud 同步",
    "blocks": [
        hero("已同步", "上次 3 分钟前 · iPad Pro"),
        stat([("会话", "24"), ("冲突", "0"), ("队列", "0")]),
        section("", [
            tgl("自动同步", "prefs.sync.auto", "改动后 30 秒内推送"),
            nav("同步详情", "sync-migration", "查看待传与已传条目", "cloud", "cyan"),
        ]),
        section("", [btn("立即同步", "action", "filled", "sync-now", "refresh")]),
    ],
}

SCREENS["sync-migration"] = {
    "title": "同步详情",
    "blocks": [
        section("待处理", [empty("没有待传条目", "队列是空的")]),
        section("近期", [
            val("会话 s1", "16:42 已传"),
            val("产物 a2", "16:41 已传"),
            val("设置", "16:30 已传"),
        ]),
    ],
}

SCREENS["backup"] = {
    "title": "备份与恢复",
    "blocks": [
        hero("今天 04:00 成功", "1.82 GB · 12,480 个文件"),
        section("", [
            nav("备份设置", "backup-settings", "每天 04:00 · 仅 Wi-Fi", "clock", "gray"),
            nav("备份历史", "backup-history", "3 份", "doc", "gray"),
            nav("恢复", "backup-restore", "从某份备份还原", "refresh", "orange"),
            nav("跳过清单", "backup-skipped", "2 个文件", "ban", "gray"),
        ]),
        section("", [btn("立即备份", "action", "filled", "backup-now", "cloud")]),
    ],
}

SCREENS["backup-settings"] = {
    "title": "备份设置",
    "blocks": [
        tgl("自动备份", "prefs.backup.auto", "每天一次"),
        seg("频率", "prefs.backup.freq", ["每天", "每 3 天", "每周"]),
        tgl("仅 Wi-Fi", "prefs.backup.wifi", "蜂窝下不备份"),
        nav("备份位置", "backup-destination", "iCloud Drive", "cloud", "cyan"),
        pick("保留份数", "prefs.backup.keep", ["3", "7", "14", "30"]),
    ],
}

SCREENS["backup-history"] = {
    "title": "备份历史",
    "blocks": [
        listblock("backups",
                  {"title": "@when", "sub": "@kind · @files 个文件 · @size",
                   "badge": "@state"},
                  searchable=False, empty_title="没有备份"),
    ],
}

SCREENS["backup-restore"] = {
    "title": "恢复",
    "blocks": [
        note("恢复会覆盖当前数据。恢复前会自动做一份「恢复前」备份。"),
        listblock("backups",
                  {"title": "@when", "sub": "@size · @files 个文件",
                   "badge": "@state"},
                  searchable=False, empty_title="没有可恢复的备份"),
        section("", [btn("从选中备份恢复", "confirm", "danger", "restore")]),
    ],
}

SCREENS["backup-destination"] = {
    "title": "备份位置",
    "blocks": [
        listblock("folders",
                  {"title": "@name", "sub": "@path"},
                  searchable=False, empty_title="没有可用位置"),
        section("", [btn("选择其他位置", "action", "plain", "pick-dest", "folder")]),
    ],
}

SCREENS["backup-skipped"] = {
    "title": "跳过清单",
    "blocks": [
        val("node_modules/", "目录 · 12,204 个文件", mono=True),
        val("*.tmp", "模式 · 2 个文件", mono=True),
        note("跳过的内容可以在备份设置里改。"),
    ],
}

SCREENS["github"] = {
    "title": "GitHub 账号",
    "blocks": [
        hero("vipios", "已授权 · repo, workflow"),
        section("", [
            val("仓库", "vipios/quanneng-ai"),
            val("默认分支", "main"),
            tgl("云端编译兜底", "prefs.github.fallback", "本机构建失败时转 Actions"),
            nav("编译历史", "build-history", "最近 3 次", "clock", "gray"),
        ]),
        section("", [btn("退出登录", "confirm", "danger", "github-logout")]),
    ],
}

SCREENS["build-history"] = {
    "title": "编译历史",
    "blocks": [
        val("16:12", "成功 · 8 分 42 秒", "macos-14 · workflow_dispatch"),
        val("昨天", "失败 · 链接错误", "ish.a 未找到 arm64 切片"),
        val("11-08", "成功 · 9 分 10 秒", ""),
    ],
}

SCREENS["permissions"] = {
    "title": "工具权限",
    "blocks": [
        listblock("tools",
                  {"title": "@name", "sub": "@desc", "badge": "允许"},
                  searchable=False, empty_title="没有权限项"),
        note("拒掉的工具即使模型调用也会被拦下，并回一条「已拒绝」给模型。"),
    ],
}

SCREENS["faceid"] = {
    "title": "Face ID 保护",
    "blocks": [
        tgl("启动时验证", "prefs.faceid.launch", "冷启动要求 Face ID"),
        tgl("回到前台验证", "prefs.faceid.resume", "超过 1 分钟回前台再验一次"),
        seg("超时", "prefs.faceid.timeout", ["立即", "1 分钟", "5 分钟", "从不"]),
    ],
}

SCREENS["logs"] = {
    "title": "日志",
    "blocks": [
        seg("级别", "prefs.logs.level", ["全部", "info", "warn", "error"]),
        _b("logs", src="logs"),
        section("", [
            btn("导出", "action", "plain", "export-logs", "download"),
            btn("清空", "confirm", "danger", "clear-logs"),
        ]),
    ],
}

SCREENS["crash-diagnostics"] = {
    "title": "崩溃诊断",
    "blocks": [
        listblock("crashes",
                  {"title": "@kind", "sub": "@when · @where", "badge": "报告"},
                  searchable=False, empty_title="没有崩溃记录", empty_sub="这是好事"),
        section("", [
            tgl("收集 MetricKit", "prefs.crash.metrickit", "崩溃与卡顿指标"),
            btn("立即上传", "action", "plain", "upload-crash", "cloud"),
        ]),
    ],
}

SCREENS["config-audit"] = {
    "title": "配置审计",
    "blocks": [
        hero("无冲突", "检查了 42 个配置文件"),
        section("", [
            val("UserDefaults", "一致"),
            val("route-rules.json", "一致"),
            val("mcp.json", "一致"),
        ]),
        section("", [btn("重新检查", "action", "filled", "audit-now", "check")]),
    ],
}

SCREENS["version"] = {
    "title": "版本",
    "blocks": [
        val("版本", "1.0", "build 37"),
        val("渠道", "自有源"),
        val("设备", "iPhone 16 Pro · iOS 18.2"),
        val("根文件系统", "Alpine 3.20.3 · aarch64"),
        nav("更新源", "update-source", "GitHub · 自有", "globe", "gray"),
    ],
}

SCREENS["check-update"] = {
    "title": "检查更新",
    "blocks": [
        hero("已是最新", "1.0 (build 37) · 3 分钟前检查"),
        section("", [
            btn("再检查一次", "action", "filled", "check-update-now", "refresh"),
            nav("更新源", "update-source", "GitHub · 自有", "globe", "gray"),
        ]),
    ],
}

SCREENS["update-source"] = {
    "title": "更新源",
    "blocks": [
        seg("来源", "prefs.update.source", ["自有源", "App Store", "不检查"]),
        fld("清单地址", "prefs.update.manifest", "https://…/appcast.json", mono=True),
        tgl("包含测试版", "prefs.update.beta", ""),
    ],
}

SCREENS["about"] = {
    "title": "关于",
    "blocks": [
        hero("全能AI", "1.0 · 本地优先的 AI 操作员"),
        section("", [
            val("开源许可", "GPL-3.0"),
            val("第三方组件", "iSH · proot · FFmpeg · LAME"),
            nav("隐私政策", "privacy", "", "doc", "gray"),
            nav("反馈", "feedback", "", "mail", "gray"),
        ]),
        note("所有会话、产物、记忆默认只在本机。"),
    ],
}

SCREENS["privacy"] = {
    "title": "隐私政策",
    "blocks": [
        txt("会话记录、产物、记忆、日志默认只保存在本机；只有你主动开启同步或备份时才离开设备。", "body"),
        txt("服务商 API Key 存放在 Keychain，模板与原生层都不做明文落盘。", "body"),
        txt("崩溃诊断在你同意后才上传，上传前会脱敏路径与账号。", "body"),
    ],
}

SCREENS["feedback"] = {
    "title": "反馈",
    "blocks": [
        fld("标题", "form.feedback.title", "一句话说清"),
        _b("textarea", title="详情", bind="form.feedback.body",
           ph="复现步骤、期望行为、实际行为"),
        section("", [btn("发送", "action", "filled", "send-feedback", "mail")]),
    ],
}

SCREENS["rootfs"] = {
    "title": "根文件系统",
    "blocks": [
        hero("Alpine 3.20.3", "1.24 GB · 412 个包 · aarch64"),
        section("", [
            nav("浏览文件", "file-browser", "/ 根目录", "folder", "blue"),
            nav("终端", "terminal", "在沙箱里执行", "terminal", "green"),
            nav("镜像测速", "mirror-test", "3 个源", "bolt", "orange"),
            nav("AOJIT 设置", "aojit", "即时编译 · 已启用", "cpu", "purple"),
        ]),
        section("", [
            btn("更新系统", "action", "plain", "rootfs-update", "refresh"),
            btn("重置根文件系统", "confirm", "danger", "rootfs-reset"),
        ]),
    ],
}

SCREENS["file-browser"] = {
    "title": "/",
    "blocks": [
        listblock("rootfs.files",
                  {"title": "@name", "sub": "@size", "icon": "folder"},
                  searchable=False, key="name", empty_title="空目录"),
        note("点目录进入，点文件预览。写操作会提示确认。"),
    ],
}

SCREENS["terminal"] = {
    "title": "终端",
    "blocks": [term("rootfs.terminal")],
}

SCREENS["mirror-test"] = {
    "title": "镜像测速",
    "blocks": [
        listblock("rootfs.mirrors",
                  {"title": "@name", "sub": "@url", "badge": "@ms ms"},
                  searchable=False, empty_title="没有源"),
        section("", [btn("重新测速", "action", "filled", "mirror-retest", "bolt")]),
    ],
}

SCREENS["aojit"] = {
    "title": "AOJIT",
    "blocks": [
        tgl("启用即时编译", "prefs.aojit.on", "沙箱里跑 JIT 需要这个"),
        seg("模式", "prefs.aojit.mode", ["自动", "强制", "关闭"]),
        val("上次恢复", "11-09 22:14", "JIT 句柄已重建"),
    ],
}

SCREENS["alarms"] = {
    "title": "闹钟",
    "blocks": [
        listblock("alarms",
                  {"title": "@time", "sub": "@label · @days", "toggle": "prefs.alarms.@id",
                   "badge": "任务"},
                  searchable=False, empty_title="没有闹钟"),
        section("", [btn("新建闹钟任务", "action", "plain", "new-alarm", "plus")]),
        section("任务详情", [
            nav("晨间时间线播报", "scheduled-task", "3 步 · 每天 07:30", "doc", "gray"),
        ]),
    ],
}

SCREENS["artifacts"] = {
    "title": "全部产物",
    "blocks": [
        listblock("artifacts",
                  {"title": "@name", "sub": "@session · @time", "badge": "@size"},
                  searchable=True, key="name", empty_title="还没有产物",
                  empty_sub="对话里生成的文件会出现在这里"),
    ],
}

SCREENS["session-skills"] = {
    "title": "本会话技能",
    "blocks": [
        note("只对当前会话生效，会覆盖全局技能开关。"),
        listblock("skills",
                  {"title": "@name", "sub": "@desc", "badge": "@source"},
                  searchable=True, empty_title="没有技能"),
    ],
}

SCREENS["session-memory"] = {
    "title": "本会话记忆",
    "blocks": [
        stat([("条数", "12"), ("体积", "1.6 KB")]),
        listblock("artifacts",
                  {"title": "@name", "sub": "@time"},
                  searchable=True, key="name", empty_title="没有记忆"),
    ],
}

SCREENS["session-mcps"] = {
    "title": "本会话 MCP",
    "blocks": [
        note("只挂当前会话的 MCP 服务器，退出会话即卸载。"),
        listblock("mcps",
                  {"title": "@name", "sub": "@transport · @tools 个工具",
                   "toggle": "prefs.sessionMcp.@id"},
                  searchable=False, empty_title="没有服务器"),
    ],
}

SCREENS["session-model"] = {
    "title": "本会话模型",
    "blocks": [
        pick("模型", "prefs.model", ["Claude Sonnet 4.5", "GPT-5.1", "Gemini 3 Pro",
                                     "GPT-5.1 mini"]),
        tgl("允许降级", "prefs.modelOpts.fallback", "失败时换模型组里的下一个"),
        slider("温度", "prefs.modelOpts.temp", 0, 100, 1, ""),
    ],
}

SCREENS["scheduled-task"] = {
    "title": "定时任务",
    "blocks": [
        val("时间", "每天 07:30"),
        val("动作", "抓 X 时间线 → 总结 → 语音播报", "3 步"),
        tgl("失败重试", "prefs.task.retry", "最多 2 次"),
        section("最近运行", [
            val("今天 07:30", "成功 · 42 秒"),
            val("昨天 07:30", "成功 · 38 秒"),
        ]),
    ],
}

SCREENS["share-select"] = {
    "title": "选择对话",
    "blocks": [
        listblock("sessions",
                  {"title": "@title", "sub": "@preview", "badge": "@artifacts"},
                  searchable=True, empty_title="没有会话"),
        section("", [btn("导出所选", "action", "filled", "export-chat", "download")]),
    ],
}

SCREENS["browser"] = {
    "title": "浏览器",
    "blocks": [
        fld("地址", "form.browser.url", "https://", mono=True),
        section("", [
            nav("标签页池", "browser-manage", "4 个标签 · 1 个运行中", "layers", "blue"),
            nav("历史", "browser-history", "今天 18 条", "clock", "gray"),
        ]),
        note("浏览器由智能体驱动，也可以手动接管。"),
    ],
}

SCREENS["browser-manage"] = {
    "title": "标签页池",
    "blocks": [
        val("tab-1", "运行中 · example.com", "最近活动 12 秒前"),
        val("tab-2", "空闲 · github.com", ""),
        val("tab-3", "空闲 · 空白页", ""),
        section("", [btn("回收空闲标签", "action", "plain", "reap-tabs", "trash")]),
    ],
}

SCREENS["browser-history"] = {
    "title": "浏览历史",
    "blocks": [
        val("16:20", "example.com/docs", "智能体"),
        val("15:58", "github.com/vipios", "智能体"),
        val("15:31", "news.ycombinator.com", "手动"),
    ],
}

SCREENS["quota"] = {
    "title": "配额",
    "blocks": [
        hero("剩余 78%", "5 小时窗口 · 14 天后重置"),
        prog("已用", 22, "22%"),
        section("", [
            val("窗口", "5 小时滚动"),
            val("重置", "14 天后"),
            val("限速", "未触发"),
        ]),
        note("额度取自服务商返回的响应头，读不到时显示为「不限」。"),
    ],
}

# 会话上下文（对话页右上角菜单进这里，再分发到各子页）
SCREENS["context"] = {
    "title": "本会话",
    "blocks": [
        hero("越狱插件 dylib 注入分析", "3 个产物 · Claude Sonnet 4.5"),
        section("会话设置", [
            nav("模型", "session-model", "Claude Sonnet 4.5", "layers", "indigo"),
            nav("技能", "session-skills", "5 个 · 覆盖全局", "puzzle", "blue"),
            nav("记忆", "session-memory", "12 条", "brain", "purple"),
            nav("MCP", "session-mcps", "1 个挂载中", "stack", "teal"),
        ]),
        section("内容", [
            nav("产物", "artifacts", "全部会话 6 个", "archive", "blue"),
            nav("定时任务", "alarms", "2 个", "clock", "gray"),
            nav("导出 / 分享", "share-select", "选会话导出", "download", "gray"),
            nav("浏览器", "browser", "智能体驱动", "globe", "cyan"),
        ]),
    ],
}

# ── 抽屉（叠在对话上的那层） ──────────────────────────────────────

DRAWER = {
    "width": 318,
    "searchPlaceholder": "搜索对话与产物",
    "groups": ["置顶", "今天", "昨天", "本周"],
    "footer": [
        {"id": "context", "title": "本会话", "icon": "layers"},
        {"id": "artifacts", "title": "全部产物", "icon": "archive"},
        {"id": "alarms", "title": "定时任务", "icon": "clock"},
    ],
    "primary": {"id": "new-chat", "title": "新建任务", "icon": "plus"},
    "gear": "settings",
}

# ── 默认状态（联动起点） ──────────────────────────────────────────

DEFAULTS = {
    "prefs": {
        "theme": "跟随系统",
        "accent": "蓝",
        "textSize": "标准",
        "density": "标准",
        "material": True,
        "reduceMotion": False,
        "bg": {"material": "液态玻璃", "blur": 24, "alpha": 82, "tone": "跟随主题"},
        "tools": {"shell": True, "browser": True, "agents": True, "files": True,
                  "health": False, "calendar": True, "reminders": True,
                  "contacts": False, "clipboard": True, "media": True,
                  "alarms": False, "http": True},
        "subAgents": {"sa1": True, "sa2": True, "sa3": False},
        "skills": {"k1": True, "k2": True, "k3": True, "k4": False, "k5": True},
        "mcp": {"m1": True, "m2": True, "m3": False},
        "sessionMcp": {"m1": True, "m2": False, "m3": False},
        "relay": {"mode": "自动", "base": "http://192.168.1.1:8080",
                  "user": "admin", "pass": "••••••"},
        "thinking": {"auto": True, "budget": 8000},
        "loop": {"main": "Claude Sonnet 4.5", "sub": "GPT-5.1 mini",
                 "compact": "GPT-5.1 mini"},
        "model": "Claude Sonnet 4.5",
        "modelOpts": {"fallback": True, "temp": 30},
        "soul": {"persona": "海鸥（默认）", "tone": "直接", "verbosity": 35,
                 "catchphrase": True, "extra": ""},
        "sync": {"auto": True},
        "backup": {"auto": True, "freq": "每天", "wifi": True, "keep": "7"},
        "github": {"fallback": True},
        "faceid": {"launch": True, "resume": True, "timeout": "1 分钟"},
        "logs": {"level": "全部"},
        "crash": {"metrickit": True},
        "update": {"source": "自有源", "manifest": "", "beta": False},
        "aojit": {"on": True, "mode": "自动"},
        "task": {"retry": True},
        "alarms": {"al1": True, "al2": False},
    },
    "ui": {"page": "home", "stack": [], "drawer": False, "sheet": None},
    "session": "s1",
    "sessionNames": {},
    "form": {"provider": {"kind": "兼容层", "name": "", "base": "", "key": ""},
             "group": {"name": "写代码"}, "skill": {"url": ""},
             "mcp": {"name": "", "transport": "stdio", "cmd": "", "json": ""},
             "mount": {"proto": "SMB", "host": "", "path": "", "user": "", "pass": ""},
             "feedback": {"title": "", "body": ""}, "browser": {"url": ""}},
}
