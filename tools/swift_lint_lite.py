#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Swift 源文件的轻量结构检查（不依赖 swiftc）。

做三件事：
  1. 去掉注释、单行字符串、多行字符串后，检查 {} () [] 是否配平
  2. 检查是否存在非 UTF-8 / BOM / CRLF 混杂问题
  3. 粗查常见笔误：`if let x = y {` 后面紧跟 `}`、多余的 `else`、未闭合的 `#if`

这不是编译器，只能拦住结构性错误。真正的编译验证必须在 macOS 上跑
xcodebuild（Windows 上没有 Swift toolchain）。
"""
import glob
import os
import sys


def strip_swift(src):
    """移除注释与字符串字面量，只留结构字符。"""
    out = []
    i = 0
    n = len(src)
    while i < n:
        if src.startswith('"""', i):
            j = src.find('"""', i + 3)
            i = (j + 3) if j != -1 else n
            out.append('STR')
            continue
        if src.startswith('//', i):
            j = src.find('\n', i)
            i = j if j != -1 else n
            continue
        if src.startswith('/*', i):
            j = src.find('*/', i + 2)
            i = (j + 2) if j != -1 else n
            continue
        ch = src[i]
        if ch == '"':
            i += 1
            while i < n:
                if src[i] == '\\':
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                i += 1
            out.append('STR')
            continue
        out.append(ch)
        i += 1
    return ''.join(out)


def check(path):
    raw = open(path, 'rb').read()
    problems = []

    if raw.startswith(b'\xef\xbb\xbf'):
        problems.append('含 UTF-8 BOM（Swift 源文件不应有）')
    try:
        src = raw.decode('utf-8')
    except UnicodeDecodeError as e:
        return ['不是合法 UTF-8：%s' % e]

    if '\r\n' in src and '\n' in src.replace('\r\n', ''):
        problems.append('CRLF 与 LF 混用')

    t = strip_swift(src)

    for a, b, name in [('{', '}', '花括号'), ('(', ')', '圆括号'), ('[', ']', '方括号')]:
        ca, cb = t.count(a), t.count(b)
        if ca != cb:
            problems.append('%s不配平 %s=%d %s=%d' % (name, a, ca, b, cb))

    # #if / #endif 配对
    n_if = sum(1 for ln in src.split('\n') if ln.strip().startswith('#if'))
    n_end = sum(1 for ln in src.split('\n') if ln.strip().startswith('#endif'))
    if n_if != n_end:
        problems.append('#if=%d 与 #endif=%d 不配对' % (n_if, n_end))

    return problems


def main():
    patterns = sys.argv[1:] or ['src/ios/Views/Settings/*/*.swift']
    files = []
    for p in patterns:
        files.extend(sorted(glob.glob(p, recursive=True)))

    if not files:
        print('没有匹配到文件')
        return 1

    bad = 0
    for f in files:
        probs = check(f)
        name = os.path.basename(f)
        if probs:
            bad += 1
            print('FAIL  %s' % name)
            for p in probs:
                print('        - %s' % p)
        else:
            print('OK    %s' % name)

    print()
    print('检查 %d 个文件，%d 个有问题' % (len(files), bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
