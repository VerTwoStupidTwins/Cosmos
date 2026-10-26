"""Unprivileged lifecycle fixtures; execute only on Odin, never real state."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import struct
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
HELPER = Path(__file__).resolve().parents[1] / "packages/hermes-state-setup.py"


class StateSetupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(
            prefix="hermes-state-", dir=Path.home() / ".cache/cosmos-specialist-tests"
        )
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.foreign = self.base / "foreign"
        self.foreign.mkdir()
        self.sentinel = self.foreign / "config.yaml"
        self.sentinel.write_bytes(b"foreign-private-fixture")
        self.sentinel.chmod(0o600)
        self.before = self.snapshot()
        protected = {(p.stat().st_dev, p.stat().st_ino) for p in (self.foreign, self.sentinel)}
        real_open, real_fchown, real_fchmod = os.open, os.fchown, os.fchmod
        self.fixture_open = real_open
        def assert_not_foreign(fd):
            s = os.fstat(fd)
            self.assertNotIn((s.st_dev, s.st_ino), protected,
                             "helper accessed a foreign inode")
        def audited_open(*args, **kwargs):
            fd = real_open(*args, **kwargs)
            try:
                assert_not_foreign(fd)
            except AssertionError:
                os.close(fd)
                raise
            return fd
        def audited_chown(fd, *args):
            assert_not_foreign(fd)
            return real_fchown(fd, *args)
        def audited_chmod(fd, *args):
            assert_not_foreign(fd)
            return real_fchmod(fd, *args)
        # Real syscalls still execute: these tripwires detect even a foreign
        # open/chown/chmod that happens to leave bytes/mode/owner unchanged.
        for name, replacement in (("open", audited_open), ("fchown", audited_chown),
                                  ("fchmod", audited_chmod)):
            patcher = mock.patch.object(os, name, side_effect=replacement)
            patcher.start()
            self.addCleanup(patcher.stop)

    def snapshot(self):
        fd = getattr(self, "fixture_open", os.open)(self.sentinel, os.O_RDONLY | os.O_NOATIME)
        try:
            data = os.read(fd, 1024)
            s = os.fstat(fd)
            return (data, s.st_uid, s.st_gid, s.st_mode, s.st_atime_ns)
        finally:
            os.close(fd)

    def helper(self):
        self.assertTrue(HELPER.exists(), "safe state provisioning helper is missing")
        spec = importlib.util.spec_from_file_location("hermes_state_setup", HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def provision(self):
        module = self.helper()
        # Only this in-process fixture API accepts a root identity override.
        # The production CLI always requires effective uid 0 and root-owned ancestors.
        with module.open_directory(str(self.base), owner=os.getuid()) as base_fd:
            return module.provision(
                base_fd, "state", uid=os.getuid(), gid=os.getgid(),
                root_uid=os.getuid(), files={"config.yaml": b"{\"managed\":true}",
                                            ".env": b"PUBLIC_FIXTURE=1\n",
                                            "SOUL.md": b"local policy\n",
                                            ".managed": b"nixos\n"},
            )

    def test_root_phase_never_forks_or_enters_nested_log_data(self):
        with mock.patch.object(os, "fork", side_effect=AssertionError("root stage must not fork")):
            self.provision()
        self.assertFalse((self.base / "state/.hermes/logs/curator").exists())

    def test_service_phase_creates_curator_without_privilege_switch(self):
        self.provision()
        module = self.helper()
        self.assertTrue(hasattr(module, "prepare_data"), "service-user phase is missing")
        home = self.base / "state/.hermes"
        with module.open_directory(str(home), owner=os.getuid()) as fd:
            with mock.patch.object(os, "fork", side_effect=AssertionError("must not fork")), \
                 mock.patch.object(os, "setuid", side_effect=AssertionError("must not switch UID")), \
                 mock.patch.object(os, "setgid", side_effect=AssertionError("must not switch GID")):
                module.prepare_data(fd, uid=os.getuid(), gid=os.getgid())
        self.assertTrue((home / "logs/curator").is_dir())
        self.assertEqual((home / "logs/curator").stat().st_uid, os.getuid())

    def test_service_cli_does_not_read_credentials_or_publish_policy(self):
        self.provision()
        module = self.helper()
        home = self.base / "state/.hermes"
        original_policy = (home / "config.yaml").stat().st_ino
        manifest = {"user": "fixture", "group": "fixture", "state_dir": str(home.parent),
                    "credential_count": 1, "files": {}, "environment": {}}
        walker = module.open_directory
        with mock.patch.object(sys, "argv", ["setup", "--prepare-data", "/fixture-manifest"]), \
             mock.patch.object(module, "read_trusted_file", return_value=json.dumps(manifest).encode()) as read, \
             mock.patch.object(module.pwd, "getpwnam", return_value=mock.Mock(pw_uid=os.getuid())), \
             mock.patch.object(module.grp, "getgrnam", return_value=mock.Mock(gr_gid=os.getgid())), \
             mock.patch.object(module, "render_files", side_effect=AssertionError("must not render secrets")), \
             mock.patch.object(module, "provision", side_effect=AssertionError("must not publish policy")), \
             mock.patch.object(module, "open_directory", side_effect=lambda p: walker(p, owner=os.getuid())):
            module.main()
        read.assert_called_once_with("/fixture-manifest")
        self.assertEqual((home / "config.yaml").stat().st_ino, original_policy)
        self.assertTrue((home / "logs/curator").is_dir())

    def test_service_phase_rejects_root_and_curator_symlinks(self):
        self.provision()
        module = self.helper()
        home = self.base / "state/.hermes"
        with module.open_directory(str(home), owner=os.getuid()) as fd:
            with mock.patch.object(os, "geteuid", return_value=0):
                with self.assertRaises(ValueError):
                    module.prepare_data(fd, uid=os.getuid(), gid=os.getgid())
            (home / "logs/curator").symlink_to(self.foreign, target_is_directory=True)
            with self.assertRaises(ValueError):
                module.prepare_data(fd, uid=os.getuid(), gid=os.getgid())
        self.assertEqual(self.snapshot(), self.before)

    def test_home_symlink_rejected_without_foreign_access(self):
        state = self.base / "state"
        state.mkdir()
        (state / ".hermes").symlink_to(self.foreign, target_is_directory=True)
        with self.assertRaises((OSError, ValueError)):
            self.provision()
        self.assertEqual(self.snapshot(), self.before)
        self.assertTrue((state / ".hermes").is_symlink())

    def test_config_env_soul_symlinks_rejected_without_foreign_access(self):
        home = self.base / "state/.hermes"
        home.mkdir(parents=True)
        for name in ("config.yaml", ".env", "SOUL.md", ".managed"):
            with self.subTest(name=name):
                link = home / name
                link.symlink_to(self.sentinel)
                with self.assertRaises((OSError, ValueError)):
                    self.provision()
                self.assertEqual(self.snapshot(), self.before)
                self.assertTrue(link.is_symlink())
                link.unlink()

    def test_atomic_managed_files_and_existing_data_retained(self):
        home = self.base / "state/.hermes"
        home.mkdir(parents=True)
        data = home / "state.db"
        data.write_bytes(b"existing sqlite fixture")
        (home / "config.yaml").write_bytes(b"old-untrusted-config")
        previous_inode = (home / "config.yaml").stat().st_ino
        self.provision()
        self.assertEqual(data.read_bytes(), b"existing sqlite fixture")
        self.assertEqual((home / "config.yaml").read_bytes(), b'{"managed":true}')
        self.assertNotEqual((home / "config.yaml").stat().st_ino, previous_inode)
        for name in ("config.yaml", ".env", "SOUL.md", ".managed"):
            s = (home / name).stat()
            self.assertEqual((s.st_uid, s.st_gid), (os.getuid(), os.getgid()))
            self.assertEqual(stat.S_IMODE(s.st_mode), 0o640)
        self.assertEqual(stat.S_IMODE(home.stat().st_mode), 0o3770)
        self.assertEqual(stat.S_IMODE(home.parent.stat().st_mode), 0o750)

    def test_data_directories_created_and_existing_subtrees_untouched(self):
        self.provision()
        home = self.base / "state/.hermes"
        for name in ("memories", "skills", "sessions", "logs", "plugins", "cron",
                     "pairing", "hooks", "image_cache", "audio_cache"):
            self.assertTrue((home / name).is_dir(), name)
            self.assertEqual((home / name).stat().st_uid, os.getuid())
        self.assertTrue((home.parent / "workspace").is_dir())
        self.assertTrue((home.parent / "home").is_dir())
        (home / "memories/untrusted-link").symlink_to(self.sentinel)
        s = (home / "memories").stat()
        self.provision()
        self.assertEqual((home / "memories").stat().st_ino, s.st_ino)
        self.assertEqual(self.snapshot(), self.before)

    def test_existing_data_directory_symlink_rejected(self):
        home = self.base / "state/.hermes"
        home.mkdir(parents=True)
        (home / "memories").symlink_to(self.foreign, target_is_directory=True)
        with self.assertRaises((OSError, ValueError)):
            self.provision()
        self.assertEqual(self.snapshot(), self.before)

    def test_state_symlink_and_trusted_ancestor_symlink_rejected(self):
        (self.base / "state").symlink_to(self.foreign, target_is_directory=True)
        with self.assertRaises((OSError, ValueError)):
            self.provision()
        self.assertEqual(self.snapshot(), self.before)
        link = self.base / "ancestor-link"
        link.symlink_to(self.foreign, target_is_directory=True)
        with self.assertRaises((OSError, ValueError)):
            with self.helper().open_directory(str(link), owner=os.getuid()):
                self.fail("trusted path walker followed symlink")

    def test_trusted_sources_and_credentials_render_without_old_state_reads(self):
        module = self.helper()
        config = self.base / "declarative-config"
        config.write_bytes(b'{"model":"local"}')
        creds = self.base / "credentials"
        creds.mkdir()
        (creds / "env-0").write_bytes(b"SYNTHETIC_TEST_TOKEN=fixture-only\n")
        manifest = {"files": {"config.yaml": {"source": str(config)},
                               "SOUL.md": {"text": "local policy"}},
                    "environment": {"LOCAL_ONLY": "true"}, "credential_count": 1}
        self.assertTrue(hasattr(module, "render_files"), "trusted manifest renderer missing")
        files = module.render_files(manifest, str(creds), root_uid=os.getuid())
        self.assertEqual(files["config.yaml"], config.read_bytes())
        self.assertIn(b"SYNTHETIC_TEST_TOKEN=fixture-only", files[".env"])
        self.assertIn(b'LOCAL_ONLY="true"', files[".env"])
        self.assertEqual(files[".managed"], b"nixos\n")
        config.unlink()
        config.symlink_to(self.sentinel)
        with self.assertRaises((OSError, ValueError)):
            module.render_files(manifest, str(creds), root_uid=os.getuid())
        self.assertEqual(self.snapshot(), self.before)
        config.unlink()
        config.write_bytes(b"{}")
        (creds / "env-0").unlink()
        with self.assertRaises((OSError, ValueError)):
            module.render_files(manifest, str(creds), root_uid=os.getuid())

    def test_racing_policy_symlink_is_replaced_not_followed(self):
        module = self.helper()
        home = self.base / "state/.hermes"
        home.mkdir(parents=True)
        replace = os.replace
        def race(source, target, **kwargs):
            if target == "config.yaml":
                (home / target).symlink_to(self.sentinel)
            return replace(source, target, **kwargs)
        with mock.patch.object(os, "replace", side_effect=race):
            self.provision()
        self.assertEqual(self.snapshot(), self.before)
        self.assertFalse((home / "config.yaml").is_symlink())

    def test_hostile_inherited_acls_removed_from_privileged_directories(self):
        home = self.base / "state/.hermes"
        home.mkdir(parents=True)
        entries = ((1, 7, 0xFFFFFFFF), (2, 7, 65534), (4, 7, 0xFFFFFFFF),
                   (16, 7, 0xFFFFFFFF), (32, 0, 0xFFFFFFFF))
        acl = struct.pack("<I", 2) + b"".join(struct.pack("<HHI", *e) for e in entries)
        for path in (home.parent, home):
            os.setxattr(path, "system.posix_acl_default", acl)
            os.setxattr(path, "system.posix_acl_access", acl)
        self.provision()
        for path in (home.parent, home, home / ".env"):
            self.assertFalse(set(os.listxattr(path)) &
                             {"system.posix_acl_access", "system.posix_acl_default"})

    def test_silently_stripped_setgid_fails_closed(self):
        module = self.helper()
        directory = self.base / "mode-fixture"
        directory.mkdir()
        real_chmod = os.fchmod
        def strip_setgid(fd, mode):
            return real_chmod(fd, mode & ~stat.S_ISGID)
        with module.open_directory(str(directory), owner=os.getuid()) as fd:
            with mock.patch.object(os, "fchmod", side_effect=strip_setgid):
                with self.assertRaisesRegex(ValueError, "directory metadata"):
                    module.own_privileged_directory(
                        fd, uid=os.getuid(), gid=os.getgid(), mode=0o3770
                    )

    def test_hardlinked_policy_rejected_without_foreign_changes(self):
        home = self.base / "state/.hermes"
        home.mkdir(parents=True)
        os.link(self.sentinel, home / ".env")
        with self.assertRaises((OSError, ValueError)):
            self.provision()
        self.assertEqual(self.snapshot(), self.before)


class NativeModuleTests(unittest.TestCase):
    def test_no_upstream_root_configuration_or_user_manager_escape(self):
        feature = HELPER.parents[1] / "modules/features/agents/hermes-local.nix"
        text = feature.read_text()
        self.assertNotIn("inputs.hermes-agent.nixosModules.default", text)
        self.assertIn("/nix/moduleCommon.nix", text)
        self.assertIn("linger = false", text)
        self.assertIn('overrideStrategy = "asDropin"', text)
        self.assertIn("ExecCondition", text)
        self.assertIn("LoadCredential", text)
        for path in ("/run/user", "/run/dbus", "/run/systemd/private",
                     "/run/systemd/resolve/io.systemd.Resolve", "/run/nscd", "/run/nsncd",
                     "/nix/var/nix/daemon-socket"):
            self.assertIn(path, text)
        for unsafe in ("mkStateScript", "system.activationScripts", "tmpfiles.rules", "chown -R"):
            self.assertNotIn(unsafe, text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
