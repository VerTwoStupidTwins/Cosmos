"""Provision private local Honcho auth; never print keys or issue admin tokens."""
import argparse
import base64
import fcntl
import hashlib
import hmac
import json
import os
import re
import secrets
import stat


def verify_file(fd):
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600:
        raise ValueError('Unsafe credential file')


def check_existing(directory, name):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
    except FileNotFoundError:
        return
    try:
        verify_file(fd)
    finally:
        os.close(fd)


def atomic_write(directory, name, data):
    temporary = '.' + name + '.' + secrets.token_hex(8)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
        os.fsync(directory)
    finally:
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass


def workspace_token(key):
    encode = lambda value: base64.urlsafe_b64encode(value).rstrip(b'=')
    header = encode(b'{"alg":"HS256","typ":"JWT"}')
    payload = encode(b'{"t":"","w":"personal"}')
    message = header + b'.' + payload
    return (message + b'.' + encode(hmac.new(key.encode(), message, hashlib.sha256).digest())).decode()


def provision(path):
    directory = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    lock = None
    try:
        info = os.fstat(directory)
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError('Unsafe credential directory')
        lock = os.open('.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=directory)
        verify_file(lock)
        fcntl.flock(lock, fcntl.LOCK_EX)
        for name in ['signing.key', 'server.env', 'client.json']:
            check_existing(directory, name)
        try:
            key_fd = os.open('signing.key', os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
        except FileNotFoundError:
            if {'server.env', 'client.json'} & set(os.listdir(directory)):
                raise ValueError('Missing signing key with existing credentials; refusing rotation')
            atomic_write(directory, 'signing.key', (secrets.token_hex(32) + '\n').encode())
            key_fd = os.open('signing.key', os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
        try:
            verify_file(key_fd)
            key_data = os.read(key_fd, 256)
        finally:
            os.close(key_fd)
        if not re.fullmatch(rb'[a-f0-9]{64}\n', key_data):
            raise ValueError('Invalid existing signing key; refusing rotation')
        key = key_data.strip().decode('ascii')
        client = {
            'baseUrl': 'http://127.0.0.1:8000',
            'apiKey': workspace_token(key),
            'contextTokens': 1200,
            'contextCadence': 1,
            'dialecticCadence': 5,
            'dialecticDepth': 1,
            'dialecticReasoningLevel': 'low',
            'reasoningLevelCap': 'low',
            'recallMode': 'hybrid',
            'sessionStrategy': 'per-session',
            'writeFrequency': 'async',
            'pinUserPeer': True,
            'observationMode': 'directional',
            'hosts': {'hermes': {'enabled': True, 'aiPeer': 'hermes', 'peerName': 'twins', 'workspace': 'personal'}},
        }
        atomic_write(directory, 'server.env', ('AUTH_JWT_SECRET=' + key + '\n').encode())
        atomic_write(directory, 'client.json', (json.dumps(client) + '\n').encode())
    finally:
        if lock is not None:
            os.close(lock)
        os.close(directory)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state-dir', required=True)
    args = parser.parse_args(argv)
    try:
        provision(args.state_dir)
    except (OSError, ValueError):
        parser.exit(1, 'Honcho credential provisioning refused unsafe or invalid state\n')


if __name__ == '__main__':
    main()
