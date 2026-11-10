#!/usr/bin/env python3
"""Generate a classic-format Xcode project for the WeBox iOS target.

Deterministic: identifiers are derived from paths, so rerunning after adding files
produces a stable project file.
"""
import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = "WeBox"

FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".js": "sourcecode.javascript",
    ".txt": "text",
    ".xcassets": "folder.assetcatalog",
    ".json": "text.json",
    ".plist": "text.plist.xml",
}


def uid(text):
    return hashlib.md5(text.encode("utf-8")).hexdigest().upper()[:24]


def collect():
    entries = []  # (relpath, kind)
    root = os.path.join(ROOT, APP)
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        # Asset catalogs are compiled as a single bundle, never recursed.
        catalogs = [d for d in dirnames if d.endswith(".xcassets")]
        for name in catalogs:
            full = os.path.join(dirpath, name)
            entries.append((os.path.relpath(full, root), "folder.assetcatalog"))
        dirnames[:] = [d for d in dirnames if not d.endswith(".xcassets")]
        for name in sorted(filenames):
            if name.startswith("."):
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            ext = os.path.splitext(name)[1]
            kind = FILE_TYPES.get(ext)
            if kind is None:
                continue
            entries.append((rel, kind))
    return entries


def main():
    entries = collect()
    swift = [e for e in entries if e[0].endswith(".swift")]
    resources = [e for e in entries if not e[0].endswith(".swift")]

    project_id = uid("project")
    main_group = uid("group:main")
    products_group = uid("group:products")
    app_product = uid("product:app")
    target_id = uid("target")
    target_configs = uid("configlist:target")
    project_configs = uid("configlist:project")
    sources_phase = uid("phase:sources")
    frameworks_phase = uid("phase:frameworks")
    resources_phase = uid("phase:resources")

    groups = {}  # rel directory -> uid
    file_refs = {}
    build_files = {"sources": [], "resources": []}

    def group_uid(rel):
        if rel in ("", "."):
            return main_group
        if rel not in groups:
            groups[rel] = uid("group:" + rel)
        return groups[rel]

    # Build directory tree (rooted at the app folder)
    tree = {APP: {}}
    for rel, kind in entries:
        parts = rel.split(os.sep)
        node = tree[APP]
        for part in parts[:-1]:
            node = node.setdefault(part, {})
        node[parts[-1]] = (rel, kind)

    lines = []
    lines.append("// !$*UTF8*$!")
    lines.append("{")
    lines.append("\tarchiveVersion = 1;")
    lines.append("\tclasses = {")
    lines.append("\t};")
    lines.append("\tobjectVersion = 56;")
    lines.append("\tobjects = {")

    # PBXBuildFile
    lines.append("")
    lines.append("/* Begin PBXBuildFile section */")
    for rel, kind in entries:
        if rel.endswith(".swift"):
            bid = uid("build:" + rel)
            fid = uid("file:" + rel)
            build_files["sources"].append(bid)
            lines.append("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
                         % (bid, os.path.basename(rel), fid, os.path.basename(rel)))
        else:
            bid = uid("build:" + rel)
            fid = uid("file:" + rel)
            build_files["resources"].append(bid)
            lines.append("\t\t%s /* %s in Resources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
                         % (bid, os.path.basename(rel), fid, os.path.basename(rel)))
    lines.append("/* End PBXBuildFile section */")

    # PBXFileReference
    lines.append("")
    lines.append("/* Begin PBXFileReference section */")
    for rel, kind in entries:
        fid = uid("file:" + rel)
        name = os.path.basename(rel)
        lines.append('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; path = "%s"; sourceTree = "<group>"; };'
                     % (fid, name, kind, name))
    lines.append('\t\t%s /* WeBox.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = WeBox.app; sourceTree = BUILT_PRODUCTS_DIR; };' % app_product)
    lines.append("/* End PBXFileReference section */")

    # PBXFrameworksBuildPhase
    lines.append("")
    lines.append("/* Begin PBXFrameworksBuildPhase section */")
    lines.append("\t\t%s /* Frameworks */ = {" % frameworks_phase)
    lines.append("\t\t\tisa = PBXFrameworksBuildPhase;")
    lines.append("\t\t\tbuildActionMask = 2147483647;")
    lines.append("\t\t\tfiles = (")
    lines.append("\t\t\t);")
    lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    lines.append("\t\t};")
    lines.append("/* End PBXFrameworksBuildPhase section */")

    # PBXGroup
    def emit_group(rel_path, node, indent):
        gid = group_uid(rel_path)
        label = os.path.basename(rel_path) if rel_path else APP
        if rel_path == "":
            label = ""
        lines.append("\t\t%s%s = {" % (indent, gid))
        lines.append("\t\t%s\tisa = PBXGroup;" % indent)
        lines.append("\t\t%s\tchildren = (" % indent)
        for name in sorted(node.keys(), key=lambda n: (not isinstance(node[n], dict), n.lower())):
            value = node[name]
            if isinstance(value, dict):
                child_rel = os.path.join(rel_path, name) if rel_path else name
                child_id = group_uid(child_rel)
                lines.append("\t\t%s\t\t%s /* %s */," % (indent, child_id, name))
            else:
                child_rel, kind = value
                lines.append("\t\t%s\t\t%s /* %s */," % (indent, uid("file:" + child_rel), name))
        lines.append("\t\t%s\t);" % indent)
        if rel_path:
            lines.append('\t\t%s\tpath = %s;' % (indent, os.path.basename(rel_path)))
        lines.append('\t\t%s\tsourceTree = "<group>";' % indent)
        lines.append("\t\t%s};" % indent)
        for name in sorted(node.keys()):
            value = node[name]
            if isinstance(value, dict):
                child_rel = os.path.join(rel_path, name) if rel_path else name
                emit_group(child_rel, value, indent)

    lines.append("")
    lines.append("/* Begin PBXGroup section */")
    # main group
    lines.append("\t\t%s = {" % main_group)
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    lines.append("\t\t\t\t%s /* %s */," % (group_uid(APP), APP))
    lines.append("\t\t\t\t%s /* Products */," % products_group)
    lines.append("\t\t\t);")
    lines.append('\t\t\tsourceTree = "<group>";')
    lines.append("\t\t};")
    lines.append("\t\t%s /* Products */ = {" % products_group)
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    lines.append("\t\t\t\t%s /* WeBox.app */," % app_product)
    lines.append("\t\t\t);")
    lines.append("\t\t\tname = Products;")
    lines.append('\t\t\tsourceTree = "<group>";')
    lines.append("\t\t};")
    emit_group(APP, tree[APP], "\t\t")
    lines.append("/* End PBXGroup section */")

    # PBXNativeTarget
    lines.append("")
    lines.append("/* Begin PBXNativeTarget section */")
    lines.append("\t\t%s /* WeBox */ = {" % target_id)
    lines.append("\t\t\tisa = PBXNativeTarget;")
    lines.append("\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget \"WeBox\" */;" % target_configs)
    lines.append("\t\t\tbuildPhases = (")
    lines.append("\t\t\t\t%s /* Sources */," % sources_phase)
    lines.append("\t\t\t\t%s /* Frameworks */," % frameworks_phase)
    lines.append("\t\t\t\t%s /* Resources */," % resources_phase)
    lines.append("\t\t\t);")
    lines.append("\t\t\tbuildRules = (")
    lines.append("\t\t\t);")
    lines.append("\t\t\tdependencies = (")
    lines.append("\t\t\t);")
    lines.append("\t\t\tname = WeBox;")
    lines.append("\t\t\tproductName = WeBox;")
    lines.append("\t\t\tproductReference = %s /* WeBox.app */;" % app_product)
    lines.append('\t\t\tproductType = "com.apple.product-type.application";')
    lines.append("\t\t};")
    lines.append("/* End PBXNativeTarget section */")

    # PBXProject
    lines.append("")
    lines.append("/* Begin PBXProject section */")
    lines.append("\t\t%s /* Project object */ = {" % project_id)
    lines.append("\t\t\tisa = PBXProject;")
    lines.append("\t\t\tattributes = {")
    lines.append("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    lines.append("\t\t\t\tLastSwiftUpdateCheck = 1500;")
    lines.append("\t\t\t\tLastUpgradeCheck = 1500;")
    lines.append("\t\t\t\tTargetAttributes = {")
    lines.append("\t\t\t\t\t%s = {" % target_id)
    lines.append("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
    lines.append("\t\t\t\t\t};")
    lines.append("\t\t\t\t};")
    lines.append("\t\t\t};")
    lines.append("\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXProject \"WeBox\" */;" % project_configs)
    lines.append('\t\t\tcompatibilityVersion = "Xcode 14.0";')
    lines.append("\t\t\tdevelopmentRegion = \"zh-Hans\";")
    lines.append("\t\t\thasScannedForEncodings = 0;")
    lines.append("\t\t\tknownRegions = (")
    lines.append("\t\t\t\ten,")
    lines.append("\t\t\t\tBase,")
    lines.append("\t\t\t\t\"zh-Hans\",")
    lines.append("\t\t\t);")
    lines.append("\t\t\tmainGroup = %s;" % main_group)
    lines.append("\t\t\tproductRefGroup = %s /* Products */;" % products_group)
    lines.append('\t\t\tprojectDirPath = "";')
    lines.append('\t\t\tprojectRoot = "";')
    lines.append("\t\t\ttargets = (")
    lines.append("\t\t\t\t%s /* WeBox */," % target_id)
    lines.append("\t\t\t);")
    lines.append("\t\t};")
    lines.append("/* End PBXProject section */")

    # Resources phase
    lines.append("")
    lines.append("/* Begin PBXResourcesBuildPhase section */")
    lines.append("\t\t%s /* Resources */ = {" % resources_phase)
    lines.append("\t\t\tisa = PBXResourcesBuildPhase;")
    lines.append("\t\t\tbuildActionMask = 2147483647;")
    lines.append("\t\t\tfiles = (")
    for bid in build_files["resources"]:
        lines.append("\t\t\t\t%s," % bid)
    lines.append("\t\t\t);")
    lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    lines.append("\t\t};")
    lines.append("/* End PBXResourcesBuildPhase section */")

    # Sources phase
    lines.append("")
    lines.append("/* Begin PBXSourcesBuildPhase section */")
    lines.append("\t\t%s /* Sources */ = {" % sources_phase)
    lines.append("\t\t\tisa = PBXSourcesBuildPhase;")
    lines.append("\t\t\tbuildActionMask = 2147483647;")
    lines.append("\t\t\tfiles = (")
    for bid in build_files["sources"]:
        lines.append("\t\t\t\t%s," % bid)
    lines.append("\t\t\t);")
    lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    lines.append("\t\t};")
    lines.append("/* End PBXSourcesBuildPhase section */")

    common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": "16.0",
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "5.0",
    }
    debug_project = dict(common)
    debug_project.update({
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": '("DEBUG=1", "$(inherited)")',
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    })
    release_project = dict(common)
    release_project.update({
        "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
        "ENABLE_NS_ASSERTIONS": "NO",
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": "-O",
        "VALIDATE_PRODUCT": "YES",
    })

    target_common = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "67",
        "DEVELOPMENT_TEAM": '""',
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "WeBox-Info.plist",
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
        "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/Frameworks")',
        "MARKETING_VERSION": "0.1.64",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.webox.ios",
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "TARGETED_DEVICE_FAMILY": '"1,2"',
    }

    def emit_config(cid, name, settings):
        lines.append("\t\t%s /* %s */ = {" % (cid, name))
        lines.append("\t\t\tisa = XCBuildConfiguration;")
        lines.append("\t\t\tbuildSettings = {")
        for key in sorted(settings):
            lines.append("\t\t\t\t%s = %s;" % (key, settings[key]))
        lines.append("\t\t\t};")
        lines.append("\t\t\tname = %s;" % name)
        lines.append("\t\t};")

    lines.append("")
    lines.append("/* Begin XCBuildConfiguration section */")
    emit_config(uid("cfg:project:debug"), "Debug", debug_project)
    emit_config(uid("cfg:project:release"), "Release", release_project)
    target_debug = dict(target_common)
    target_release = dict(target_common)
    emit_config(uid("cfg:target:debug"), "Debug", target_debug)
    emit_config(uid("cfg:target:release"), "Release", target_release)
    lines.append("/* End XCBuildConfiguration section */")

    lines.append("")
    lines.append("/* Begin XCConfigurationList section */")
    lines.append("\t\t%s /* Build configuration list for PBXProject \"WeBox\" */ = {" % project_configs)
    lines.append("\t\t\tisa = XCConfigurationList;")
    lines.append("\t\t\tbuildConfigurations = (")
    lines.append("\t\t\t\t%s /* Debug */," % uid("cfg:project:debug"))
    lines.append("\t\t\t\t%s /* Release */," % uid("cfg:project:release"))
    lines.append("\t\t\t);")
    lines.append("\t\t\tdefaultConfigurationIsVisible = 0;")
    lines.append("\t\t\tdefaultConfigurationName = Release;")
    lines.append("\t\t};")
    lines.append("\t\t%s /* Build configuration list for PBXNativeTarget \"WeBox\" */ = {" % target_configs)
    lines.append("\t\t\tisa = XCConfigurationList;")
    lines.append("\t\t\tbuildConfigurations = (")
    lines.append("\t\t\t\t%s /* Debug */," % uid("cfg:target:debug"))
    lines.append("\t\t\t\t%s /* Release */," % uid("cfg:target:release"))
    lines.append("\t\t\t);")
    lines.append("\t\t\tdefaultConfigurationIsVisible = 0;")
    lines.append("\t\t\tdefaultConfigurationName = Release;")
    lines.append("\t\t};")
    lines.append("/* End XCConfigurationList section */")

    lines.append("\t};")
    lines.append("\trootObject = %s /* Project object */;" % project_id)
    lines.append("}")

    out_dir = os.path.join(ROOT, "WeBox.xcodeproj")
    os.makedirs(os.path.join(out_dir, "xcshareddata", "xcschemes"), exist_ok=True)
    scheme = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "%(target)s"
               BuildableName = "WeBox.app"
               BlueprintName = "WeBox"
               ReferencedContainer = "container:WeBox.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "%(target)s"
            BuildableName = "WeBox.app"
            BlueprintName = "WeBox"
            ReferencedContainer = "container:WeBox.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "%(target)s"
            BuildableName = "WeBox.app"
            BlueprintName = "WeBox"
            ReferencedContainer = "container:WeBox.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
""" % {"target": target_id}
    with open(os.path.join(out_dir, "xcshareddata", "xcschemes", "WeBox.xcscheme"), "w",
              encoding="utf-8", newline="\n") as handle:
        handle.write(scheme)
    with open(os.path.join(out_dir, "project.pbxproj"), "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(lines) + "\n")
    print("wrote %s with %d swift files and %d resources" % (out_dir, len(swift), len(resources)))


if __name__ == "__main__":
    main()
