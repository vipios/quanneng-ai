#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 src/ios/Views/Settings/Relay/ 下的新 Swift 文件注册进 Minis.xcodeproj。

pbxproj 是 objectVersion = 70，但 Settings 目录**不在**任何
PBXFileSystemSynchronizedRootGroup 里（同步组只有 Terminal / AIChatView /
ContentView / Markdown / CollectionViewMessageListV3）。所以这些文件必须
手工登记到四个地方，漏一个就编译不过：

  1. PBXBuildFile       —— "X.swift in Sources"
  2. PBXFileReference   —— 文件引用本体
  3. PBXGroup(children) —— 挂到 Settings 组（F1V00011）
  4. PBXSourcesBuildPhase(files) —— 真正参与编译

ID 规则：24 位大写十六进制，前缀 BE1A（BuildFile）/ FE1A（FileRef），末尾补序号。
已有的 ID 会被检测跳过，脚本可重复执行（幂等）。

用法：
    python tools/register_relay_files.py            # 登记缺失项（幂等）
    python tools/register_relay_files.py --check    # 只校验不写盘，缺项返回非 0
"""
import os
import re
import sys

PBX = "src/ios/Minis.xcodeproj/project.pbxproj"
RELAY_DIR = "src/ios/Views/Settings/Relay"
SETTINGS_GROUP_ID = "F1V00011"   # F1V00011 /* Settings */

# 顺序即插入顺序，保证 diff 稳定
FILES = [
    "RelayRoute.swift",
    "RelayVault.swift",
    "RelayBackend.swift",
    "RelayStore.swift",
    "RelayRouterView.swift",
    "RelayAdminView.swift",
    "RelaySettingsView.swift",
    "RelayProviderSettings.swift",
    "AddRelayProviderView.swift",
]


def make_ids(index):
    """给第 index 个文件生成 (buildFileID, fileRefID)，各 24 位**纯十六进制**。

    ⚠️ Xcode 的 object ID 只允许 0-9A-F。前缀不能带 L/Y/Z 之类字母，
       所以这里用 RELAY 的十六进制近似：RE1A (R=不合法) → 改用
       前缀 "BE1A"（Be1a，看起来像 relay）保证纯十六进制。
    """
    # 20 位十六进制 → 24 位 = 4 位前缀 + 20 位序号
    bf = "BE1A%020X" % (index + 1)      # Build File
    fr = "FE1A%020X" % (index + 1)      # File Reference
    assert len(bf) == 24 and re.fullmatch(r"[0-9A-F]{24}", bf), bf
    assert len(fr) == 24 and re.fullmatch(r"[0-9A-F]{24}", fr), fr
    return bf, fr


def check_only():
    """只读校验：每个文件在四处都登记了才算过。不写盘。"""
    with open(PBX, "r", encoding="utf-8", newline="") as f:
        src = f.read()

    anchors = [
        ("PBXBuildFile",     "\t\tE5CVSET0000000000000A001 /* SettingsSheet.swift in Sources */ = {isa = PBXBuildFile; fileRef = E5CVSET0000000000000A011 /* SettingsSheet.swift */; };\n"),
        ("PBXFileReference", '\t\tE5CVSET0000000000000A011 /* SettingsSheet.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SettingsSheet.swift; sourceTree = "<group>"; };\n'),
        ("PBXGroup",         "\t\t\t\tE5LOCK103 /* AppLockOverlay.swift */,\n"),
        ("SourcesPhase",     "\t\t\t\tE5CVSET0000000000000A002 /* AppearanceSettingsView.swift in Sources */,\n"),
    ]
    for label, a in anchors:
        if a not in src:
            print("✗ %-16s 锚点丢失，pbxproj 结构已变" % label)
            return 1
    print("锚点 4/4 齐全\n")

    bad = 0
    print("%-30s %-10s %-10s %-8s %-9s" % ("文件", "BuildFile", "FileRef", "组内", "编译"))
    for i, name in enumerate(FILES):
        bf_id, fr_id = make_ids(i)
        bf_def = bf_id in src                                     # 定义
        bf_use = ("%s /* %s in Sources */," % (bf_id, name)) in src  # 编译阶段引用
        fr_def = fr_id in src
        fr_grp = ("%s /* %s */," % (fr_id, name)) in src          # 组内引用
        cells = ["✓" if x else "✗" for x in (bf_def, fr_def, fr_grp, bf_use)]
        if not all((bf_def, fr_def, fr_grp, bf_use)):
            bad += 1
        print("%-30s %-10s %-10s %-8s %-9s" % (name, cells[0], cells[1], cells[2], cells[3]))

    print()
    if bad:
        print("✗ %d 个文件登记不全" % bad)
        return 1
    print("✓ %d 个文件全部登记完整（各 4 处）" % len(FILES))
    return 0


def main():
    if not os.path.exists(PBX):
        sys.exit("找不到 %s，请在仓库根目录执行" % PBX)

    if "--check" in sys.argv[1:]:
        return check_only()

    with open(PBX, "r", encoding="utf-8", newline="") as f:
        src = f.read()

    missing = [n for n in FILES if not os.path.exists(os.path.join(RELAY_DIR, n))]
    if missing:
        sys.exit("缺文件：%s" % ", ".join(missing))

    added, skipped = [], []

    # ---------- 1. PBXBuildFile ----------
    anchor_bf = "\t\tE5CVSET0000000000000A001 /* SettingsSheet.swift in Sources */ = {isa = PBXBuildFile; fileRef = E5CVSET0000000000000A011 /* SettingsSheet.swift */; };\n"
    if anchor_bf not in src:
        sys.exit("PBXBuildFile 锚点没找到（SettingsSheet.swift in Sources）")

    bf_lines = []
    fr_lines = []
    group_lines = []
    phase_lines = []

    for i, name in enumerate(FILES):
        bf_id, fr_id = make_ids(i)
        if bf_id in src or fr_id in src:
            skipped.append(name)
            continue

        bf_lines.append(
            "\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n"
            % (bf_id, name, fr_id, name))
        fr_lines.append(
            '\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = %s; sourceTree = "<group>"; };\n'
            % (fr_id, name, name))
        group_lines.append("\t\t\t\t%s /* %s */,\n" % (fr_id, name))
        phase_lines.append("\t\t\t\t%s /* %s in Sources */,\n" % (bf_id, name))
        added.append(name)

    if not added:
        print("全部已注册，无需改动。")
        return

    # 插 PBXBuildFile：锚点之后
    src = src.replace(anchor_bf, anchor_bf + "".join(bf_lines), 1)

    # ---------- 2. PBXFileReference ----------
    anchor_fr = '\t\tE5CVSET0000000000000A011 /* SettingsSheet.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SettingsSheet.swift; sourceTree = "<group>"; };\n'
    if anchor_fr not in src:
        sys.exit("PBXFileReference 锚点没找到")
    src = src.replace(anchor_fr, anchor_fr + "".join(fr_lines), 1)

    # ---------- 3. Settings 组的 children ----------
    # 用组内最后一个子项作锚点（AppLockOverlay.swift 之后就是 ");"）
    anchor_group = "\t\t\t\tE5LOCK103 /* AppLockOverlay.swift */,\n"
    if anchor_group not in src:
        sys.exit("PBXGroup children 锚点没找到（AppLockOverlay.swift）")
    src = src.replace(anchor_group, anchor_group + "".join(group_lines), 1)

    # ---------- 4. Sources build phase ----------
    anchor_phase = "\t\t\t\tE5CVSET0000000000000A002 /* AppearanceSettingsView.swift in Sources */,\n"
    if anchor_phase not in src:
        sys.exit("PBXSourcesBuildPhase 锚点没找到（AppearanceSettingsView.swift in Sources）")
    src = src.replace(anchor_phase, anchor_phase + "".join(phase_lines), 1)

    with open(PBX, "w", encoding="utf-8", newline="") as f:
        f.write(src)

    print("已注册 %d 个文件：" % len(added))
    for n in added:
        print("  +", n)
    if skipped:
        print("已存在跳过 %d 个：%s" % (len(skipped), ", ".join(skipped)))


if __name__ == "__main__":
    sys.exit(main())
