#!/usr/bin/env python3
"""Generate a standalone, dependency-free XCTest UI-testing project; do not run it."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET


def identifier(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def openstep(value, depth=0):
    indent = "\t" * depth
    if isinstance(value, dict):
        lines = ["{"]
        for key, child in value.items():
            lines.append(f"{indent}\t{json.dumps(key)} = {openstep(child, depth + 1)};")
        return "\n".join(lines) + f"\n{indent}}}"
    if isinstance(value, list):
        return "(" + ", ".join(openstep(child, depth) for child in value) + ")"
    if isinstance(value, int):
        return str(value)
    return json.dumps(value, ensure_ascii=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-bundle-id", required=True)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent / ".generated")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]+", args.app_bundle_id):
        parser.error("--app-bundle-id must be an application bundle identifier")
    source = Path(__file__).resolve().parent
    project = args.output.resolve() / "DriveApple.xcodeproj"
    scheme_directory = project / "xcshareddata" / "xcschemes"
    scheme_directory.mkdir(parents=True, exist_ok=True)
    objects = {}

    def add(object_name, **fields):
        key = identifier(object_name)
        objects[key] = fields
        return key

    build_files = []
    references = []
    for name in ["DriveWire.swift", "DriveTCP.swift", "DriveXCTestRunner.swift", "DriveUITests.example.swift"]:
        path = source / name
        if not path.is_file():
            parser.error(f"missing source: {path}")
        reference = add(name, isa="PBXFileReference", lastKnownFileType="sourcecode.swift",
                        path=str(path), sourceTree="<absolute>")
        references.append(reference)
        build_files.append(add(f"build-{name}", isa="PBXBuildFile", fileRef=reference))
    product = add("product", isa="PBXFileReference", explicitFileType="wrapper.cfbundle",
                  includeInIndex=0, path="DriveAppleTests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
    products = add("products", isa="PBXGroup", children=[product], name="Products", sourceTree="<group>")
    group = add("root-group", isa="PBXGroup", children=references + [products], sourceTree="<group>")
    sources = add("sources", isa="PBXSourcesBuildPhase", buildActionMask=2147483647,
                  files=build_files, runOnlyForDeploymentPostprocessing=0)
    frameworks = add("frameworks", isa="PBXFrameworksBuildPhase", buildActionMask=2147483647,
                     files=[], runOnlyForDeploymentPostprocessing=0)
    project_configs = []
    target_configs = []
    for configuration in ["Debug", "Release"]:
        project_configs.append(add(f"project-{configuration}", isa="XCBuildConfiguration",
                                   name=configuration, buildSettings={
                                       "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
                                       "SWIFT_VERSION": "6.0", "CLANG_ENABLE_MODULES": "YES",
                                   }))
        settings = {
            "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "dev.lui.drive.xctest",
            "GENERATE_INFOPLIST_FILE": "YES", "TARGETED_DEVICE_FAMILY": "1,2",
            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SKIP_INSTALL": "YES",
            "ENABLE_TESTING_SEARCH_PATHS": "YES", "SWIFT_STRICT_CONCURRENCY": "complete",
            "FRAMEWORK_SEARCH_PATHS": ["$(inherited)", "$(PLATFORM_DIR)/Developer/Library/Frameworks"],
            "LIBRARY_SEARCH_PATHS": ["$(inherited)", "$(PLATFORM_DIR)/Developer/usr/lib"],
            "OTHER_LDFLAGS": ["$(inherited)", "-framework", "XCTest"],
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"],
            "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "YES",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if configuration == "Debug" else "-O",
        }
        if configuration == "Debug":
            settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = ["$(inherited)", "DEBUG"]
        target_configs.append(add(f"target-{configuration}", isa="XCBuildConfiguration",
                                  name=configuration, buildSettings=settings))
    project_config_list = add("project-configs", isa="XCConfigurationList",
                              buildConfigurations=project_configs, defaultConfigurationIsVisible=0,
                              defaultConfigurationName="Debug")
    target_config_list = add("target-configs", isa="XCConfigurationList",
                             buildConfigurations=target_configs, defaultConfigurationIsVisible=0,
                             defaultConfigurationName="Debug")
    target = add("target", isa="PBXNativeTarget", name="DriveAppleTests", productName="DriveAppleTests",
                 buildConfigurationList=target_config_list, buildPhases=[sources, frameworks],
                 buildRules=[], dependencies=[], productReference=product,
                 productType="com.apple.product-type.bundle.ui-testing")
    root = add("project", isa="PBXProject", attributes={"LastUpgradeCheck": "2600"},
               buildConfigurationList=project_config_list, compatibilityVersion="Xcode 14.0",
               developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "Base"],
               mainGroup=group, productRefGroup=products, projectDirPath="", projectRoot="", targets=[target])
    (project / "project.pbxproj").write_text("// !$*UTF8*$!\n" + openstep({
        "archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": root,
    }) + "\n", encoding="utf-8")

    scheme = ET.Element("Scheme", LastUpgradeVersion="2600", version="1.3")
    build = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="NO", buildImplicitDependencies="NO")
    entries = ET.SubElement(build, "BuildActionEntries")
    entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="NO",
                          buildForProfiling="NO", buildForArchiving="NO", buildForAnalyzing="YES")
    reference_attributes = {
        "BuildableIdentifier": "primary", "BlueprintIdentifier": target,
        "BuildableName": "DriveAppleTests.xctest", "BlueprintName": "DriveAppleTests",
        "ReferencedContainer": "container:DriveApple.xcodeproj",
    }
    ET.SubElement(entry, "BuildableReference", **reference_attributes)
    action = ET.SubElement(scheme, "TestAction", buildConfiguration="Debug",
                           selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                           selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB",
                           shouldUseLaunchSchemeArgsEnv="NO")
    testables = ET.SubElement(action, "Testables")
    testable = ET.SubElement(testables, "TestableReference", skipped="NO", parallelizable="NO")
    ET.SubElement(testable, "BuildableReference", **reference_attributes)
    environment = ET.SubElement(action, "EnvironmentVariables")
    for key, value in {"DRIVE_XCTEST": "1", "DRIVE_APP_BUNDLE_ID": args.app_bundle_id}.items():
        ET.SubElement(environment, "EnvironmentVariable", key=key, value=value, isEnabled="YES")
    ET.indent(scheme)
    ET.ElementTree(scheme).write(scheme_directory / "DriveApple.xcscheme", encoding="utf-8", xml_declaration=True)
    print(project)
    print("Generated UI-testing-only project; no app build, Simulator launch, or UI test was executed.")


if __name__ == "__main__":
    main()
