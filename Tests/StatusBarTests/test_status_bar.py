"""Opt-in macOS 27 integration: DOCKAPP_TEST_STATUS_BAR=1 python3 Tests/StatusBarTests/test_status_bar.py.

Requires Accessibility for the invoking terminal and a quit DockAppToggler.
Temporarily installs "DockAppToggler Tray Test *.app" fixtures in /Applications
(macOS only attributes status items to apps installed there), briefly applies
native visibility restrictions, then restores the menu bar and removes them.
"""
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import unittest

PREFIX = "com.limtec.dockapptoggler.tray-test."
FIXTURES = ["visible", "hidden", "permanent", "new", "late"]


@unittest.skipUnless(os.environ.get("DOCKAPP_TEST_STATUS_BAR") == "1", "Live menu-bar test is opt-in")
class StatusBarTests(unittest.TestCase):
    def setUp(self):
        self.apps = {}
        # Fresh bundle identifiers per run; see main.swift.
        self.run_id = f"r{os.getpid()}"
        self.processes = {}
        self.directory = tempfile.TemporaryDirectory(prefix="dockapp-tray-test-")
        self.root = pathlib.Path(self.directory.name)
        self.addCleanup(self.cleanup)
        self.binary = self.build()
        for role in FIXTURES + ["controller"]:
            self.install(role, pathlib.Path("/Applications"))
        for role in ["outside", "controller-outside"]:
            self.install(role, self.root)

    def cleanup(self):
        for process in self.processes.values():
            process.kill()
            process.wait()
        for role, app in self.apps.items():
            shutil.rmtree(app, ignore_errors=True)
            for domain in (f"{PREFIX}{role}.{self.run_id}", f"{PREFIX}{role}.{self.run_id}.layout"):
                subprocess.run(["defaults", "delete", domain], capture_output=True)
                (pathlib.Path.home() / "Library/Preferences" / f"{domain}.plist").unlink(missing_ok=True)
        self.directory.cleanup()

    def build(self):
        repo = pathlib.Path(__file__).resolve().parents[2]
        sources = repo / "Sources/DockAppToggler"
        headers = repo / "Sources/MenuBarVisibility/include"
        (self.root / "module.modulemap").write_text(
            f'module MenuBarVisibility {{ umbrella header "{headers / "MenuBarVisibility.h"}" export * }}\n'
        )
        bridge = self.root / "bridge.o"
        subprocess.run([
            "clang", "-fobjc-arc", "-mmacosx-version-min=13.0", "-I", str(headers),
            "-c", str(repo / "Sources/MenuBarVisibility/MenuBarVisibility.m"), "-o", str(bridge),
        ], check=True, text=True)
        binary = self.root / "TrayTest"
        subprocess.run([
            "swiftc", "-swift-version", "6", "-target", f"{os.uname().machine}-apple-macosx13.0",
            "-I", str(self.root), str(repo / "Tests/StatusBarTests/main.swift"),
            *[str(sources / path) for path in [
                "Features/StatusBar/NativeTrayController.swift", "Features/StatusBar/TrayMenuInventory.swift",
                "Features/StatusBar/TrayMenuLayout.swift", "UI/StatusBar/TrayOverflowPanel.swift", "Utils/Logger.swift",
            ]], str(bridge), "-o", str(binary),
        ], check=True, text=True)
        return binary

    def install(self, role, directory):
        app = directory / f"DockAppToggler Tray Test {role}.app"
        shutil.rmtree(app, ignore_errors=True)
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": f"{PREFIX}{role}.{self.run_id}", "CFBundleExecutable": "TrayTest", "CFBundleName": f"TrayTest {role}",
            "CFBundlePackageType": "APPL", "LSUIElement": True,
        }))
        shutil.copy2(self.binary, app / "Contents/MacOS/TrayTest")
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
        self.apps[role] = app

    def launch(self, role):
        self.processes[role] = subprocess.Popen([str(self.apps[role] / "Contents/MacOS/TrayTest"), "--fixture", role[0].upper()])

    def quit(self, role):
        process = self.processes.pop(role)
        process.terminate()
        process.wait()

    def run_controller(self, role, *arguments):
        """Runs a controller and serves its requests to launch or quit fixtures."""
        controller = subprocess.Popen([str(self.apps[role] / "Contents/MacOS/TrayTest"), *arguments],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.processes[role] = controller
        output = []
        for line in controller.stdout:
            output.append(line)
            words = line.split()
            if words[:1] == ["REQUEST"]:
                if words[1] in ("quit", "relaunch"):
                    self.quit(words[2])
                if words[1] in ("launch", "relaunch"):
                    self.launch(words[2])
        errors = controller.stderr.read()
        controller.stdout.close()
        controller.stderr.close()
        self.assertEqual(controller.wait(timeout=10), 0, "".join(output) + errors)
        del self.processes[role]
        print("".join(output), end="")
        return "".join(output)

    def test_native_visibility_lifecycle(self):
        self.launch("visible")
        output = self.run_controller("controller")
        self.assertIn("PASS: sections, toggles, launches, editing, unplaceable apps, persistence", output)
        output = self.run_controller("controller-outside", "--outside-applications")
        self.assertIn("PASS: own icons outside /Applications", output)


if __name__ == "__main__":
    unittest.main()
