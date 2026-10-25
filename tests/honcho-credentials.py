"""Only synthetic keys in private fixture directories; no production secret access."""
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(sys.argv.pop(1))


class CredentialsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'])
        self.root = Path(self.tmp.name)
        self.state = self.root / 'state'
        self.state.mkdir(mode=0o700)

    def tearDown(self):
        self.tmp.cleanup()

    def run_setup(self):
        return subprocess.run([sys.executable, str(SCRIPT), '--state-dir', str(self.state)], capture_output=True, text=True)

    def test_stable_private_key_and_workspace_only_client(self):
        first = self.run_setup()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout, '')
        original = (self.state / 'signing.key').read_bytes()
        second = self.run_setup()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertTrue(original == (self.state / 'signing.key').read_bytes())
        for name in ['signing.key', 'server.env', 'client.json']:
            info = (self.state / name).stat()
            self.assertEqual(stat.S_IMODE(info.st_mode), 0o600)
            self.assertEqual(info.st_nlink, 1)
            self.assertEqual(info.st_uid, os.geteuid())
        client = json.loads((self.state / 'client.json').read_text())
        token = client['apiKey']
        header, payload, signature = token.split('.')
        decode = lambda value: base64.urlsafe_b64decode(value + '=' * (-len(value) % 4))
        claims = json.loads(decode(payload))
        self.assertEqual(claims['w'], 'personal')
        self.assertFalse(claims.get('ad', False))
        self.assertEqual(json.loads(decode(header))['alg'], 'HS256')
        expected = hmac.new(original.strip(), (header + '.' + payload).encode(), hashlib.sha256).digest()
        self.assertTrue(hmac.compare_digest(expected, decode(signature)))
        self.assertEqual(client['baseUrl'], 'http://127.0.0.1:8000')
        self.assertFalse(original.strip().decode() in json.dumps(client))
        self.assertFalse(token in first.stdout + first.stderr + second.stdout + second.stderr)

    def test_refuses_public_directory(self):
        self.state.chmod(0o755)
        self.assertNotEqual(self.run_setup().returncode, 0)
        self.assertFalse((self.state / 'server.env').exists())

    def test_refuses_symlink_state_directory(self):
        real = self.root / 'real'
        self.state.rename(real)
        self.state.symlink_to(real, target_is_directory=True)
        self.assertNotEqual(self.run_setup().returncode, 0)
        self.assertFalse((real / 'server.env').exists())

    def test_refuses_key_symlink_and_preserves_target(self):
        target = self.root / 'target'
        target.write_bytes(b'public canary')
        (self.state / 'signing.key').symlink_to(target)
        self.assertNotEqual(self.run_setup().returncode, 0)
        self.assertEqual(target.read_bytes(), b'public canary')

    def test_refuses_key_hardlink(self):
        self.assertEqual(self.run_setup().returncode, 0)
        os.link(self.state / 'signing.key', self.root / 'alias')
        self.assertNotEqual(self.run_setup().returncode, 0)

    def test_refuses_malformed_existing_key_without_rotation(self):
        self.assertEqual(self.run_setup().returncode, 0)
        (self.state / 'signing.key').write_bytes(b'not a key')
        p = self.run_setup()
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual((self.state / 'signing.key').read_bytes(), b'not a key')
        self.assertEqual(p.stdout, '')

    def test_refuses_missing_key_when_existing_outputs_would_rotate(self):
        self.assertEqual(self.run_setup().returncode, 0)
        client = (self.state / 'client.json').read_bytes()
        (self.state / 'signing.key').unlink()
        self.assertNotEqual(self.run_setup().returncode, 0)
        self.assertFalse((self.state / 'signing.key').exists())
        self.assertTrue(client == (self.state / 'client.json').read_bytes())

    def test_refuses_output_symlink_without_touching_target(self):
        target = self.root / 'target'
        target.write_bytes(b'public canary')
        (self.state / 'server.env').symlink_to(target)
        self.assertNotEqual(self.run_setup().returncode, 0)
        self.assertEqual(target.read_bytes(), b'public canary')


if __name__ == '__main__':
    unittest.main()
