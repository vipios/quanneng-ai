#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把三元组 R40 复刻新增的两个 Swift 文件注册进 Minis.xcodeproj。

与 register_relay_files.py / register_github_files.py 同一套机制：
Skills / Domain 目录都不在 PBXFileSystemSynchronizedRootGroup 里，
必须手工登记到四处，漏一个就编译不过：

  1. PBXBuildFile        —— "X.swift in Sources"
  2. PBXFileReference    —— 文件引用本体
  3. PBXGroup(children)  —— 挂到对应组
  4. PBXSourcesBuildPhase(files) —— 真正参与编译

本次两个文件分属两个组：
  · SkillsCatalogView.swift  → Skills 组（F1V00016）
  · RouteCatalogData.swift   → Domain 组（FF1A000000000000000000FF）

ID 规则：24 位大写十六进制，前缀 E5CA（BuildFile）/ E5CB（FileRef），
末尾补序号。幂等：已存在的 ID 会跳过。

用法：
    python tools/register_skills_files.py            # 登记缺失项（幂等）
    python tools/register_skills_files.py --check    # 只校验不写盘
"""
import os
import re
import sys

PBX = "src/ios/Minis.xcodeproj/project.pbxproj"

# (文件名, 所属目录, 组内锚点文件)
FILES = [
    ("SkillsCatalogView.swift", "src/ios/Views/Skills", "SkillsManagementView.swift"),
    ("RouteCatalogData.swift", "src/ios/Views/Skills/Domain", "RouteRules.swift"),
    ("PersonaBodies.swift", "src/ios/Views/Skills/Domain", "RouteCatalogData.swift"),
]


def make_ids(index):
    bf = "E5CA%020X" % (index + 1)
    fr = "E5CB%020X" % (index + 1)
    assert len(bf) == 24 and re.fullmatch(r"[0-9A-F]{24}", bf), bf
    assert len(fr) == 24 and re.fullmatch(r"[0-9A-F]{24}", fr), fr
    return bf, fr


def check_only():
    with open(PBX, "r", encoding="utf-8", newline="") as f:
        src = f.read()
    bad = 0
    for i, (name, _dir, _anchor) in enumerate(FILES):
        bf_id, fr_id = make_ids(i)
        ok = (
            (bf_id in src)
            and (fr_id in src)
            and ("%s /* %s */," % (fr_id, name) in src)
            and ("%s /* %s in Sources */," % (bf_id, name) in src)
        )
        print("%-26s %s" % (name, "✓" if ok else "✗ 未登记完整"))
        if not ok:
            bad += 1
    return 1 if bad else 0


def main():
    if not os.path.exists(PBX):
        sys.exit("找不到 %s，请在仓库根目录执行" % PBX)

    if "--check" in sys.argv[1:]:
        return check_only()

    with open(PBX, "r", encoding="utf-8", newline="") as f:
        src = f.read()

    # 检测换行符（pbxproj 是 CRLF）
    nl = "\r\n" if "\r\n" in src else "\n"

    for i, (name, dirpath, _anchor) in enumerate(FILES):
        if not os.path.exists(os.path.join(dirpath, name)):
            sys.exit("缺文件：%s" % os.path.join(dirpath, name))

    # 锚点（取自现有文件，用于定位插入点）。换行符用检测到的 nl。
    anchors = {
        "bf_skills": "\t\tE5N0000032F3B941A00049557 /* SkillsManagementView.swift in Sources */ = {isa = PBXBuildFile; fileRef = E5N0000132F3B941A00049557 /* SkillsManagementView.swift */; };" + nl,
        "bf_domain": "\t\tFF2A00000000000000000002 /* RouteRules.swift in Sources */ = {isa = PBXBuildFile; fileRef = FF1A00000000000000000002 /* RouteRules.swift */; };" + nl,
        "fr_skills": '\t\tE5N0000132F3B941A00049557 /* SkillsManagementView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SkillsManagementView.swift; sourceTree = "<group>"; };' + nl,
        "fr_domain": '\t\tFF1A00000000000000000002 /* RouteRules.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RouteRules.swift; sourceTree = "<group>"; };' + nl,
        "grp_skills": "\t\t\t\tE5N0000132F3B941A00049557 /* SkillsManagementView.swift */," + nl,
        "grp_domain": "\t\t\t\tFF1A00000000000000000002 /* RouteRules.swift */," + nl,
        "ph_skills": "\t\t\t\tE5N0000032F3B941A00049557 /* SkillsManagementView.swift in Sources */," + nl,
        "ph_domain": "\t\t\t\tFF2A00000000000000000002 /* RouteRules.swift in Sources */," + nl,
    }

    for label, a in anchors.items():
        if a not in src:
            sys.exit("锚点丢失：%s" % label)

    added, skipped = [], []

    for i, (name, _dir, _anchor) in enumerate(FILES):
        bf_id, fr_id = make_ids(i)
        if bf_id in src or fr_id in src:
            skipped.append(name)
            continue
        tag = "skills" if i == 0 else "domain"

        # 1. PBXBuildFile
        src = src.replace(
            anchors["bf_" + tag],
            anchors["bf_" + tag]
            + "\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };%s" % (bf_id, name, fr_id, name, nl),
            1,
        )
        # 2. PBXFileReference
        src = src.replace(
            anchors["fr_" + tag],
            anchors["fr_" + tag]
            + '\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = %s; sourceTree = "<group>"; };%s' % (fr_id, name, name, nl),
            1,
        )
        # 3. 组 children
        src = src.replace(
            anchors["grp_" + tag],
            anchors["grp_" + tag] + "\t\t\t\t%s /* %s */,%s" % (fr_id, name, nl),
            1,
        )
        # 4. Sources build phase
        src = src.replace(
            anchors["ph_" + tag],
            anchors["ph_" + tag] + "\t\t\t\t%s /* %s in Sources */,%s" % (bf_id, name, nl),
            1,
        )
        added.append(name)

    if not added:
        print("全部已注册，无需改动。")
        return 0

    with open(PBX, "w", encoding="utf-8", newline="") as f:
        f.write(src)

    print("已注册 %d 个文件：" % len(added))
    for n in added:
        print("  +", n)
    if skipped:
        print("已存在跳过 %d 个：%s" % (len(skipped), ", ".join(skipped)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
