#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
交叉引用检查：新写的 Relay / GitHub 代码调用了哪些外部符号，逐个确认在仓库里存在。

编译器没装，只能做这种「符号在不在」的粗检。能拦住的最常见错误：
  · 调了一个不存在的方法（拼错、大小写错）
  · 用了不存在的枚举成员
  · 引用了没定义的 type
"""
import os
import re
import sys
import glob

SRC = "src/ios"

# 新代码所在的目录，每个目录里定义的 "前缀*" 类型都要能自洽
NEW_CODE_DIRS = [
    ("Views/Settings/Relay", r'Relay[A-Z]\w*', "Relay*"),
    ("Views/Settings/GitHub", r'GitHub[A-Z]\w*|Build[A-Z]\w*|LocalToolchain\w*|RepoFile|WorkflowRun', "GitHub*/Build*"),
]

# (调用方文件, 符号, 期望在哪些文件里出现)
CHECKS = [
    # 我们新写的
    ("RelayRoute.swift",            "enum RelayProbe",            None),
    ("RelayRoute.swift",            "enum RelayLocalNet",         None),
    ("RelayVault.swift",            "final class RelayVault",     None),
    ("RelayBackend.swift",          "enum RelayBackend",          None),
    ("RelayBackend.swift",          "enum RelayRouter",           None),
    ("RelayBackend.swift",          "struct RelayDeviceStatus",   None),
    ("RelayStore.swift",            "final class RelayStore",     None),
    ("RelayProviderSettings.swift", "enum RelayRouteMode",        None),
    ("RelayProviderSettings.swift", "final class RelayProfileStore", None),
    ("RelayProviderSettings.swift", "final class RelayProfileMirror", None),

    # GitHub 新写的
    ("GitHubAuth.swift",            "final class GitHubAuth",     None),
    ("GitHubAuth.swift",            "struct GitHubDeviceCode",    None),
    ("GitHubAuth.swift",            "struct GitHubAccount",       None),
    ("GitHubAuth.swift",            "enum GitHubAuthError",       None),
    ("GitHubPush.swift",            "final class GitHubPush",     None),
    ("GitHubPush.swift",            "enum GitHubPushError",       None),
    ("GitHubPush.swift",            "struct WorkflowRun",         None),
    ("GitHubStore.swift",           "final class GitHubStore",    None),
    ("BuildFallback.swift",         "enum BuildRoute",            None),
    ("BuildFallback.swift",         "struct BuildDecision",       None),
    ("BuildFallback.swift",         "enum BuildRouter",           None),
    ("BuildFallback.swift",         "enum LocalToolchainProbe",   None),
    ("GitHubAccountView.swift",     "struct GitHubAccountView",   None),

    # 我们依赖的外部符号（必须真实存在）
    ("RelayBackend.swift",          "func saveAPIKey",            "ProviderConfigStore.swift"),
    ("RelayBackend.swift",          "static let shared",          "ProviderConfigStore.swift"),
    ("AddRelayProviderView.swift",  "func addInstance",           "ProviderConfigStore.swift"),
    ("AddRelayProviderView.swift",  "func loadAPIKey",            "ProviderConfigStore.swift"),
    ("ProviderInstance.swift",      "case openAI",                "ProviderTypes.swift"),
    ("ProviderInstance.swift",      "case anthropic",             "ProviderTypes.swift"),
    ("ProviderInstance.swift",      "case apiKey",                "ProviderTypes.swift"),
]


def strip_comments_and_strings(src):
    """把注释和字符串字面量换成空格，保留换行与长度。

    不剥的话，像 "Minis.RelayAdmin.v1" 这样的盐、或者文件名注释
    `//  RelayProviderSettings.swift`，都会被 \\b(Relay[A-Z]\\w+) 当成类型引用，
    报出根本不存在的「未定义」。
    """
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        # 行注释
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                out.append(" ")
                i += 1
            continue
        # 块注释（Swift 允许嵌套）
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            depth = 0
            while i < n:
                if src.startswith("/*", i):
                    depth += 1
                    out.append("  ")
                    i += 2
                elif src.startswith("*/", i):
                    depth -= 1
                    out.append("  ")
                    i += 2
                    if depth == 0:
                        break
                else:
                    out.append("\n" if src[i] == "\n" else " ")
                    i += 1
            continue
        # 三引号多行字符串
        if src.startswith('"""', i):
            out.append("   ")
            i += 3
            while i < n and not src.startswith('"""', i):
                out.append("\n" if src[i] == "\n" else " ")
                i += 1
            if i < n:
                out.append("   ")
                i += 3
            continue
        # 普通字符串
        if c == '"':
            out.append(" ")
            i += 1
            while i < n and src[i] != '"':
                if src[i] == "\\" and i + 1 < n:
                    out.append("  ")
                    i += 2
                    continue
                out.append("\n" if src[i] == "\n" else " ")
                i += 1
            if i < n:
                out.append(" ")
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def norm(p):
    """统一成 / 分隔的相对路径，供 dict 键与 glob 结果对齐。

    Windows 上 glob 会给出 'src/ios\\Views/Settings/Relay\\X.swift' 这种混分隔符，
    而 read_all() 的键长这样，直接对不上 —— 那样 used 永远是空集，
    「全部类型都有定义」就会变成一个永远通过的假断言。
    """
    return os.path.relpath(p).replace("\\", "/")


def read_all():
    files = {}
    for p in glob.glob(os.path.join(SRC, "**", "*.swift"), recursive=True):
        try:
            files[norm(p)] = strip_comments_and_strings(
                open(p, encoding="utf-8").read())
        except Exception:
            pass
    return files


def main():
    files = read_all()
    print("扫描 %d 个 Swift 文件\n" % len(files))

    bad = 0
    for caller, symbol, expected in CHECKS:
        hits = [p for p, s in files.items() if symbol in s]
        if expected:
            hits = [p for p in hits if os.path.basename(p) == expected]
        if hits:
            print("OK    %-32s %-32s -> %s" % (
                symbol, "", os.path.basename(hits[0])))
        else:
            bad += 1
            where = (" 应在 %s" % expected) if expected else ""
            print("MISS  %-32s 找不到%s" % (symbol, where))

    # 检查我们新文件里用到的类型是否都有定义
    # 定义集合全仓库扫一次，够用；按目录分别比 used - defined。
    defined = set()
    for p, s in files.items():
        for m in re.finditer(
                r'\b(?:struct|class|enum|final class|actor)\s+([A-Z]\w*)', s):
            defined.add(m.group(1))

    for rel_dir, pat, label in NEW_CODE_DIRS:
        print("\n--- 新文件引用的 %s 类型是否都已定义（%s）---" % (label, rel_dir))
        used = set()
        for p in glob.glob(os.path.join(SRC, rel_dir, "*.swift")):
            s = files.get(norm(p), "")
            if not s:
                bad += 1
                print("  ⚠️ 读不到源码，检查无效: %s" % p)
                continue
            for m in re.finditer(r'\b(%s)' % pat, s):
                used.add(m.group(1))

        if not used:
            bad += 1
            print("  ⚠️ 没扫到任何引用，检查失效（glob 或路径键对不上）")
            continue

        undefined = sorted(used - defined)
        for t in sorted(used & defined):
            print("  defined: %s" % t)
        if undefined:
            bad += 1
            print("  ⚠️ 未定义: %s" % ", ".join(undefined))
        else:
            print("  ✅ 所有 %s 类型都有定义" % label)

    print("\n结论：%s" % ("有 %d 项问题" % bad if bad else "全部通过"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
