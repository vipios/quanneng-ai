# -*- coding: utf-8 -*-
"""把 spec/ + src/ 打成单文件 ui.html，并做一致性校验。

用法：
    python tools/uitemplate/build.py            # 构建
    python tools/uitemplate/build.py --check    # 只校验不写盘

产物：src/ios/Resources/UITemplate/ui.html（Xcode 已把这个目录作为 folder resource 打进包）

为什么是「生成」而不是手写大文件：
  1) 45 个界面共用一套块结构，手写会漂；
  2) 规格里加一页 = 改 spec，不碰引擎；
  3) 校验能拦住「跳转到不存在的页面」这种死链。
"""

import json
import os
import re
import sys
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "src", "ios", "Resources", "UITemplate", "ui.html")

sys.path.insert(0, os.path.join(HERE, "spec"))

import data as data_mod          # noqa: E402
import screens as screens_mod    # noqa: E402

SPEC = {
    "screens": screens_mod.SCREENS,
    "drawer": screens_mod.DRAWER,
}
DATA = data_mod.DATA
DEFAULTS = screens_mod.DEFAULTS


def collect_pages(node, acc, where):
    """从块树里收集所有跳转目标。"""
    if isinstance(node, dict):
        if node.get("t") == "row" and node.get("page"):
            acc.append((node["page"], where))
        for k, v in node.items():
            collect_pages(v, acc, where)
    elif isinstance(node, list):
        for v in node:
            collect_pages(v, acc, where)


def edges_of(sid):
    """一个页面的所有出边：nav 行、action=nav 的按钮、列表项自带的 page。"""
    sdef = SPEC["screens"].get(sid) or {}
    out = []

    def walk(node):
        if isinstance(node, dict):
            if node.get("t") == "row" and node.get("page"):
                out.append(node["page"])
            if node.get("t") == "btn" and node.get("action") == "nav" and node.get("arg"):
                out.append(node["arg"])
            if node.get("t") == "list" and node.get("src"):
                for item in (DATA.get(node["src"]) or []):
                    if isinstance(item, dict) and item.get("page"):
                        out.append(item["page"])
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(sdef.get("blocks", []))
    return out


def validate():
    errors, warnings = [], []
    screens = SPEC["screens"]

    # 1) 跳转目标存在性
    targets = []
    for sid, sdef in screens.items():
        collect_pages(sdef.get("blocks", []), targets, sid)
    for row in SPEC["drawer"]["footer"]:
        targets.append((row["id"], "drawer.footer"))
    targets.append((SPEC["drawer"]["gear"], "drawer.gear"))

    for page, where in targets:
        if page not in screens:
            errors.append("死链：%s 跳转到不存在的页面 %r" % (where, page))

    # 2) 可达性：home 出发，含抽屉底栏、齿轮、对话页导航栏
    graph = {sid: edges_of(sid) for sid in screens}
    graph.setdefault("home", [])
    graph["home"] += [r["id"] for r in SPEC["drawer"]["footer"]]
    graph["home"] += [SPEC["drawer"]["gear"], "artifacts", "settings"]

    seen, stack = set(), ["home"]
    while stack:
        cur = stack.pop()
        if cur in seen or cur not in screens:
            continue
        seen.add(cur)
        stack.extend(graph.get(cur, []))
    orphans = sorted(set(screens) - seen)
    for o in orphans:
        warnings.append("不可达：%s（没有任何页面跳到它）" % o)

    # 3) 数据源存在性
    srcs = set()

    def walk_src(node):
        if isinstance(node, dict):
            for k in ("src", "series"):
                if node.get(k):
                    srcs.add(node[k])
            for v in node.values():
                walk_src(v)
        elif isinstance(node, list):
            for v in node:
                walk_src(v)

    walk_src(screens)

    def has(path):
        cur = DATA
        for part in path.split("."):
            if not isinstance(cur, dict) or part not in cur:
                return False
            cur = cur[part]
        return True

    for s in sorted(srcs):
        if not has(s):
            errors.append("数据源缺失：DATA.%s（被某个块引用）" % s)

    # 4) 绑定路径存在性（只警告：可能指向用户新建的表单字段）
    binds = set()

    def walk_bind(node):
        if isinstance(node, dict):
            for k in ("bind", "toggle"):
                v = node.get(k)
                if v and "@" not in v:
                    binds.add(v)
            for v in node.values():
                walk_bind(v)
        elif isinstance(node, list):
            for v in node:
                walk_bind(v)

    walk_bind(screens)

    def has_default(path):
        cur = DEFAULTS
        for part in path.split("."):
            if not isinstance(cur, dict) or part not in cur:
                return False
            cur = cur[part]
        return True

    for b in sorted(binds):
        if not has_default(b):
            warnings.append("绑定无默认值：%s（首帧为空）" % b)

    return errors, warnings, len(seen), len(screens)


HTML = """<!DOCTYPE html>
<html lang="zh-CN" data-theme="light" data-accent="蓝" data-size="标准" data-density="标准" data-motion="on">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, maximum-scale=1, user-scalable=no">
<meta name="format-detection" content="telephone=no">
<title>全能AI · 联动模板</title>
<style>
%(css)s
</style>
</head>
<body data-host="preview">
<div class="stage">
  <div class="phone">
    <div class="screen" id="mainScreen"></div>
    <div class="drawer-scrim" id="drawerScrim"></div>
    <aside class="drawer" id="drawer"></aside>
    <div class="sheet-layer" id="sheetLayer"></div>
    <div class="toast" id="toast"></div>
    <div class="dialog-layer" id="dialogLayer"></div>
  </div>
</div>

<!-- 规格与数据（由 tools/uitemplate/build.py 生成，不要手改本文件） -->
<script>
window.__SPEC__ = %(spec)s;
window.__DATA__ = %(data)s;
window.__DEFAULTS__ = %(defaults)s;
window.__BUILD__ = %(build)s;
</script>
<script>
%(js)s
</script>
</body>
</html>
"""


def build():
    errors, warnings, reachable, total = validate()

    print("界面总数：%d，可达：%d" % (total, reachable))
    for w in warnings:
        print("  [warn] " + w)
    if errors:
        for e in errors:
            print("  [ERROR] " + e)
        print("\n构建中止：先修规格。")
        return 1

    with open(os.path.join(HERE, "src", "app.css"), encoding="utf-8") as f:
        css = f.read()
    with open(os.path.join(HERE, "src", "app.js"), encoding="utf-8") as f:
        js = f.read()

    build_meta = {
        "at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "screens": total,
        "generator": "tools/uitemplate/build.py",
    }

    html = HTML % {
        "css": css,
        "spec": json.dumps(SPEC, ensure_ascii=False, separators=(",", ":")),
        "data": json.dumps(DATA, ensure_ascii=False, separators=(",", ":")),
        "defaults": json.dumps(DEFAULTS, ensure_ascii=False, separators=(",", ":")),
        "build": json.dumps(build_meta, ensure_ascii=False),
        "js": js,
    }

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(html)

    kb = len(html.encode("utf-8")) / 1024.0
    print("产物：%s" % OUT)
    print("大小：%.1f KB · 界面 %d 个 · 警告 %d 条" % (kb, total, len(warnings)))
    return 0


if __name__ == "__main__":
    if "--check" in sys.argv:
        errs, warns, reach, tot = validate()
        print("界面 %d / 可达 %d / 错误 %d / 警告 %d" % (tot, reach, len(errs), len(warns)))
        for e in errs:
            print("  [ERROR] " + e)
        sys.exit(1 if errs else 0)
    sys.exit(build())
