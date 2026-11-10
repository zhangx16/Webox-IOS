#!/usr/bin/env python3
"""Cheap structural check for Swift sources: balanced delimiters outside strings/comments.

Not a compiler, but catches accidental truncation and unbalanced braces.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def strip(text):
    out = []
    i = 0
    n = len(text)
    in_line = False
    in_block = 0
    in_string = False
    in_multiline = False
    while i < n:
        ch = text[i]
        two = text[i:i + 2]
        three = text[i:i + 3]
        if in_line:
            if ch == "\n":
                in_line = False
            i += 1
            continue
        if in_block:
            if two == "*/":
                in_block -= 1
                i += 2
                continue
            if two == "/*":
                in_block += 1
                i += 2
                continue
            i += 1
            continue
        if in_multiline:
            if three == '"""':
                in_multiline = False
                i += 3
                continue
            i += 1
            continue
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if two == "//":
            in_line = True
            i += 2
            continue
        if two == "/*":
            in_block = 1
            i += 2
            continue
        if three == '"""':
            in_multiline = True
            i += 3
            continue
        if ch == '"':
            in_string = True
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def check(path):
    source = strip(open(path, encoding="utf-8").read())
    counts = {c: source.count(c) for c in "{}()[]"}
    problems = []
    if counts["{"] != counts["}"]:
        problems.append("braces %d/%d" % (counts["{"], counts["}"]))
    if counts["("] != counts[")"]:
        problems.append("parens %d/%d" % (counts["("], counts[")"]))
    if counts["["] != counts["]"]:
        problems.append("brackets %d/%d" % (counts["["], counts["]"]))
    # simple nesting walk
    pairs = {"}": "{", ")": "(", "]": "["}
    stack = []
    for ch in source:
        if ch in "{([":
            stack.append(ch)
        elif ch in pairs:
            if not stack or stack[-1] != pairs[ch]:
                problems.append("mismatched %s at %d" % (ch, source.index(ch)))
                break
            stack.pop()
    if stack:
        problems.append("unclosed %s" % "".join(stack[:5]))
    return problems


def main():
    failures = 0
    for dirpath, _, filenames in os.walk(os.path.join(ROOT, "WeBox")):
        for name in sorted(filenames):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name)
            problems = check(path)
            if problems:
                failures += 1
                print("FAIL", os.path.relpath(path, ROOT), "->", "; ".join(problems))
    print("checked swift files, failures:", failures)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
