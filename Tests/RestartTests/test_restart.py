import json
import os
import pathlib
import plistlib
import signal
import subprocess
import tempfile
import time
import unittest
import uuid


class RestartTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo = pathlib.Path(__file__).resolve().parents[2]
        cls.temporary = tempfile.TemporaryDirectory(prefix="dockapp-restart-test-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = pathlib.Path(cls.temporary.name)
        cls.executable = cls.root / "RestartTest"
        subprocess.run([
            "swiftc", "-swift-version", "6",
            str(cls.repo / "Tests/RestartTests/main.swift"),
            str(cls.repo / "Sources/DockAppToggler/Core/Extensions/NSApplication+Extensions.swift"),
            str(cls.repo / "Sources/DockAppToggler/Utils/Logger.swift"),
            "-o", str(cls.executable),
        ], check=True, capture_output=True, text=True)

    def check_restart(self, skip_update_check):
        test_root = self.root / str(uuid.uuid4())
        app = test_root / "App with spaces.app"
        binary = app / "Contents/MacOS/RestartTest"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(self.executable.read_bytes())
        binary.chmod(0o755)
        output = test_root / "output"
        output.mkdir()
        info = {
            "CFBundleIdentifier": "com.limtec.restart-test." + uuid.uuid4().hex,
            "CFBundleExecutable": "RestartTest",
            "CFBundleName": "Restart Test",
            "CFBundlePackageType": "APPL",
            "LSUIElement": True,
            "TestOutput": str(output),
            "SkipUpdateCheck": skip_update_check,
        }
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)

        def running_pids():
            processes = subprocess.run(["ps", "-axo", "pid=,comm="], check=True, capture_output=True, text=True)
            return {
                int(pid) for line in processes.stdout.splitlines()
                for pid, command in [line.strip().split(None, 1)]
                if command == str(binary)
            }

        process = subprocess.Popen([str(binary)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and len(list(output.glob("terminated-*"))) < 3:
                time.sleep(0.1)
            launches = [json.loads(path.read_text()) for path in sorted(output.glob("launch-*.json"))]
            self.assertEqual(len(launches), 3, "Each restart must launch exactly one replacement")
            self.assertEqual(len({launch["pid"] for launch in launches}), 3, "Restart must create a new process")
            self.assertEqual(len(list(output.glob("terminated-*"))), 3, "Every instance must terminate through AppKit")
            for launch in launches[1:]:
                self.assertEqual(launch["arguments"][1:], ["--s"] if skip_update_check else [])
            process.wait(timeout=5)
            deadline = time.monotonic() + 5
            while running_pids() and time.monotonic() < deadline:
                time.sleep(0.1)
            self.assertFalse(running_pids(), "Terminated instances must actually exit")
        finally:
            for pid in running_pids():
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            process.wait(timeout=5)

    def test_restart_skips_updates_and_terminates_old_instances(self):
        self.check_restart(skip_update_check=True)

    def test_restart_can_keep_update_checks_enabled(self):
        self.check_restart(skip_update_check=False)


if __name__ == "__main__":
    unittest.main()
