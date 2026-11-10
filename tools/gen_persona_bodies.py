#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从 资源/人格/*.md 重新生成 PersonaBodies.swift。

为什么存在：8 套人格正文的唯一真源是 资源/人格/ 下的 md 文件（用户改
自称、改命名都在 md 上改）。App 里注入正文用的是硬编码的 Swift 常量
（PersonaBodies.swift），md 和 Swift 必须一致，否则「选人格」注入的是
旧正文。

生成规则：
  1. 剥离 YAML frontmatter（开头 --- 到 --- 之间）
  2. 正文原样嵌入 static let <id>: String = 三引号字符串
  3. 加 static func body(for:) 按 id 查询
  4. 常量 id 与 PersonaCatalog / RoutePersona 里的 id 一一对应

用法：
    python tools/gen_persona_bodies.py
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MD_DIR = os.path.join(ROOT, "..", "资源", "人格")
OUT = os.path.join(ROOT, "src", "ios", "Views", "Skills", "Domain", "PersonaBodies.swift")

# 文件名 -> 常量 id（顺序即 PersonaBodies 里的声明顺序）
FILES = [
    ("01-实战全能.md", "seagull"),
    ("02-深度逆向.md", "jeli"),
    ("03-极速直出.md", "sol"),
    ("04-CTF强攻.md", "omega"),
    ("05-轻量编码.md", "codex"),
    ("06-规则路由.md", "s"),
    ("07-沙箱执行.md", "sandbox"),
    ("08-全能执行.md", "omni"),
]


def strip_frontmatter(text: str) -> str:
    """剥离开头的 YAML frontmatter（--- ... ---）。"""
    if text.startswith("---"):
        # 找第二个 --- 之后的内容
        parts = text.split("---", 2)
        if len(parts) >= 3:
            return parts[2].lstrip("\n")
    return text


def main():
    if not os.path.isdir(MD_DIR):
        sys.exit("找不到 md 目录: %s" % MD_DIR)

    bodies = []
    for fname, cid in FILES:
        path = os.path.join(MD_DIR, fname)
        if not os.path.exists(path):
            sys.exit("缺 md 文件: %s" % path)
        body = strip_frontmatter(open(path, encoding="utf-8").read())
        # 末尾去掉多余空白，保留正文内部换行
        body = body.rstrip() + "\n"
        # 三引号冲突检查
        if '"""' in body:
            sys.exit("%s 正文含三引号冲突" % fname)
        # 反斜杠转义：Swift 三引号字符串里 `\` 仍是转义字符，
        # 正文里的字面反斜杠（如 `人格\*.txt`、`gau DOMAIN \| anew`、
        # 正则 `\d`、路径）必须写成 `\\` 才能原样保留。
        # md 是纯文本，反斜杠都是字面量，无「意图转义」的 \n，直接全转。
        body = body.replace("\\", "\\\\")
        bodies.append((cid, body))

    header = (
        "//\n"
        "//  PersonaBodies.swift\n"
        "//  全能AI - 8 套人格的完整 system prompt 正文\n"
        "//\n"
        "//  数据来源：产出/2026-11-08_OpenMinis改造/资源/人格/*.md\n"
        "//  由 tools/gen_persona_bodies.py 生成，勿手改。\n"
        "//\n"
        "\n"
        "enum PersonaBodies {\n"
    )

    decls = []
    for cid, body in bodies:
        decls.append(
            "\n    /// 人格 id = %s 的完整正文。\n"
            "    static let %s: String = \"\"\"\n%s\"\"\"\n" % (cid, cid, body)
        )

    # body(for:) 查询函数
    cases = "\n".join(
        '        case "%s": return %s' % (cid, cid) for cid, _ in bodies
    )
    query = (
        "\n    /// 按人格 id 取正文；找不到返回空串。\n"
        "    static func body(for id: String) -> String {\n"
        "        switch id {\n"
        "%s\n"
        "        default: return \"\"\n"
        "        }\n"
        "    }\n"
        "}\n" % cases
    )

    content = header + "".join(decls) + query
    open(OUT, "w", encoding="utf-8").write(content)
    print("OK 生成 %s，共 %d 套人格" % (OUT, len(bodies)))


if __name__ == "__main__":
    main()
