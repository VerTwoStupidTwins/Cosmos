"""Public synthetic credentials only; never reads production Honcho state."""
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

SCRIPT, CORE, HTPASSWD = [Path(sys.argv.pop(1)) for _ in range(3)]


class CredentialsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'])
        self.root = Path(self.tmp.name)
        self.state = self.root / 'viewer'
        self.state.mkdir(mode=0o700)
        self.key = self.root / 'signing.key'
        self.key.write_text('a' * 64 + '\n')
        self.key.chmod(0o600)

    def tearDown(self):
        self.tmp.cleanup()

    def provision(self):
        return subprocess.run([sys.executable, str(SCRIPT), '--state-dir', str(self.state), '--signing-key', str(self.key), '--core', str(CORE), '--htpasswd', str(HTPASSWD)], capture_output=True, text=True)

    def test_refuses_public_state(self):
        self.state.chmod(0o755)
        self.assertNotEqual(self.provision().returncode, 0)
        self.assertFalse((self.state / 'login.json').exists())

    def test_refuses_signing_key_symlink_without_touching_target(self):
        target = self.root / 'original.key'
        self.key.rename(target)
        self.key.symlink_to(target)
        self.assertNotEqual(self.provision().returncode, 0)
        self.assertEqual(target.read_text(), 'a' * 64 + '\n')

    def test_refuses_unsafe_output_without_overwriting_target(self):
        target = self.root / 'canary'
        target.write_text('PUBLIC FIXTURE CANARY')
        (self.state / 'container.env').symlink_to(target)
        self.assertNotEqual(self.provision().returncode, 0)
        self.assertEqual(target.read_text(), 'PUBLIC FIXTURE CANARY')

    def test_refuses_missing_login_instead_of_rotating(self):
        self.assertEqual(self.provision().returncode, 0)
        previous = (self.state / 'container.env').read_bytes()
        (self.state / 'login.json').unlink()
        self.assertNotEqual(self.provision().returncode, 0)
        self.assertFalse((self.state / 'login.json').exists())
        self.assertEqual(previous, (self.state / 'container.env').read_bytes())

    def test_rejects_login_hash_mismatch_without_replacing_environment(self):
        self.assertEqual(self.provision().returncode, 0)
        original = (self.state / 'container.env').read_bytes()
        login = json.loads((self.state / 'login.json').read_text())
        login['password'] = 'b' * 43
        (self.state / 'login.json').write_text(json.dumps(login))
        result = self.provision()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(original, (self.state / 'container.env').read_bytes())
        self.assertNotIn(login['password'], result.stdout + result.stderr)

    def test_stable_private_login_and_admin_token_without_signing_key_delivery(self):
        first = self.provision()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout, '')
        login = (self.state / 'login.json').read_bytes()
        second = self.provision()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(login, (self.state / 'login.json').read_bytes())
        info = json.loads(login)
        self.assertEqual(info['username'], 'viewer')
        self.assertGreaterEqual(len(info['password']), 40)
        env = dict(line.split('=', 1) for line in (self.state / 'container.env').read_text().splitlines())
        self.assertEqual(set(env), {'OPENCONCHO_API_TOKEN', 'OPENCONCHO_HTPASSWD'})
        token = env['OPENCONCHO_API_TOKEN']
        header, payload, signature = token.split('.')
        decode = lambda s: base64.urlsafe_b64decode(s + '=' * (-len(s) % 4))
        self.assertEqual(json.loads(decode(payload)), {'t': '', 'ad': True})
        self.assertTrue(hmac.compare_digest(decode(signature), hmac.new(b'a' * 64, (header + '.' + payload).encode(), hashlib.sha256).digest()))
        self.assertNotIn('a' * 64, (self.state / 'container.env').read_text())
        self.assertNotIn(info['password'], (self.state / 'container.env').read_text())
        self.assertEqual(first.stdout + second.stdout, '')
        for name in ['login.json', 'container.env']:
            self.assertEqual(stat.S_IMODE((self.state / name).stat().st_mode), 0o600)
        htfile = self.root / 'htpasswd'
        htfile.write_text(env['OPENCONCHO_HTPASSWD'] + '\n')
        p = subprocess.run([str(HTPASSWD), '-vi', str(htfile), 'viewer'], input=info['password'] + '\n', capture_output=True, text=True)
        self.assertEqual(p.returncode, 0)


if __name__ == '__main__':
    unittest.main()
