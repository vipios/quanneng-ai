#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 src/ios/Views/Settings/GitHub/ 下的新 Swift 文件注册进 Minis.xcodeproj。

与 register_relay_files.py 同一套机制（Settings 目录不在
PBXFileSystemSynchronizedRootGroup 里，必须手工登记），但多一层：
GitHub 是 Settings 的子目录，所以要先建一个 PBXGroup 承载它，
否则 Xcode 会去 Views/Settings/GitHubAuth.swift 找文件 —— 路径是错的。

需要落地的五处：

  1. PBXGroup            —— 新建 "GitHub" 组，path = GitHub，挂到 Settings 组下
  2. PBXGroup(children)  —— Settings 组的 children 里加一行 /* GitHub */,
  3. PBXBuildFile        —— "X.swift in Sources"
  4. PBXFileReference    —— 文件引用本体（path 只写裸文件名，父组带 GitHub）
  5. PBXSourcesBuildPhase(files) —— 真正参与编译

ID 规则：24 位大写十六进制。
  GitHub 组  C410 + 20 个 0
  BuildFile  C400 + 20 位序号（1 起）
  FileRef    C401 + 20 位序号（1 起）
  Relay 用的是 BE1A / FE1A，两套不冲突。

用法：
    python tools/register_github_files.py            # 登记缺失项（幂等）
    python tools/register_github_files.py --check    # 只校验不写盘
"""
import os
import re
import sys

PBX = "src/ios/Minis.xcodeproj/project.pbxproj"
GH_DIR = "src/ios/Views/Settings/GitHub"

FILES = [
    "GitHubAuth.swift",
    "BuildFallback.swift",
    "GitHubPush.swift",
    "GitHubStore.swift",
    "GitHubAccountView.swift",
    "GitHubCloudBuildTool.swift",
]

GH_GROUP_ID = "C41000000000000000000000"


def make_ids(index):
    """(buildFileID, fileRefID)，各 24 位纯十六进制。"""
    bf = "C400%020X" % (index + 1)
    fr = "C401%020X" % (index + 1)
    assert len(bf) == 24 and re.fullmatch(r"[0-9A-F]{24}", bf), bf
    assert len(fr) == 24 and re.fullmatch(r"[0-9A-F]{24}", fr), fr
    return bf, fr


# PBXGroup 段里 Settings 组定义的开头 —— 用来插 GitHub 组定义
ANCHOR_GROUP_BLOCK = "\t\tF1V00011 /* Settings */ = {\n\t\t\tisa = PBXGroup;\n"
# Settings 组 children 里的一行 —— 用来插 /* GitHub */,
ANCHOR_SETTINGS_CHILD = "\t\t\t\tE5LOCK103 /* AppLockOverlay.swift */,\n"
ANCHOR_BF = ("\t\tE5CVSET0000000000000A001 /* SettingsSheet.swift in Sources */ = "
             "{isa = PBXBuildFile; fileRef = E5CVSET0000000000000A011 /* SettingsSheet.swift */; };\n")
ANCHOR_FR = ('\t\tE5CVSET0000000000000A011 /* SettingsSheet.swift */ = '
             '{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
             'path = SettingsSheet.swift; sourceTree = "<group>"; };\n')
ANCHOR_PHASE = "\t\t\t\tE5CVSET0000000000000A002 /* AppearanceSettingsView.swift in Sources */,\n"

ANCHORS = {
    "groupblock": ANCHOR_GROUP_BLOCK,
    "settingschild": ANCHOR_SETTINGS_CHILD,
    "bf": ANCHOR_BF,
    "fr": ANCHOR_FR,
    "phase": ANCHOR_PHASE,
}


def check_only():
    with open(PBX, "r", encoding="utf-8", newline="") as f:
        src = f.read()

    for label, a in ANCHORS.items():
        if a not in src:
            print("✗ %-14s 锚点丢失，pbxproj 结构已变" % label)
            return 1
    print("锚点 5/5 齐全\n")

    bad = 0
    group_ok = ('%s /* GitHub */ = {' % GH_GROUP_ID) in src
    group_child_ok = ("%s /* GitHub */," % GH_GROUP_ID) in src
    group_path_ok = '\t\t\tpath = GitHub;\n' in src
    print("%-26s %-10s %-10s %-10s %-10s %-8s %-9s"
          % ("文件", "GitHub组", "组挂载", "BuildFile", "FileRef", "组内", "编译"))
    for i, name in enumerate(FILES):
        bf_id, fr_id = make_ids(i)
        # 不能只判 "id in src"：group children 里也有 id，
        # 那是"组内引用"，不是"编译/文件引用定义"。必须匹配定义语句本身。
        bf_def = ("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile" % (bf_id, name)) in src
        bf_use = ("%s /* %s in Sources */," % (bf_id, name)) in src
        fr_def = ("\t\t%s /* %s */ = {isa = PBXFileReference" % (fr_id, name)) in src
        fr_grp = ("%s /* %s */," % (fr_id, name)) in src
        cells = ["✓" if x else "✗"
                 for x in (bf_def, fr_def, fr_grp, bf_use)]
        if not all((bf_def, fr_def, fr_grp, bf_use)):
            bad += 1
        print("%-26s %-10s %-10s %-10s %-10s %-8s %-9s"
              % (name, "✓" if group_ok else "✗", "✓" if group_child_ok else "✗",
                 cells[0], cells[1], cells[2], cells[3]))

    print()
    if not group_ok:
        print("✗ PBXGroup 里没有 GitHub 组定义（%s）" % GH_GROUP_ID)
        bad += 1
    if not group_child_ok:
        print("✗ Settings 组里没挂 GitHub 组")
        bad += 1
    if not group_path_ok:
        print("✗ GitHub 组缺 path = GitHub")

    if bad:
        print("✗ %d 处登记不全" % bad)
        return 1
    print("✓ GitHub 组 + %d 个文件全部登记完整" % len(FILES))
    return 0


def main():
    if not os.path.exists(PBX):
        sys.exit("找不到 %s，请在仓库根目录执行" % PBX)

    if "--check" in sys.argv[1:]:
        return check_only()

    with open(PBX, "r", encoding="utf-8", newline="") as f:
        src = f.read()

    missing = [n for n in FILES if not os.path.exists(os.path.join(GH_DIR, n))]
    if missing:
        sys.exit("缺文件：%s" % ", ".join(missing))

    for label, a in ANCHORS.items():
        if a not in src:
            sys.exit("锚点没找到：%s" % label)

    changed = []

    # 1) GitHub 子组定义
    if ("%s /* GitHub */ = {" % GH_GROUP_ID) not in src:
        gh_children = "".join(
            "\t\t\t\t%s /* %s */,\n" % (make_ids(i)[1], n)
            for i, n in enumerate(FILES))
        block = (
            "\t\t%s /* GitHub */ = {\n"
            "\t\t\tisa = PBXGroup;\n"
            "\t\t\tchildren = (\n"
            "%s"
            "\t\t\t);\n"
            "\t\t\tpath = GitHub;\n"
            '\t\t\tsourceTree = "<group>";\n'
            "\t\t};\n" % (GH_GROUP_ID, gh_children)
        )
        src = src.replace(ANCHOR_GROUP_BLOCK, block + ANCHOR_GROUP_BLOCK, 1)
        changed.append("+ PBXGroup GitHub (%s)" % GH_GROUP_ID)

    # 2) 挂到 Settings 组
    if ("%s /* GitHub */," % GH_GROUP_ID) not in src:
        src = src.replace(
            ANCHOR_SETTINGS_CHILD,
            ANCHOR_SETTINGS_CHILD + "\t\t\t\t%s /* GitHub */,\n" % GH_GROUP_ID, 1)
        changed.append("+ Settings.children 挂上 GitHub 组")

    # 2b) 组已存在时，新文件也要补进它的 children。
    #     只判「组定义在不在」不够 —— 后来新增的文件会漏掉，正是
    #     GitHubCloudBuildTool.swift 这种后加文件踩的坑：
    #     BuildFile/FileRef/Sources 都登记了，组里没有它，
    #     Xcode 里看不到文件，文件也真正参与编译 —— 但 project navigator
    #     里是散的，下次谁用 Xcode 点一下就容易被"修复"成重复条目。
    gh_group_def = "%s /* GitHub */ = {" % GH_GROUP_ID
    if gh_group_def in src:
        for i, name in enumerate(FILES):
            fr_id = make_ids(i)[1]
            entry = "\t\t\t\t%s /* %s */,\n" % (fr_id, name)
            if entry in src:
                continue
            # 插到 GitHub 组 children 的右括号前
            start = src.find(gh_group_def)
            if start == -1:
                continue
            close = src.find("\t\t\t);", start)
            if close == -1:
                continue
            src = src[:close] + entry + src[close:]
            changed.append("+ GitHub.children 补上 %s" % name)

    bf_lines, fr_lines, phase_lines, added = [], [], [], []
    for i, name in enumerate(FILES):
        bf_id, fr_id = make_ids(i)
        # 同上：用定义语句判存在，否则 GitHub 组 children 里的 id 会让这里误判为已登记。
        if ("\t\t%s /* %s */ = {isa = PBXFileReference" % (fr_id, name)) in src:
            continue
        bf_lines.append(
            "\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n"
            % (bf_id, name, fr_id, name))
        fr_lines.append(
            '\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
            'path = %s; sourceTree = "<group>"; };\n' % (fr_id, name, name))
        phase_lines.append("\t\t\t\t%s /* %s in Sources */,\n" % (bf_id, name))
        added.append(name)

    if bf_lines:
        src = src.replace(ANCHOR_BF, ANCHOR_BF + "".join(bf_lines), 1)
        src = src.replace(ANCHOR_FR, ANCHOR_FR + "".join(fr_lines), 1)
        src = src.replace(ANCHOR_PHASE, ANCHOR_PHASE + "".join(phase_lines), 1)
        changed.append("+ %d 个文件的 BuildFile / FileRef / Sources 登记" % len(added))

    if not changed:
        print("全部已注册，无需改动。")
        return 0

    with open(PBX, "w", encoding="utf-8", newline="") as f:
        f.write(src)

    for c in changed:
        print(c)
    for n in added:
        print("  +", n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
