"""Operator-only credential bootstrap: 1Password login plus one SOPS dotenv entry.

Run on an authorized editing client, never as the Hermes service. No password,
hash, signing secret, identity or provider output is printed or put in arguments.
SOPS_AGE_KEY_CMD must already name the verified Cosmos operator callback.
"""
import argparse
import base64
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile

TITLE = 'Odin Hermes Dashboard'
KEY = '["hermes_dashboard_env"]'


def hash_password(password):
    salt = secrets.token_bytes(16)
    derived = hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1, dklen=32)
    return 'scrypt$16384$8$1$' + base64.b64encode(salt).decode() + '$' + base64.b64encode(derived).decode()


def verify_password(password, encoded):
    try:
        scheme, n, r, p, salt, digest = encoded.split('$')
        if (scheme, n, r, p) != ('scrypt', '16384', '8', '1'):
            return False
        expected = base64.b64decode(digest, validate=True)
        actual = hashlib.scrypt(password.encode(), salt=base64.b64decode(salt, validate=True), n=16384, r=8, p=1, dklen=32)
        return hmac.compare_digest(actual, expected)
    except (ValueError, TypeError):
        return False


def invoke(argv, value=None):
    result = subprocess.run(argv, input=value, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    if result.returncode:
        raise RuntimeError('A credential-provider operation failed; details suppressed to protect secrets')
    return result.stdout


def fields(item):
    return {field.get('id'): field.get('value', '') for field in item.get('fields', [])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--secrets-file', type=Path, required=True)
    parser.add_argument('--sops', default='sops')
    parser.add_argument('--vault', default='Cosmos Runtime')
    args = parser.parse_args()
    if not os.environ.get('SOPS_AGE_KEY_CMD') or not os.environ.get('COSMOS_SOPS_OPERATOR_KEY_REF'):
        raise RuntimeError('Configure the authorized Cosmos SOPS operator callback first')
    target = str(args.secrets_file.resolve(strict=True))
    # Lock the stable directory inode, not the ciphertext inode SOPS replaces.
    # No persistent lockfile; a contender must fail before any provider call.
    lock = os.open(Path(target).parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another credential bootstrap is in progress') from None
        bootstrap(args, target)
    finally:
        os.close(lock)


def bootstrap(args, target):
    target = Path(target)
    original = target.read_bytes()
    # A failed extract cannot distinguish a missing key from decryption errors.
    # Inspect membership only after a successful full decrypt, kept in memory.
    document = json.loads(invoke([args.sops, '--decrypt', '--output-type', 'json', target]))
    if not isinstance(document, dict):
        raise RuntimeError('Decrypted secrets are not an object; no changes made')
    if 'hermes_dashboard_env' in document:
        raise RuntimeError('Dashboard credentials already exist; refusing an implicit rotation')
    del document
    if target.read_bytes() != original:
        raise RuntimeError('Encrypted secrets changed during bootstrap; no publication made')
    items = json.loads(invoke(['op', 'item', 'list', '--vault', args.vault, '--format=json']))
    matches = [item for item in items if item.get('title') == TITLE]
    if len(matches) > 1:
        raise RuntimeError('Dashboard login is ambiguous; resolve duplicate entries privately')
    if matches:
        item = json.loads(invoke(['op', 'item', 'get', matches[0]['id'], '--format=json']))
        values = fields(item)
        username, password = values.get('username'), values.get('password')
        if not username or not password:
            raise RuntimeError('Existing dashboard login is incomplete; no changes made')
    else:
        username, password = 'twins', secrets.token_urlsafe(32)
        template = {
            'title': TITLE, 'category': 'LOGIN',
            'fields': [
                {'id': 'username', 'type': 'STRING', 'purpose': 'USERNAME', 'value': username},
                {'id': 'password', 'type': 'CONCEALED', 'purpose': 'PASSWORD', 'value': password},
                {'id': 'notesPlain', 'type': 'STRING', 'value': 'NetBird-only Odin Hermes dashboard. Token signing key is held separately in Cosmos SOPS; no operator identity is stored in this login.'},
            ],
            'urls': [{'href': 'http://100.94.82.252:9119', 'primary': True}],
        }
        item = json.loads(invoke(['op', 'item', 'create', '--vault', args.vault, '--format=json'], json.dumps(template).encode()))
    # Verify the exact externally written item before encrypting service material.
    readback = json.loads(invoke(['op', 'item', 'get', item['id'], '--format=json']))
    values = fields(readback)
    if values.get('username') != username or not hmac.compare_digest(values.get('password', ''), password):
        raise RuntimeError('1Password login read-back did not match; no SOPS update made')
    encoded = hash_password(password)
    if not verify_password(password, encoded):
        raise RuntimeError('Password hash verification failed')
    env = '\n'.join([
        'HERMES_DASHBOARD_BASIC_AUTH_USERNAME=' + username,
        "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH='" + encoded + "'",
        'HERMES_DASHBOARD_BASIC_AUTH_SECRET=' + secrets.token_urlsafe(48),
        'HERMES_DASHBOARD_BASIC_AUTH_TTL_SECONDS=43200',
        '',
    ])
    # Only ciphertext touches disk. Verify the staged update before publishing.
    with tempfile.TemporaryDirectory(prefix='.hermes-bootstrap-', dir=target.parent) as staging:
        candidate = Path(staging) / target.name
        candidate.write_bytes(original)
        candidate.chmod(target.stat().st_mode & 0o777)
        invoke([args.sops, 'set', '--value-stdin', candidate, KEY], json.dumps(env).encode())
        actual = invoke([args.sops, '--decrypt', '--extract', KEY, candidate]).decode()
        if actual.rstrip('\n') != env.rstrip('\n'):
            raise RuntimeError('Encrypted credential read-back did not match')
        # Also detect writers that do not cooperate with the directory flock.
        if target.read_bytes() != original:
            raise RuntimeError('Encrypted secrets changed during bootstrap; no publication made')
        os.replace(candidate, target)
    print('Dashboard login saved and independently read back in 1Password: ' + TITLE)
    print('SOPS dashboard hash/signing key encrypted and privately verified; no plaintext password in the repository.')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, OSError, ValueError) as exc:
        # Provider stderr/stdout are deliberately not included in diagnostics.
        print('Credential bootstrap stopped: ' + str(exc) if isinstance(exc, RuntimeError) else 'Credential bootstrap stopped; provider details suppressed.')
        raise SystemExit(1)
