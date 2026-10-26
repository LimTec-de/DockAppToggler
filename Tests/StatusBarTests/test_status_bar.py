"""Opt-in macOS 27 integration: DOCKAPP_TEST_STATUS_BAR=1 python3 Tests/StatusBarTests/test_status_bar.py.

Requires Accessibility for the invoking terminal. Creates temporary status items,
briefly applies native visibility restrictions, then restores the menu bar.
"""
import os
import pathlib
import plistlib
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.environ.get("DOCKAPP_TEST_STATUS_BAR") == "1", "Live menu-bar test is opt-in")
class StatusBarTests(unittest.TestCase):
    def test_native_visibility_lifecycle(self):
        repo = pathlib.Path(__file__).resolve().parents[2]
        sources = repo / "Sources/DockAppToggler"
        with tempfile.TemporaryDirectory(prefix="dockapp-tray-test-") as directory:
            root = pathlib.Path(directory)
            app = root / "TrayTest.app"
            binary = app / "Contents/MacOS/TrayTest"
            binary.parent.mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "com.limtec.dockapptoggler.tray-integration",
                "CFBundleExecutable": "TrayTest", "CFBundleName": "TrayTest",
                "CFBundlePackageType": "APPL", "LSUIElement": True,
            }))
            headers = repo / "Sources/MenuBarVisibility/include"
            (root / "module.modulemap").write_text(
                f'module MenuBarVisibility {{ umbrella header "{headers / "MenuBarVisibility.h"}" export * }}\n'
            )
            bridge = root / "bridge.o"
            subprocess.run([
                "clang", "-fobjc-arc", "-mmacosx-version-min=13.0", "-I", str(headers),
                "-c", str(repo / "Sources/MenuBarVisibility/MenuBarVisibility.m"), "-o", str(bridge),
            ], check=True, text=True)
            subprocess.run([
                "swiftc", "-swift-version", "6", "-target", f"{os.uname().machine}-apple-macosx13.0",
                "-I", str(root), str(repo / "Tests/StatusBarTests/main.swift"),
                *[str(sources / path) for path in [
                    "Features/StatusBar/NativeTrayController.swift", "Features/StatusBar/TrayMenuInventory.swift",
                    "Features/StatusBar/TrayMenuLayout.swift", "UI/StatusBar/TrayOverflowPanel.swift", "Utils/Logger.swift",
                ]], str(bridge), "-o", str(binary),
            ], check=True, text=True)
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=35)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: collapse, expand, rapid toggles, stop, editing", result.stdout)


if __name__ == "__main__":
    unittest.main()
