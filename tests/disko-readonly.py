"""Reproduce read-only flake checking with an uncached Disko source expression.

Run as the unprivileged operator on Odin. Copies only the public pinned input;
never deletes store paths or changes the real flake lock, disks or services.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path.cwd())
    parser.add_argument('--scratch', type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() == 0:
        raise RuntimeError('Refusing host-root regression run')
    repo = args.repo.resolve()
    assert (repo / 'flake.nix').is_file()
    original_lock = (repo / 'flake.lock').read_bytes()
    args.scratch.mkdir(mode=0o700, parents=True, exist_ok=True)
    run = args.scratch / ('disko-readonly-' + secrets.token_hex(6))
    run.mkdir(mode=0o700)
    expr = '(builtins.getFlake ' + json.dumps('path:' + str(repo)) + ').inputs.disko.outPath'
    source = subprocess.check_output(['nix', 'eval', '--no-write-lock-file', '--impure', '--raw', '--expr', expr], text=True).strip()
    copied = run / 'disko'
    shutil.copytree(source, copied, symlinks=True)
    package = copied / 'package.nix'
    package.chmod(0o600)
    # Disko's payload fileset excludes package.nix. This harmless nonce changes
    # the generated expression's store hash, not the selected payload or logic.
    with package.open('a') as stream:
        stream.write('\n# Public cache-miss fixture ' + secrets.token_hex(16) + '\n')
    flags = ['--no-write-lock-file', '--override-input', 'disko', 'path:' + str(copied)]
    host_names = json.loads(subprocess.check_output(['nix', 'eval', *flags, '--json', '--apply', 'builtins.attrNames', 'path:' + str(repo) + '#nixosConfigurations'], text=True))
    for host in host_names:
        p = subprocess.run(['nix', 'eval', *flags, '--raw', 'path:' + str(repo) + '#nixosConfigurations.' + host + '.config.system.build.toplevel.drvPath'], text=True, capture_output=True)
        (run / (host + '.log')).write_text(p.stdout + p.stderr)
        if p.returncode:
            raise RuntimeError('Host priming failed; inspect ' + str(run / (host + '.log')))
    p = subprocess.run(['nix', 'flake', 'check', *flags, '--no-build', '--show-trace', 'path:' + str(repo)], text=True, capture_output=True)
    log = run / 'flake-check.log'
    log.write_text(p.stdout + p.stderr)
    assert (repo / 'flake.lock').read_bytes() == original_lock, 'Real flake lock changed'
    print(json.dumps({'hosts': host_names, 'readonly_flake_check_passed': p.returncode == 0, 'fresh_disko_expression': True, 'real_lock_modified': False, 'log': str(log)}))
    if p.returncode:
        print((p.stdout + p.stderr)[-3500:])
        raise SystemExit(p.returncode)


if __name__ == '__main__':
    main()
