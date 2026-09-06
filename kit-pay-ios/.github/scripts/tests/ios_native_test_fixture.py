"""Small generated-product fixture for native command and registration checks."""
from pathlib import Path
import plistlib


def write_native_products(runner_temp: Path):
    products_root = runner_temp / "KitPay-quality-derived/Build/Products"
    products = products_root / "Debug-iphonesimulator"
    identities = {
        "KitPay.app": "africa.kit.pay.ios",
        "KitPay.app/PlugIns/KitPayTests.xctest": "africa.kit.pay.ios.tests",
        "KitPayUITests-Runner.app": "africa.kit.pay.ios.uitests.xctrunner",
        "KitPayUITests-Runner.app/PlugIns/KitPayUITests.xctest": "africa.kit.pay.ios.uitests",
    }
    for name, identifier in identities.items():
        bundle = products / name
        bundle.mkdir(parents=True)
        (bundle / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "fixture",
            "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
        }))
        (bundle / "fixture").write_bytes(b"fixture")

    targets = []
    for name, host in (("KitPayTests", "KitPay.app"), ("KitPayUITests", "KitPayUITests-Runner.app")):
        targets.append({
            "BlueprintName": name,
            "TestHostPath": "__TESTROOT__/Debug-iphonesimulator/" + host,
            "TestHostBundleIdentifier": identities[host],
            "TestBundlePath": "__TESTHOST__/PlugIns/" + name + ".xctest",
            "UITargetAppPath": "__TESTROOT__/Debug-iphonesimulator/KitPay.app",
            "UITargetAppBundleIdentifier": "africa.kit.pay.ios",
            "IsAppHostedTestBundle": True,
            "IsUITestBundle": name == "KitPayUITests",
            "TestingEnvironmentVariables": {"DYLD_FRAMEWORK_PATH": "__TESTROOT__/Debug-iphonesimulator",
                                             "XCInjectBundleInto": "__TESTHOST__/fixture"},
            "DependentProductPaths": ["__TESTROOT__/Debug-iphonesimulator/" + host],
            "CommandLineArguments": ["unchanged-fixture-argument"],
            "EnvironmentVariables": {"UNCHANGED_FIXTURE_VARIABLE": "yes"},
            "GeneratedOnlyField": {"nested": [1, 2, 3]},
        })
    plan = {
        "__xctestrun_metadata__": {"FormatVersion": 2, "GeneratedMetadata": "preserve"},
        "TestPlan": {"Name": "KitPay", "IsDefault": True},
        "TestConfigurations": [{"Name": "Default", "IsEnabled": True, "TestTargets": targets}],
        "CodeCoverageBuildableInfos": [{"Name": "KitPay", "IncludeInReport": True}],
    }
    generated = products_root / "KitPay_iphonesimulator26.5-arm64.xctestrun"
    generated.write_bytes(plistlib.dumps(plan))
    return generated, plan
