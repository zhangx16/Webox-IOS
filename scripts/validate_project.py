#!/usr/bin/env python3
"""Validate the generated project.pbxproj without Xcode.

Parses the OpenStep property list, checks identifier references, verifies that every
file reference resolves on disk, and reports the source/resource phases.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class ParseError(Exception):
    pass


class Parser:
    def __init__(self, text):
        self.text = text
        self.pos = 0

    def skip(self):
        while self.pos < len(self.text):
            ch = self.text[self.pos]
            if ch in " \t\r\n":
                self.pos += 1
            elif self.text.startswith("/*", self.pos):
                end = self.text.find("*/", self.pos + 2)
                if end < 0:
                    raise ParseError("unterminated comment")
                self.pos = end + 2
            elif self.text.startswith("//", self.pos):
                end = self.text.find("\n", self.pos)
                self.pos = len(self.text) if end < 0 else end + 1
            else:
                return

    def parse(self):
        self.skip()
        if self.text[self.pos] != "{":
            raise ParseError("expected top level dictionary")
        value = self.value()
        self.skip()
        if self.pos != len(self.text):
            raise ParseError("trailing content at %d" % self.pos)
        return value

    def value(self):
        self.skip()
        ch = self.text[self.pos]
        if ch == "{":
            self.pos += 1
            result = {}
            while True:
                self.skip()
                if self.text[self.pos] == "}":
                    self.pos += 1
                    return result
                key = self.string_or_bare()
                self.skip()
                if self.text[self.pos] != "=":
                    raise ParseError("expected = after %r" % key)
                self.pos += 1
                result[key] = self.value()
                self.skip()
                if self.text[self.pos] == ";":
                    self.pos += 1
                else:
                    raise ParseError("expected ; after value for %r" % key)
        if ch == "(":
            self.pos += 1
            result = []
            while True:
                self.skip()
                if self.text[self.pos] == ")":
                    self.pos += 1
                    return result
                result.append(self.value())
                self.skip()
                if self.text[self.pos] == ",":
                    self.pos += 1
        return self.string_or_bare()

    def string_or_bare(self):
        self.skip()
        if self.text[self.pos] == '"':
            self.pos += 1
            out = []
            while True:
                ch = self.text[self.pos]
                if ch == "\\":
                    nxt = self.text[self.pos + 1]
                    mapping = {"n": "\n", "t": "\t", '"': '"', "\\": "\\"}
                    out.append(mapping.get(nxt, nxt))
                    self.pos += 2
                elif ch == '"':
                    self.pos += 1
                    return "".join(out)
                else:
                    out.append(ch)
                    self.pos += 1
        start = self.pos
        while self.pos < len(self.text) and self.text[self.pos] not in ' \t\r\n;=,(){}"':
            self.pos += 1
        if start == self.pos:
            raise ParseError("unexpected character %r at %d" % (self.text[self.pos], self.pos))
        return self.text[start:self.pos]


def main():
    path = os.path.join(ROOT, "WeBox.xcodeproj", "project.pbxproj")
    text = open(path, encoding="utf-8").read()
    top = Parser(text).parse()
    objects = top["objects"]
    problems = []

    # Identifier uniqueness and reference integrity
    defined = set(objects.keys())
    referenced = set(re.findall(r"\b[0-9A-F]{24}\b", text))
    unknown = referenced - defined
    if unknown:
        problems.append("undefined identifiers: %s" % sorted(unknown))

    for key, object_value in objects.items():
        if not isinstance(object_value, dict) or "isa" not in object_value:
            problems.append("object %s has no isa" % key)

    project = objects.get(top["rootObject"])
    if project is None or project.get("isa") != "PBXProject":
        problems.append("rootObject is not a PBXProject")
        print("\n".join(problems))
        sys.exit(1)

    # Walk groups and resolve file references on disk
    def walk(group_id, prefix):
        group = objects[group_id]
        group_path = group.get("path", "")
        base = os.path.join(prefix, group_path) if group_path else prefix
        for child in group.get("children", []):
            entry = objects[child]
            if entry.get("isa") == "PBXGroup":
                walk(child, base)
            elif entry.get("isa") == "PBXFileReference":
                if entry.get("sourceTree") == "BUILT_PRODUCTS_DIR":
                    continue
                file_path = entry.get("path", "")
                full = os.path.join(base, file_path.replace('"', ""))
                if not os.path.exists(full):
                    problems.append("missing file: %s" % full)

    walk(project["mainGroup"], ROOT)

    # Build phase summaries
    target = objects[project["targets"][0]]
    phases = {objects[p]["isa"]: objects[p] for p in target["buildPhases"]}
    sources = phases.get("PBXSourcesBuildPhase", {}).get("files", [])
    resources = phases.get("PBXResourcesBuildPhase", {}).get("files", [])
    print("targets:", [objects[t]["name"] for t in project["targets"]])
    print("source files:", len(sources))
    print("resource files:", len(resources))
    print("known regions:", project.get("knownRegions"))
    print("object version:", open(path, encoding="utf-8").read().split("objectVersion = ")[1].split(";")[0])

    if problems:
        print("PROBLEMS:")
        for problem in problems:
            print(" -", problem)
        sys.exit(1)
    print("project.pbxproj OK")


if __name__ == "__main__":
    main()
