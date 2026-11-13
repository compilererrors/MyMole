#!/usr/bin/env python3
"""Negative tests for cleanup; all files belong to leased synthetic roots."""
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("cleanup", Path(__file__).with_name("test-cleanup.py"))
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.owned = []
        self.root, self.token = self.make_root()

    def make_root(self):
        root = Path(tempfile.mkdtemp(prefix="mymole-cleanup-test-")).resolve()
        token = cleanup.lease(str(root))
        self.owned.append((root, token))
        return root, token

    def tearDown(self):
        for root, token in self.owned:
            if root.exists():
                cleanup.clean(str(root), token)

    def test_dry_run_is_read_only_and_cleanup_uses_the_same_target(self):
        (self.root / "Synthetic files").mkdir()
        file = self.root / "Synthetic files" / "--literal $(name).txt"
        file.write_text("synthetic contents")
        cleanup.clean(str(self.root), self.token, dry_run=True)
        self.assertEqual(file.read_text(), "synthetic contents")
        cleanup.clean(str(self.root), self.token)
        self.assertFalse(self.root.exists())

    def test_wrong_directory_cannot_use_another_lease(self):
        other, _ = self.make_root()
        sentinel = other / "sentinel"
        sentinel.write_text("keep")
        with self.assertRaises(ValueError):
            cleanup.clean(str(other), self.token)
        self.assertEqual(sentinel.read_text(), "keep")

    def test_symlinks_are_unlinked_without_following_them(self):
        other, _ = self.make_root()
        sentinel = other / "sentinel"
        sentinel.write_text("keep")
        (self.root / "linked-folder").symlink_to(other, target_is_directory=True)
        cleanup.clean(str(self.root), self.token)
        self.assertEqual(sentinel.read_text(), "keep")

    def test_a_symlink_cannot_replace_the_root(self):
        other, _ = self.make_root()
        moved = self.root.with_name(self.root.name + "-held")
        self.root.rename(moved)
        self.root.symlink_to(other, target_is_directory=True)
        try:
            with self.assertRaises(OSError):
                cleanup.clean(str(self.root), self.token)
            self.assertTrue((other / cleanup.MARKER).exists())
        finally:
            self.root.unlink()
            moved.rename(self.root)

    def test_replaced_entries_stop_the_verified_plan(self):
        file = self.root / "entry"
        file.write_text("original")
        fd = os.open(self.root, cleanup.FLAGS)
        try:
            plan = [entry for entry in cleanup.plan(fd, os.fstat(fd).st_dev) if entry[0] == "entry"]
            file.rename(self.root / "original-held")
            file.write_text("replacement")
            with self.assertRaises(ValueError):
                cleanup.execute(fd, plan)
            self.assertEqual(file.read_text(), "replacement")
            self.assertEqual((self.root / "original-held").read_text(), "original")
        finally:
            os.close(fd)

    def test_marker_tampering_stops_every_deletion(self):
        marker = self.root / cleanup.MARKER
        before = marker.read_bytes()
        marker.write_text('{"nonce":"changed"}')
        try:
            with self.assertRaises(ValueError):
                cleanup.clean(str(self.root), self.token)
            self.assertTrue(marker.exists())
        finally:
            marker.write_bytes(before)

    def test_unsafe_roots_and_unleased_contents_are_refused(self):
        for path in ["", "/", "/private/tmp", "relative-folder", str(self.root.parent) + "//" + self.root.name]:
            with self.assertRaises((ValueError, OSError)):
                cleanup.clean(path, self.token)
        with self.assertRaises(ValueError):
            cleanup.lease(str(self.root))

    def test_changed_permissions_stop_cleanup(self):
        self.root.chmod(0o755)
        try:
            with self.assertRaises(ValueError):
                cleanup.clean(str(self.root), self.token)
        finally:
            self.root.chmod(0o700)

    def test_ci_shell_checks_have_no_recursive_rm_commands(self):
        scripts = Path(__file__).parent
        for name in ["test-guarded.sh", "test-e2e.sh", "test-strings-guard.sh", "test-policy-guard.sh", "check-no-strings.sh", "sync-strings.sh"]:
            self.assertNotRegex((scripts / name).read_text(), r"\brm\s+-[a-zA-Z]*[rf]")


if __name__ == "__main__":
    unittest.main()
