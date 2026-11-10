#!/usr/bin/env python3
"""Validate CI assets: workflow YAML, shared scheme XML, and scheme/target agreement."""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    problems = []
    workflow = os.path.join(ROOT, ".github", "workflows", "build.yml")
    try:
        import yaml
        with open(workflow, encoding="utf-8") as handle:
            data = yaml.safe_load(handle)
        steps = data["jobs"]["build"]["steps"]
        print("workflow steps:", len(steps))
        print("runs-on:", data["jobs"]["build"]["runs-on"])
    except Exception as error:  # noqa: BLE001
        problems.append("workflow: %s" % error)

    pbxproj = open(os.path.join(ROOT, "WeBox.xcodeproj", "project.pbxproj"), encoding="utf-8").read()
    target_id = re.search(r"([0-9A-F]{24}) /\* WeBox \*/ = \{\n\t\t\tisa = PBXNativeTarget;", pbxproj)
    if not target_id:
        problems.append("PBXNativeTarget WeBox not found")
        target = None
    else:
        target = target_id.group(1)
        print("target id:", target)

    scheme_path = os.path.join(ROOT, "WeBox.xcodeproj", "xcshareddata", "xcschemes", "WeBox.xcscheme")
    try:
        from lxml import etree
        tree = etree.parse(scheme_path)
        identifiers = {el.get("BlueprintIdentifier") for el in tree.iter("BuildableReference")}
        print("scheme blueprint ids:", sorted(identifiers))
        if target and identifiers != {target}:
            problems.append("scheme BlueprintIdentifier mismatch: %s" % sorted(identifiers))
    except Exception as error:  # noqa: BLE001
        problems.append("scheme: %s" % error)

    package_script = os.path.join(ROOT, "scripts", "package_ipa.sh")
    text = open(package_script, encoding="utf-8").read()
    if "Payload/WeBox.app" not in text:
        problems.append("package_ipa.sh does not build a Payload folder")

    if problems:
        print("PROBLEMS:")
        for problem in problems:
            print(" -", problem)
        sys.exit(1)
    print("CI assets OK")


if __name__ == "__main__":
    main()
