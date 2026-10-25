"""Fd-anchored Hermes lifecycle provisioning; never inspect old policy contents."""
import argparse
from contextlib import contextmanager
import errno
import grp
import hmac
import json
import os
import pwd
import re
import secrets
import stat
import sys

DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


@contextmanager
def open_directory(path, *, owner=0):
    """Walk an absolute trusted path without traversing any symlink."""
    if not path.startswith("/") or any(p in (".", "..") for p in path.split("/")):
        raise ValueError("invalid directory path")
    fd = os.open("/", DIR_FLAGS)
    try:
        for part in filter(None, path.split("/")):
            child = os.open(part, DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = child
            s = os.fstat(fd)
            if s.st_uid not in (0, owner):
                raise ValueError("untrusted directory owner")
            if s.st_mode & 0o022 and not s.st_mode & stat.S_ISVTX:
                raise ValueError("untrusted writable directory")
        yield fd
    finally:
        os.close(fd)


def own_privileged_directory(fd, *, uid, gid, mode):
    """Quiesce a migrated directory and erase agent-controlled inherited ACLs."""
    os.fchown(fd, uid, gid)
    os.fchmod(fd, 0o700)
    for attribute in ("system.posix_acl_access", "system.posix_acl_default"):
        try:
            os.removexattr(fd, attribute)
        except OSError as exc:
            if exc.errno not in (errno.ENODATA, errno.ENOTSUP):
                raise
    os.fchmod(fd, mode)
    actual = os.fstat(fd)
    if (actual.st_uid, actual.st_gid, stat.S_IMODE(actual.st_mode)) != (uid, gid, mode):
        raise ValueError("directory metadata does not match required policy")


def data_directory(parent_fd, name, *, uid, gid):
    """Only provision a fresh inode; existing data is validated, never changed."""
    try:
        os.mkdir(name, 0o700, dir_fd=parent_fd)
    except FileExistsError:
        s = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISDIR(s.st_mode) or s.st_uid != uid:
            raise ValueError("hostile data directory")
        return
    fd = os.open(name, DIR_FLAGS, dir_fd=parent_fd)
    try:
        os.fchown(fd, uid, gid)
    finally:
        os.close(fd)


def prepare_data(home_fd, *, uid, gid):
    """Run only as the service user; root never enters mutable nested log data."""
    if uid == 0 or (os.geteuid(), os.getegid()) != (uid, gid):
        raise ValueError("data preparation requires the service identity")
    logs = os.open("logs", DIR_FLAGS, dir_fd=home_fd)
    try:
        if os.fstat(logs).st_uid != uid:
            raise ValueError("unexpected logs owner")
        data_directory(logs, "curator", uid=uid, gid=gid)
    finally:
        os.close(logs)


def provision(parent_fd, name, *, uid, gid, files, root_uid=0):
    """Own the stable state inode before opening its children (migration safe)."""
    if not name or "/" in name or name in (".", ".."):
        raise ValueError("invalid state name")
    try:
        os.mkdir(name, 0o750, dir_fd=parent_fd)
    except FileExistsError:
        pass
    state = os.open(name, DIR_FLAGS, dir_fd=parent_fd)
    try:
        if os.fstat(state).st_uid not in (uid, root_uid):
            raise ValueError("unexpected state owner")
        own_privileged_directory(state, uid=root_uid, gid=gid, mode=0o750)
        try:
            os.mkdir(".hermes", 0o700, dir_fd=state)
        except FileExistsError:
            pass
        home = os.open(".hermes", DIR_FLAGS, dir_fd=state)
        try:
            if os.fstat(home).st_uid not in (uid, root_uid):
                raise ValueError("unexpected home owner")
            own_privileged_directory(home, uid=root_uid, gid=gid, mode=0o3770)
            # Validate all destinations before publishing any policy. Never open,
            # read, chmod or chown a preexisting policy inode.
            for filename in files:
                if not filename or "/" in filename or filename in (".", ".."):
                    raise ValueError("invalid managed filename")
                try:
                    s = os.stat(filename, dir_fd=home, follow_symlinks=False)
                except FileNotFoundError:
                    continue
                if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1:
                    raise ValueError("hostile managed destination")
            for directory in ("cron", "sessions", "logs", "memories", "plugins", "skills",
                              "pairing", "hooks", "image_cache", "audio_cache"):
                data_directory(home, directory, uid=uid, gid=gid)
            for directory in ("workspace", "home"):
                data_directory(state, directory, uid=uid, gid=gid)
            for filename, data in files.items():
                temporary = ".setup-" + secrets.token_hex(16)
                fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                             os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=state)
                try:
                    with os.fdopen(fd, "wb", closefd=False) as output:
                        output.write(data)
                        output.flush()
                    os.fchown(fd, root_uid, gid)
                    os.fchmod(fd, 0o640)
                    os.fsync(fd)
                    os.replace(temporary, filename, src_dir_fd=state, dst_dir_fd=home)
                finally:
                    os.close(fd)
                    try:
                        os.unlink(temporary, dir_fd=state)
                    except FileNotFoundError:
                        pass
            os.fsync(home)
            os.fsync(state)
        finally:
            os.close(home)
    finally:
        os.close(state)


def read_trusted_file(path, *, root_uid=0, private=False):
    """Only read immutable regular inputs beneath trusted, no-follow ancestors."""
    parent, name = os.path.split(path)
    if name in ("", ".", ".."):
        raise ValueError("invalid trusted file")
    with open_directory(parent, owner=root_uid) as directory:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                     dir_fd=directory)
        try:
            s = os.fstat(fd)
            if not stat.S_ISREG(s.st_mode) or s.st_uid != root_uid or s.st_mode & 0o022:
                raise ValueError("untrusted input file")
            if private and (s.st_nlink != 1 or stat.S_IMODE(s.st_mode) != 0o600):
                raise ValueError("untrusted private input file")
            with os.fdopen(fd, "rb", closefd=False) as source:
                return source.read()
        finally:
            os.close(fd)


def render_files(manifest, credentials_directory, *, root_uid=0):
    files = {}
    for name, entry in manifest["files"].items():
        if "credential" in entry:
            alias = entry["credential"]
            if not re.fullmatch(r"home-[0-9]+", alias):
                raise ValueError("invalid private file credential")
            original = read_trusted_file(entry["trusted_source"], root_uid=root_uid, private=True)
            copy = read_trusted_file(credentials_directory + "/" + alias, root_uid=root_uid)
            if not hmac.compare_digest(original, copy):
                raise ValueError("private source changed during credential loading")
            files[name] = copy
        else:
            files[name] = (read_trusted_file(entry["source"], root_uid=root_uid)
                           if "source" in entry else entry["text"].encode())
    environment = []
    for key, value in manifest["environment"].items():
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            raise ValueError("invalid environment key")
        environment.append(key + "=" + json.dumps(value, ensure_ascii=False))
    env = ("\n".join(environment) + "\n").encode()
    for index in range(manifest["credential_count"]):
        env += b"\n" + read_trusted_file(
            credentials_directory + "/env-" + str(index), root_uid=root_uid
        ) + b"\n"
    files[".env"] = env
    files[".managed"] = b"nixos\n"
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest")
    parser.add_argument("--prepare-data", action="store_true")
    args = parser.parse_args()
    if not args.prepare_data and os.geteuid() != 0:
        raise ValueError("state setup requires root")
    manifest = json.loads(read_trusted_file(args.manifest))
    uid = pwd.getpwnam(manifest["user"]).pw_uid
    gid = grp.getgrnam(manifest["group"]).gr_gid
    if uid == 0 or gid == 0:
        raise ValueError("service identity must not be root")
    if args.prepare_data:
        if (os.geteuid(), os.getegid()) != (uid, gid):
            raise ValueError("data preparation requires the service identity")
        with open_directory(manifest["state_dir"]) as state:
            home = os.open(".hermes", DIR_FLAGS, dir_fd=state)
            try:
                prepare_data(home, uid=uid, gid=gid)
            finally:
                os.close(home)
        return
    credentials = os.environ.get("CREDENTIALS_DIRECTORY", "")
    # These are systemd's root-managed copies, not the SOPS symlink or agent state.
    private_files = any("credential" in entry for entry in manifest["files"].values())
    if (manifest["credential_count"] or private_files) and not credentials.startswith("/run/credentials/"):
        raise ValueError("missing trusted runtime credentials")
    files = render_files(manifest, credentials)
    state_parent, state_name = os.path.split(manifest["state_dir"])
    with open_directory(state_parent) as parent:
        provision(parent, state_name, uid=uid, gid=gid, files=files)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError):
        # Never include paths, input contents, parser exceptions, or credentials.
        print("hermes-state-setup: refused unsafe or unavailable state/input", file=sys.stderr)
        sys.exit(1)
