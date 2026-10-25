"""Pinned compatibility regression tests; root ownership metadata is simulated.

Real fixture paths/content and pinned discovery code are used. Distinct root/service
UIDs cannot be created without privilege; this is NOT installed-identity acceptance.
Run with HERMES_TEST_SOURCE pointing to the patched Python source tree.
"""
import importlib.util
import os
from pathlib import Path
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SOURCE = Path(os.environ["HERMES_TEST_SOURCE"])
spec = importlib.util.spec_from_file_location(
    "managed_discovery", SOURCE / "hermes_cli/gateway_runtime_discovery.py"
)
discovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(discovery)


def metadata(path, *, uid=0, gid=992, mode=None, links=1):
    values = list(os.lstat(path))
    values[3:6] = [links, uid, gid]
    if mode is not None:
        values[0] = stat.S_IFMT(values[0]) | mode
    return os.stat_result(values)


class ManagedHomeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="managed-home-", dir=os.environ["TMPDIR"])
        self.addCleanup(self.tmp.cleanup)
        self.parent = Path(self.tmp.name)
        self.home = self.parent / ".hermes"
        self.home.mkdir()
        self.marker = self.home / ".managed"
        self.marker.write_text("nixos\n")
        self.nodes = {ancestor: metadata(ancestor, mode=0o755) for ancestor in self.home.parents}
        self.nodes.update({
            self.parent: metadata(self.parent, mode=0o750),
            self.home: metadata(self.home, mode=0o3770),
            self.marker: metadata(self.marker, mode=0o640),
        })
        self.user = SimpleNamespace(pw_uid=993, pw_gid=992, pw_name="hermes")
        self.group = SimpleNamespace(gr_gid=992, gr_name="hermes", gr_mem=[])
        original_lstat = Path.lstat
        def lstat(path, *args, **kwargs):
            return self.nodes[path] if path in self.nodes else original_lstat(path, *args, **kwargs)
        for context in (
            patch.dict(os.environ, {"HERMES_MANAGED": "nixos"}),
            patch.object(Path, "lstat", lstat),
            patch.object(discovery.os, "getuid", return_value=993),
            patch("pwd.getpwuid", return_value=self.user),
            patch("pwd.getpwall", return_value=[self.user]),
            patch("grp.getgrgid", return_value=self.group),
            patch.object(discovery, "_may_have_access_acl", return_value=False),
        ):
            context.start()
            self.addCleanup(context.stop)

    def accepted(self):
        return discovery._private_node(self.home, kind="directory", home=True)

    def rejected(self):
        with self.assertRaises(discovery.DiscoveryError):
            self.accepted()

    def test_exact_root_managed_home_is_accepted(self):
        self.assertEqual(self.accepted().st_uid, 0)
        self.assertFalse(discovery.home_mode_unsafe(self.nodes[self.home], self.home))

    def test_unmanaged_root_home_is_rejected(self):
        with patch.dict(os.environ, {"HERMES_MANAGED": ""}):
            self.rejected()

    def test_home_modes_do_not_generalize(self):
        for mode in (0o770, 0o1770, 0o2770, 0o3777, 0o3750):
            with self.subTest(mode=oct(mode)):
                self.nodes[self.home] = metadata(self.home, mode=mode)
                self.rejected()

    def test_other_owner_or_group_is_rejected(self):
        for uid, gid in ((994, 992), (0, 994)):
            self.nodes[self.home] = metadata(self.home, uid=uid, gid=gid, mode=0o3770)
            self.rejected()

    def test_parent_must_be_root_owned_and_not_mutable(self):
        for uid, gid, mode in ((993, 992, 0o750), (0, 994, 0o750), (0, 992, 0o770), (0, 992, 0o757)):
            self.nodes[self.parent] = metadata(self.parent, uid=uid, gid=gid, mode=mode)
            self.rejected()

    def test_untrusted_ancestor_is_rejected(self):
        ancestor = self.parent.parent
        for uid, mode in ((993, 0o755), (0, 0o777)):
            self.nodes[ancestor] = metadata(ancestor, uid=uid, mode=mode)
            self.rejected()

    def test_shared_group_is_rejected(self):
        self.group.gr_mem.append("other")
        self.rejected()
        self.group.gr_mem.clear()
        with patch("pwd.getpwall", return_value=[self.user, SimpleNamespace(pw_uid=994, pw_gid=992)]):
            self.rejected()

    def test_acl_is_rejected(self):
        with patch.object(discovery, "_may_have_access_acl", return_value=True):
            self.rejected()

    def test_marker_integrity_is_required(self):
        for uid, gid, mode, links in ((993, 992, 0o640, 1), (0, 994, 0o640, 1),
                                     (0, 992, 0o660, 1), (0, 992, 0o640, 2)):
            self.nodes[self.marker] = metadata(self.marker, uid=uid, gid=gid, mode=mode, links=links)
            self.rejected()
        self.nodes[self.marker] = metadata(self.marker, mode=0o640)
        self.marker.write_text("not-nixos\n")
        self.rejected()
        self.marker.unlink()
        self.rejected()

    def test_runtime_files_do_not_get_root_exception(self):
        runtime = self.home / "gateway.sock.path"
        runtime.write_text("public fixture\n")
        self.nodes[runtime] = metadata(runtime, mode=0o600)
        with self.assertRaises(discovery.DiscoveryError):
            discovery._private_node(runtime, kind="file")
        self.nodes[runtime] = metadata(runtime, uid=993, mode=0o600)
        self.assertEqual(discovery._private_node(runtime, kind="file").st_uid, 993)


if __name__ == "__main__":
    unittest.main(verbosity=2)
