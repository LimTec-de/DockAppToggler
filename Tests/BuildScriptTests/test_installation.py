import os
import pathlib
import stat
import subprocess
import tempfile
import unittest


class InstallationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        script = (pathlib.Path(__file__).resolve().parents[2] / "build.sh").read_text()
        cls.installer = script.split("<<'SWIFT'\n", 1)[1].split("\nSWIFT\n", 1)[0]

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dockapp-install-test-")
        self.addCleanup(self.temporary.cleanup)
        root = pathlib.Path(self.temporary.name)
        self.source = root / "Build with spaces" / "DockAppToggler.app"
        contents = self.source / "Contents"
        contents.mkdir(parents=True)
        (contents / "version").write_text("new")
        (contents / "current").symlink_to("version")
        self.destination = root / "Applications with spaces" / "DockAppToggler.app"
        self.destination.parent.mkdir()

    def install(self, source=None):
        return subprocess.run(
            ["swift", "-", str(source or self.source), str(self.destination)],
            input=self.installer, text=True, capture_output=True,
        )

    def test_first_install_preserves_bundle_and_symlinks(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / "Contents/current").read_text(), "new")
        self.assertTrue((self.destination / "Contents/current").is_symlink())
        self.assertTrue(self.source.is_dir())

    def test_update_replaces_old_bundle_without_merging(self):
        self.destination.mkdir()
        (self.destination / "obsolete-file").write_text("old")
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.destination / "obsolete-file").exists())
        self.assertEqual((self.destination / "Contents/version").read_text(), "new")

    def test_failed_copy_preserves_existing_installation(self):
        self.destination.mkdir()
        old = self.destination / "old-version"
        old.write_text("old")
        result = self.install(self.source.parent / "missing.app")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("App installation failed:", result.stderr)
        self.assertEqual(old.read_text(), "old")
        self.assertFalse((self.destination / "Contents").exists())

    def test_denied_replacement_preserves_existing_installation(self):
        self.destination.mkdir()
        old = self.destination / "old-version"
        old.write_text("old")
        os.chflags(self.destination, stat.UF_IMMUTABLE)
        self.addCleanup(os.chflags, self.destination, 0)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("App installation failed:", result.stderr)
        self.assertEqual(old.read_text(), "old")
        self.assertFalse((self.destination / "Contents").exists())


if __name__ == "__main__":
    unittest.main()
