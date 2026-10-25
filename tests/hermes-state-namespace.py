"""Odin-only, real-credential root/service split; no sudo or host-root execution.

Run with Python 3.14 on Odin. The outer process must be unprivileged. A fresh
user/mount/network/PID namespace and private tmpfs chroot contain every mutation.
Root provision has only CHOWN,DAC_OVERRIDE,FOWNER (no SETUID/SETGID/FSETID).
A separate UID 993/GID 992 worker prepares logs/curator with zero capabilities.
The old Group=root SGID regression must fail; Group=hermes must retain 03770.

Example:
  python3.14 tests/hermes-state-namespace.py --result /absolute/scratch/result.json
A successful run writes JSON and returns zero; unavailable isolation is a failure,
not a skipped or simulated success. --worker/--namespace are internal entrypoints.
"""
import argparse
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import traceback

sys.dont_write_bytecode = True
PYTHON = "/nix/store/lb41b0anx1f98y9y5s9mdv97gjgsq740-python3-3.14.7/bin/python3.14"
SDK_PYTHON = "/nix/store/d7z9xfn4apdpb07p3ngdls0a2smd9w6a-hermes-agent-env/bin/python3"
SOURCE = "/nix/store/2qmk7gbidpr6546irsmpm1j7p5k4nlxs-hermes-managed-python-source"
SCRATCH = Path("/home/twins/.hermes/profiles/cosmos/cache/scratch")
CAPS = "-all,+chown,+dac_override,+fowner"
CAP_MASK = sum(1 << bit for bit in (0, 1, 3))
NAMESPACES = ("user", "mnt", "net", "pid")
DATA_DIRECTORIES = ("cron", "sessions", "logs", "memories", "plugins", "skills",
                    "pairing", "hooks", "image_cache", "audio_cache")
POLICIES = {".managed": b"nixos\n", "config.yaml": b"{}\n",
            ".env": b'PUBLIC_NAMESPACE_FIXTURE="1"\n', "SOUL.md": b"fixture policy\n"}


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def credentials():
    status = dict(line.split(":", 1) for line in Path("/proc/self/status").read_text().splitlines())
    return {"uid": os.getuid(), "euid": os.geteuid(), "gid": os.getgid(),
            "egid": os.getegid(), "groups": os.getgroups(),
            **{key: status[key].strip() for key in
               ("CapEff", "CapPrm", "CapBnd", "CapInh", "CapAmb", "NoNewPrivs")}}


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def metadata(path):
    node = path.stat()
    return {"uid": node.st_uid, "gid": node.st_gid,
            "mode": oct(stat.S_IMODE(node.st_mode))}


def worker(kind, gid):
    # Internal CLI switches must not provide a route to real host state either.
    proof = json.loads(Path("/fixture/isolation.json").read_text())
    for name in NAMESPACES:
        current = os.readlink("/proc/self/ns/" + name)
        require(current == proof["namespace_ids"][name]
                and current != proof["host_namespaces"][name], "worker escaped isolation")
    root_map = [line.split() for line in Path("/proc/self/uid_map").read_text().splitlines()
                if line.split()[0] == "0"]
    require(len(root_map) == 1 and int(root_map[0][1]) == proof["host_uid"] != 0,
            "worker refuses host root")
    creds = credentials()
    service = kind in ("prepare", "discovery")
    expected_uid = 993 if service else 0
    require((creds["uid"], creds["euid"], creds["gid"], creds["egid"], creds["groups"])
            == (expected_uid, expected_uid, gid, gid, []), "wrong real kernel identity")
    expected_caps = 0 if service else CAP_MASK
    for field in ("CapEff", "CapPrm", "CapBnd"):
        require(int(creds[field], 16) == expected_caps, "wrong capability set: " + field)
    require(int(creds["CapInh"], 16) == int(creds["CapAmb"], 16) == 0,
            "unexpected inherited or ambient capabilities")
    require(creds["NoNewPrivs"] == "1", "no-new-privs missing")
    if kind.startswith("raw-"):
        parent = Path("/var/lib") / kind
        parent.mkdir(mode=0o750)
        os.chown(parent, 0, 992)
        home = parent / ".hermes"
        home.mkdir(mode=0o700)
        fd = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fchown(fd, 0, 992)
            os.fchmod(fd, 0o3770)
            observed = os.fstat(fd)
        finally:
            os.close(fd)
        marker = home / ".managed"
        marker.write_bytes(b"nixos\n")
        os.chown(marker, 0, 992)
        marker.chmod(0o640)
        result = {"kind": kind, "credentials": creds, "home": metadata(home),
                  "postcondition": stat.S_IMODE(observed.st_mode) == 0o3770}
        print(json.dumps(result), flush=True)
        return 0 if result["postcondition"] else 1
    if kind == "provision":
        helper = load_module("hermes_state_setup", "/fixture/helper.py")
        denied_switches = []
        for operation, target in ((os.setuid, 993), (os.setgid, 991)):
            try:
                operation(target)
            except OSError as exc:
                require(exc.errno == errno.EPERM, "identity switch failed for unexpected reason")
                denied_switches.append({"operation": operation.__name__, "target": target,
                                        "errno": exc.errno})
            else:
                raise AssertionError("reduced-capability root unexpectedly switched identity")
        require(credentials() == creds, "identity denial changed root credentials")
        # Reproduce the live mixed legacy layout without reading any live state.
        legacy = Path("/var/lib/legacy/.hermes")
        legacy.parent.mkdir(mode=0o750)
        os.chown(legacy.parent, 0, 992)
        legacy.mkdir(mode=0o700)
        os.chown(legacy, 0, 992)
        legacy.chmod(0o3770)
        old_fds = {}
        for name, mode in ((".env", 0o640), ("SOUL.md", 0o640), (".managed", 0o644)):
            node = legacy / name
            node.write_bytes(b"old synthetic namespace policy\n")
            os.chown(node, 993, 992)
            node.chmod(mode)
            old_fds[name] = os.open(node, os.O_RDONLY | os.O_NOFOLLOW)
        for name in (*DATA_DIRECTORIES, "logs/curator"):
            node = legacy / name
            node.mkdir(mode=0o700)
            os.chown(node, 993, 992)
            node.chmod(0o2770)
        for name in ("workspace", "home"):
            node = legacy.parent / name
            node.mkdir(mode=0o700)
            os.chown(node, 993, 992)
        (legacy / "logs/curator/retained").write_bytes(b"retain service data\n")
        os.chown(legacy / "logs/curator/retained", 993, 992)
        preserved = {name: {**metadata(legacy / name), "inode": (legacy / name).stat().st_ino}
                     for name in (*DATA_DIRECTORIES, "logs/curator")}
        old_policy = {name: {"inode": os.fstat(fd).st_ino,
                             "mode": oct(stat.S_IMODE(os.fstat(fd).st_mode)),
                             "uid": os.fstat(fd).st_uid}
                      for name, fd in old_fds.items()}
        # An audit guard rejects even attempted helper traversal/privilege changes.
        # It is not a fake filesystem: every permitted operation reaches the kernel.
        guard = {"active": False, "blocked": [], "home": None,
                 "fresh_logs_metadata_opens": 0}

        def audit(event, arguments):
            if not guard["active"]:
                return
            forbidden = event in ("os.fork", "os.forkpty", "os.setuid", "os.setgid",
                                  "os.setreuid", "os.setregid", "os.setresuid",
                                  "os.setresgid", "os.setgroups")
            if event == "open" and isinstance(arguments[0], (str, bytes)):
                name = os.fsdecode(arguments[0]).rstrip("/").split("/")[-1]
                if name == "logs":
                    # Fresh data_directory must open its own root-owned inode to
                    # fchown it. It must never open an existing agent-owned logs.
                    fresh = (guard["home"] / "logs").stat().st_uid == 0
                    forbidden |= not fresh
                    guard["fresh_logs_metadata_opens"] += int(fresh)
                forbidden |= name == "curator"
            if forbidden:
                guard["blocked"].append(event)
                raise AssertionError("root helper attempted forbidden traversal/identity operation")

        sys.addaudithook(audit)
        layouts = []
        cli_record = None
        try:
            for state_name in ("hermes", "legacy", "cli-hermes"):
                if state_name == "cli-hermes":
                    command = [PYTHON, "-B", "/fixture/helper.py", "/fixture/root-manifest.json"]
                    process = subprocess.run(command, capture_output=True, text=True, timeout=20,
                                             env={"PATH": "/nonexistent", "PYTHONDONTWRITEBYTECODE": "1"})
                    cli_record = {"command": command, "returncode": process.returncode,
                                  "stdout": process.stdout, "stderr": process.stderr}
                    require(process.returncode == 0 and not process.stderr, "root CLI failed: " + process.stderr)
                else:
                    with helper.open_directory("/var/lib") as parent_fd:
                        guard["home"] = Path("/var/lib") / state_name / ".hermes"
                        guard["active"] = True
                        try:
                            helper.provision(parent_fd, state_name, uid=993, gid=992, files=POLICIES)
                        finally:
                            guard["active"] = False
                home = Path("/var/lib") / state_name / ".hermes"
                require(metadata(home) == {"uid": 0, "gid": 992, "mode": "0o3770"},
                        "root provision lost SGID")
                require(metadata(home.parent) == {"uid": 0, "gid": 992, "mode": "0o750"},
                        "wrong state directory")
                for name, data in POLICIES.items():
                    require((home / name).read_bytes() == data, "wrong fixture policy bytes")
                    require(metadata(home / name) == {"uid": 0, "gid": 992, "mode": "0o640"},
                            "wrong policy ownership/mode")
                for name in DATA_DIRECTORIES:
                    require((home / name).is_dir() and (home / name).stat().st_uid == 993,
                            "wrong service data directory")
                for name in ("workspace", "home"):
                    require((home.parent / name).stat().st_uid == 993, "wrong service state owner")
                layouts.append({"state": state_name, "home": metadata(home),
                                "policy_files_verified": list(POLICIES),
                                "data_directories_verified": list(DATA_DIRECTORIES)})
            for state_name in ("hermes", "cli-hermes"):
                require(not (Path("/var/lib") / state_name / ".hermes/logs/curator").exists(),
                        "root provision created curator")
            for name, before in preserved.items():
                node = legacy / name
                require({**metadata(node), "inode": node.stat().st_ino} == before,
                        "root provision mutated existing service data")
            for name, fd in old_fds.items():
                old = os.fstat(fd)
                require(old.st_uid == 993 and oct(stat.S_IMODE(old.st_mode)) == old_policy[name]["mode"],
                        "root provision changed old policy inode")
                require((legacy / name).stat().st_ino != old.st_ino,
                        "policy was not atomically replaced")
                require(os.read(fd, 4096) == b"old synthetic namespace policy\n",
                        "root provision changed old policy contents")
        finally:
            for fd in old_fds.values():
                os.close(fd)
        require(not guard["blocked"], "root helper attempted a forbidden operation")
        # prepare_data must refuse namespace root; it must never drop privileges.
        with helper.open_directory("/var/lib/hermes/.hermes") as home_fd:
            try:
                helper.prepare_data(home_fd, uid=993, gid=992)
            except ValueError:
                pass
            else:
                raise AssertionError("prepare_data accepted root credentials")
        # Malicious, wholly synthetic inputs for the zero-capability service phase.
        for case in ("logs-link", "curator-link", "logs-owner", "curator-owner"):
            home = Path("/var/lib") / case
            home.mkdir(mode=0o770)
            os.chown(home, 993, 992)
            if case == "logs-link":
                (home / "logs").symlink_to("/fixture")
                continue
            logs = home / "logs"
            logs.mkdir(mode=0o770)
            os.chown(logs, 0 if case == "logs-owner" else 993, 992)
            if case == "curator-link":
                (logs / "curator").symlink_to("/fixture")
            if case == "curator-owner":
                (logs / "curator").mkdir(mode=0o770)
                os.chown(logs / "curator", 0, 992)
        print(json.dumps({"kind": kind, "credentials": creds, "layouts": layouts,
                          "root_did_not_create_curator": True,
                          "root_did_not_enter_existing_logs": True,
                          "fresh_logs_metadata_opens": guard["fresh_logs_metadata_opens"],
                          "root_did_not_switch_identity": True,
                          "kernel_identity_switch_denials": denied_switches,
                          "root_cli": cli_record,
                          "legacy_data_preserved": preserved, "old_policy_inodes": old_policy,
                          "policy_atomic_replacement": True, "root_prepare_rejected": True}), flush=True)
        return 0
    if kind == "prepare":
        helper = load_module("hermes_state_setup", "/fixture/helper.py")
        layouts = []
        cli_record = None
        for state_name in ("hermes", "legacy", "cli-hermes"):
            home = Path("/var/lib") / state_name / ".hermes"
            before_policies = {name: {**metadata(home / name), "inode": (home / name).stat().st_ino}
                               for name in POLICIES}
            curator = home / "logs/curator"
            before_curator = ({**metadata(curator), "inode": curator.stat().st_ino}
                              if curator.exists() else None)
            if state_name == "cli-hermes":
                command = [SDK_PYTHON, "-B", "/fixture/helper.py", "--prepare-data",
                           "/fixture/prepare-manifest.json"]
                process = subprocess.run(command, capture_output=True, text=True, timeout=20,
                                         env={"PATH": "/nonexistent", "PYTHONDONTWRITEBYTECODE": "1"})
                cli_record = {"command": command, "returncode": process.returncode,
                              "stdout": process.stdout, "stderr": process.stderr}
                require(process.returncode == 0 and not process.stderr, "service CLI failed: " + process.stderr)
                require(curator.is_dir() and curator.stat().st_uid == 993,
                        "service CLI did not create curator")
            with helper.open_directory(str(home)) as home_fd:
                helper.prepare_data(home_fd, uid=993, gid=992)
                first = {**metadata(curator), "inode": curator.stat().st_ino}
                helper.prepare_data(home_fd, uid=993, gid=992)
                require(first == {**metadata(curator), "inode": curator.stat().st_ino},
                        "service preparation is not idempotent")
                if before_curator is not None:
                    require(first == before_curator, "legacy curator changed")
                    require((curator / "retained").read_bytes() == b"retain service data\n",
                            "legacy data contents changed")
                for uid, gid in ((994, 992), (993, 991), (0, 992), (993, 0)):
                    try:
                        helper.prepare_data(home_fd, uid=uid, gid=gid)
                    except ValueError:
                        pass
                    else:
                        raise AssertionError("prepare_data accepted mismatched/root identity")
            require(curator.stat().st_uid == 993 and curator.stat().st_gid == 992,
                    "curator has wrong service ownership")
            require(before_policies == {name: {**metadata(home / name), "inode": (home / name).stat().st_ino}
                                        for name in POLICIES}, "service preparation changed policy")
            layouts.append({"state": state_name, "curator": first,
                            "existing_curator_preserved": before_curator is not None,
                            "idempotent": True, "policy_unchanged": True})
        rejected = []
        for case in ("logs-link", "curator-link", "logs-owner", "curator-owner"):
            home_fd = os.open(Path("/var/lib") / case, helper.DIR_FLAGS)
            try:
                try:
                    helper.prepare_data(home_fd, uid=993, gid=992)
                except (OSError, ValueError):
                    rejected.append(case)
                else:
                    raise AssertionError("service preparation accepted hostile " + case)
            finally:
                os.close(home_fd)
        require(not Path("/fixture/curator").exists(), "logs symlink target was mutated")
        require(credentials() == creds, "service preparation changed credentials")
        print(json.dumps({"kind": kind, "credentials": creds, "layouts": layouts,
                          "service_cli": cli_record, "prepare_cli_did_not_read_policy_inputs": True,
                          "hostile_inputs_rejected": rejected, "mismatched_identities_rejected": True,
                          "symlink_target_unchanged": True}), flush=True)
        return 0
    require(kind == "discovery", "unknown worker")
    os.environ["HERMES_MANAGED"] = "nixos"
    discovery = load_module("managed_discovery", SOURCE + "/hermes_cli/gateway_runtime_discovery.py")
    rejected = False
    try:
        discovery._private_node(Path("/var/lib/raw-old/.hermes"), kind="directory", home=True)
    except discovery.DiscoveryError:
        rejected = True
    require(rejected, "discovery accepted missing SGID")
    for home in (Path("/var/lib/raw-fixed/.hermes"), Path("/var/lib/hermes/.hermes"),
                 Path("/var/lib/legacy/.hermes"), Path("/var/lib/cli-hermes/.hermes")):
        require(discovery._private_node(home, kind="directory", home=True).st_uid == 0,
                "discovery did not accept root-managed home")
    sticky_checks = []
    for state_name in ("hermes", "legacy", "cli-hermes"):
        home = Path("/var/lib") / state_name / ".hermes"
        for name in POLICIES:
            try:
                (home / name).unlink()
            except PermissionError:
                sticky_checks.append(state_name + "/" + name)
            else:
                raise AssertionError("sticky policy protection failed")
        require((home / "logs/curator").stat().st_uid == 993,
                "discovery ran before service data preparation")
    home = Path("/var/lib/hermes/.hermes")
    try:
        discovery._private_node(home / ".managed", kind="file")
    except discovery.DiscoveryError:
        pass
    else:
        raise AssertionError("root runtime-file exception was widened")
    runtime = home / "namespace-runtime"
    runtime.write_bytes(b"fixture runtime\n")
    runtime.chmod(0o600)
    require((runtime.stat().st_uid, runtime.stat().st_gid) == (993, 992),
            "new service file did not inherit service group")
    discovery._private_node(runtime, kind="file")
    endpoint = home / "gateway.sock"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
        listener.bind(str(endpoint))
        endpoint.chmod(0o600)
        listener.listen(1)
        listener.settimeout(10)
        child = os.fork()
        if child == 0:
            try:
                with listener.accept()[0] as connection:
                    connection.settimeout(10)
                    request = connection.recv(4096)
                    require(json.loads(request)["verb"] == "identify", "wrong SDK request")
                    connection.sendall(b'{"protocol":1,"id":1,"ok":true,"result":{"fixture":true,"uid":993}}\n')
            except BaseException:
                os._exit(1)
            os._exit(0)
        try:
            response = discovery.query_identify(home, timeout=10)
        finally:
            _, child_status = os.waitpid(child, 0)
        require(child_status == 0, "fixture control peer failed")
    require(response == {"fixture": True, "uid": 993}, "native SDK discovery failed")
    print(json.dumps({"kind": kind, "credentials": creds, "old_home_rejected": rejected,
                      "fixed_homes_accepted": True, "sticky_policy_protected": True,
                      "sticky_checks": sticky_checks,
                      "root_runtime_file_rejected": True, "runtime": metadata(runtime),
                      "native_query_identify": response}), flush=True)
    return 0


def namespace(config):
    # Check isolation before creating directories, mounting, or changing credentials.
    actual = {name: os.readlink("/proc/self/ns/" + name) for name in NAMESPACES}
    require(all(actual[name] != config["host_namespaces"][name] for name in NAMESPACES),
            "refusing mutations without separate user/mount/network/PID namespaces")
    uid_map = Path("/proc/self/uid_map").read_text()
    gid_map = Path("/proc/self/gid_map").read_text()
    root_map = [line.split() for line in uid_map.splitlines() if line.split()[0] == "0"]
    require(os.geteuid() == 0 and len(root_map) == 1
            and int(root_map[0][1]) == config["host_uid"] != 0, "refusing host root")
    root_mount = [line for line in Path("/proc/self/mountinfo").read_text().splitlines()
                  if line.split()[4] == "/"]
    require(root_mount and all("shared:" not in line and "master:" not in line for line in root_mount),
            "mount propagation is not private")
    root = Path(config["fixture"])
    require(root.parent == SCRATCH and root.name.startswith("hermes-sgid-ns-"),
            "fixture root outside approved scratch")
    require(root.is_dir() and not root.is_symlink(), "unsafe fixture root")

    def mount(*args):
        target = Path(args[-1])
        require(target == root or root in target.parents, "mount target escaped fixture")
        subprocess.run([config["mount"], *args], check=True, capture_output=True, text=True)

    mount("-t", "tmpfs", "-o", "mode=755,size=32m,nosuid,nodev", "hermes-sgid-fixture", str(root))
    for name in ("nix/store", "proc", "etc", "fixture", "var/lib"):
        (root / name).mkdir(parents=True, exist_ok=True, mode=0o755)
    mount("--bind", "/nix/store", str(root / "nix/store"))
    mount("-o", "remount,bind,ro", str(root / "nix/store"))
    mount("-t", "proc", "-o", "nosuid,nodev,noexec,ro", "proc", str(root / "proc"))
    shutil.copyfile(__file__, root / "fixture/test.py")
    shutil.copyfile(config["helper"], root / "fixture/helper.py")
    (root / "fixture/isolation.json").write_text(json.dumps({
        "namespace_ids": actual, "host_namespaces": config["host_namespaces"],
        "host_uid": config["host_uid"],
    }))
    (root / "etc/passwd").write_text("root:x:0:0:root:/root:/bin/false\nhermes:x:993:992:fixture:/var/lib/hermes/home:/bin/false\n")
    (root / "etc/group").write_text("root:x:0:\nhermes:x:992:\n")
    (root / "etc/nsswitch.conf").write_text("passwd: files\ngroup: files\n")
    manifest = {"state_dir": "/var/lib/cli-hermes", "user": "hermes", "group": "hermes",
                "files": {name: {"text": data.decode()} for name, data in POLICIES.items()
                          if name not in (".env", ".managed")},
                "environment": {"PUBLIC_NAMESPACE_FIXTURE": "1"}, "credential_count": 0}
    (root / "fixture/root-manifest.json").write_text(json.dumps(manifest))
    # prepare-only must not render policy or access root-only credentials/sources.
    manifest.update({"credential_count": 1, "files": {"SOUL.md": {"source": "/no-such-policy-input"}},
                     "environment": {"INVALID ENVIRONMENT KEY": "not used"}})
    (root / "fixture/prepare-manifest.json").write_text(json.dumps(manifest))
    os.chroot(root)
    os.chdir("/")
    require(Path("/").stat().st_uid == 0, "chroot ancestry is not namespace-root owned")
    results = {"namespace_ids": actual, "uid_map": uid_map, "gid_map": gid_map,
               "private_mount_propagation": True, "fixture": config["fixture"], "cases": []}
    expected_cases = (("raw-old", 0, 1), ("raw-fixed", 992, 0),
                      ("provision", 992, 0), ("prepare", 992, 0), ("discovery", 992, 0))
    for kind, gid, expected_rc in expected_cases:
        service = kind in ("prepare", "discovery")
        command = [config["setpriv"], "--bounding-set=" + ("-all" if service else CAPS),
                   "--inh-caps=-all", "--ambient-caps=-all", "--no-new-privs",
                   "--reuid=" + ("993" if service else "0"), "--regid=" + str(gid),
                   "--clear-groups", SDK_PYTHON if service else PYTHON,
                   "-B", "/fixture/test.py", "--worker", kind, "--gid", str(gid)]
        process = subprocess.run(command, text=True, capture_output=True, timeout=40,
                                 env={"PATH": "/nonexistent", "PYTHONDONTWRITEBYTECODE": "1", "HOME": "/var/lib/hermes/home"})
        record = {"kind": kind, "command": command, "returncode": process.returncode,
                  "expected_returncode": expected_rc,
                  "stdout": process.stdout, "stderr": process.stderr, "status": "failed"}
        results["cases"].append(record)
        if process.stdout:
            try:
                record["observed"] = json.loads(process.stdout)
            except ValueError:
                record["parse_error"] = "worker stdout was not valid JSON"
        if process.returncode == expected_rc and not process.stderr and "observed" in record:
            record["status"] = "passed"
    old, fixed = (case.get("observed", {}) for case in results["cases"][:2])
    results["sgid_regression_verified"] = (
        old.get("home", {}).get("mode") == "0o1770" and old.get("postcondition") is False
        and fixed.get("home", {}).get("mode") == "0o3770" and fixed.get("postcondition") is True)
    results["expected_case_count"] = len(expected_cases)
    results["collected_case_count"] = len(results["cases"])
    results["status"] = ("passed" if results["sgid_regression_verified"]
                         and len(results["cases"]) == len(expected_cases)
                         and all(case["status"] == "passed" for case in results["cases"]) else "failed")
    print(json.dumps(results), flush=True)
    return 0 if results["status"] == "passed" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result", type=Path)
    parser.add_argument("--namespace")
    parser.add_argument("--worker")
    parser.add_argument("--gid", type=int)
    args = parser.parse_args()
    if args.worker:
        return worker(args.worker, args.gid)
    if args.namespace:
        return namespace(json.loads(args.namespace))
    require(os.geteuid() != 0 and os.getuid() != 0, "run unprivileged, never host root")
    require(os.uname().nodename == "odin", "tests must run on Odin")
    script = Path(__file__).resolve()
    helper = script.parents[1] / "packages/hermes-state-setup.py"
    config = {"host_uid": os.getuid(),
              "host_namespaces": {name: os.readlink("/proc/self/ns/" + name) for name in NAMESPACES},
              "helper": str(helper), "mount": str(Path("/run/current-system/sw/bin/mount").resolve()),
              "setpriv": str(Path("/run/current-system/sw/bin/setpriv").resolve())}
    result = {"status": "failed", "test_sha256": hashlib.sha256(script.read_bytes()).hexdigest(),
              "helper_sha256": hashlib.sha256(helper.read_bytes()).hexdigest(),
              "sdk_discovery_sha256": hashlib.sha256(Path(SOURCE + "/hermes_cli/gateway_runtime_discovery.py").read_bytes()).hexdigest(),
              "host_uid": config["host_uid"], "host_namespaces": config["host_namespaces"]}
    SCRATCH.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="hermes-sgid-ns-", dir=SCRATCH) as fixture:
        config["fixture"] = fixture
        command = ["/run/current-system/sw/bin/unshare", "--user", "--map-auto", "--map-root-user",
                   "--mount", "--net", "--pid", "--fork", "--kill-child", "--propagation", "private",
                   PYTHON, "-B", str(script), "--namespace", json.dumps(config)]
        process = subprocess.run(command, text=True, capture_output=True, timeout=180)
        result.update({"command": command, "returncode": process.returncode,
                       "stdout": process.stdout, "stderr": process.stderr})
        if process.stdout:
            result["namespace_result"] = json.loads(process.stdout)
        if process.returncode == 0 and result.get("namespace_result", {}).get("status") == "passed":
            result["status"] = "passed"
    result["fixture_removed"] = not Path(fixture).exists()
    rendered = json.dumps(result, indent=2) + "\n"
    if args.result:
        require(args.result.is_absolute(), "result must use absolute path")
        args.result.write_text(rendered)
    print(rendered, end="", flush=True)
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        traceback.print_exc()
        sys.exit(1)
