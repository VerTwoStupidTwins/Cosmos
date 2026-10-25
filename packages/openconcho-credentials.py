"""Provision OpenConcho login and backend-only admin JWT, without rotating Honcho."""
import argparse
import base64
import fcntl
import hashlib
import hmac
import importlib.util
import json
import os
import re
import secrets
import stat
import subprocess


def provision(args):
    spec = importlib.util.spec_from_file_location('private_files', args.core)
    core = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(core)
    directory = os.open(args.state_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    lock = None
    try:
        info = os.fstat(directory)
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError('Unsafe state directory')
        lock = os.open('.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=directory)
        core.verify_file(lock)
        fcntl.flock(lock, fcntl.LOCK_EX)
        for name in ['login.json', 'container.env']:
            core.check_existing(directory, name)
        key_fd = os.open(args.signing_key, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            core.verify_file(key_fd)
            key = os.read(key_fd, 256)
        finally:
            os.close(key_fd)
        if not re.fullmatch(rb'[a-f0-9]{64}\n', key):
            raise ValueError('Invalid Honcho key')
        encode = lambda value: base64.urlsafe_b64encode(value).rstrip(b'=')
        message = encode(b'{"alg":"HS256","typ":"JWT"}') + b'.' + encode(b'{"t":"","ad":true}')
        token = (message + b'.' + encode(hmac.new(key.strip(), message, hashlib.sha256).digest())).decode()
        try:
            fd = os.open('login.json', os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
        except FileNotFoundError:
            if 'container.env' in os.listdir(directory):
                raise ValueError('Missing login with existing credentials; refusing rotation')
            password = secrets.token_urlsafe(32)
            hashed = subprocess.run([args.htpasswd, '-niB', 'viewer'], input=password + '\n', text=True, capture_output=True, check=True).stdout.strip()
            login = {'username': 'viewer', 'password': password, 'htpasswd': hashed}
            core.atomic_write(directory, 'login.json', (json.dumps(login) + '\n').encode())
        else:
            with os.fdopen(fd) as stream:
                core.verify_file(stream.fileno())
                login = json.load(stream)
        if (login.get('username') != 'viewer'
                or not re.fullmatch(r'[A-Za-z0-9_-]{43}', login.get('password', ''))
                or not re.fullmatch(r'viewer:\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}', login.get('htpasswd', ''))):
            raise ValueError('Invalid login; refusing rotation')
        # Verify the preserved login without plaintext passwords in argv or
        # a verification file on disk. Only this child inherits the hash memfd.
        hashed_fd = os.memfd_create('openconcho-htpasswd', flags=0)
        try:
            os.write(hashed_fd, (login['htpasswd'] + '\n').encode())
            subprocess.run([args.htpasswd, '-vi', f'/proc/self/fd/{hashed_fd}', 'viewer'], input=login['password'] + '\n', text=True, capture_output=True, check=True, pass_fds=(hashed_fd,), timeout=10)
        finally:
            os.close(hashed_fd)
        # Neither the signing key nor plaintext login password enters Podman.
        env = 'OPENCONCHO_API_TOKEN=' + token + '\nOPENCONCHO_HTPASSWD=' + login['htpasswd'] + '\n'
        core.atomic_write(directory, 'container.env', env.encode())
    finally:
        if lock is not None:
            os.close(lock)
        os.close(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state-dir', required=True)
    parser.add_argument('--signing-key', required=True)
    parser.add_argument('--core', required=True)
    parser.add_argument('--htpasswd', required=True)
    args = parser.parse_args()
    try:
        provision(args)
    except (OSError, ValueError, subprocess.SubprocessError):
        parser.exit(1, 'OpenConcho credentials refused unsafe or invalid state\n')


if __name__ == '__main__':
    main()
