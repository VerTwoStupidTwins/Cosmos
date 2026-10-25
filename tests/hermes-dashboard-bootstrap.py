"""Public synthetic fixtures; every credential-provider subprocess is replaced."""
import contextlib
import importlib.util
import io
import json
import multiprocessing
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SOURCE = Path(__file__).resolve().parents[1] / 'packages/hermes-dashboard-bootstrap.py'
spec = importlib.util.spec_from_file_location('bootstrap', SOURCE)
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)
PRIVATE = 'public-fixture-provider-output-never-release'


class FakeProviders:
    def __init__(self):
        self.calls = []
        self.document = {'bootstrap_validation': PRIVATE}
        self.decrypt_error = False
        self.env = None
        self.item = None

    def run(self, argv, **kwargs):
        self.calls.append((argv, kwargs.get('input')))
        output = b''
        status = 0
        if argv[0] == 'fixture-sops':
            if argv[1] == 'set':
                self.env = json.loads(kwargs['input'])
                Path(argv[-2]).write_bytes(b'public-updated-ciphertext')
            elif '--extract' in argv:
                if '["bootstrap_validation"]' in argv:
                    output = PRIVATE.encode()
                elif self.env is not None:
                    output = self.env.encode()
                else:
                    status = 1
            elif self.decrypt_error:
                status = 1
            else:
                output = json.dumps(self.document).encode()
        elif argv[:3] == ['op', 'item', 'list']:
            output = b'[]'
        elif argv[:3] == ['op', 'item', 'create']:
            self.item = json.loads(kwargs['input'])
            self.item['id'] = 'public-fixture-item-id'
            output = json.dumps(self.item).encode()
        elif argv[:3] == ['op', 'item', 'get']:
            output = json.dumps(self.item).encode()
        else:
            raise AssertionError('Unexpected synthetic provider call')
        if status:
            output = PRIVATE.encode()
        return subprocess.CompletedProcess(argv, status, output, PRIVATE.encode())

    def writes(self):
        return [argv for argv, _ in self.calls if argv[1:2] == ['set']]

    def creates(self):
        return [argv for argv, _ in self.calls if argv[:3] == ['op', 'item', 'create']]


class CredentialFormatTests(unittest.TestCase):
    def test_hash_matches_pinned_scrypt_format(self):
        encoded = bootstrap.hash_password('public-fixture-not-a-password')
        self.assertTrue(bootstrap.verify_password('public-fixture-not-a-password', encoded))
        self.assertFalse(bootstrap.verify_password('different-fixture', encoded))
        self.assertTrue(encoded.startswith('scrypt$16384$8$1$'))
        self.assertNotIn('public-fixture-not-a-password', encoded)


class BootstrapGuardTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='hermes-bootstrap-test-')
        self.addCleanup(self.directory.cleanup)
        self.target = Path(self.directory.name) / 'secrets.yaml'
        self.original = b'public-original-ciphertext'
        self.target.write_bytes(self.original)
        self.target.chmod(0o640)
        self.provider = FakeProviders()
        self.output = io.StringIO()
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(sys, 'argv', ['bootstrap', '--secrets-file', str(self.target), '--sops', 'fixture-sops']).start()
        mock.patch.dict(os.environ, {'SOPS_AGE_KEY_CMD': 'fixture-callback', 'COSMOS_SOPS_OPERATOR_KEY_REF': 'fixture-reference'}).start()
        mock.patch.object(bootstrap.subprocess, 'run', side_effect=self.provider.run).start()
        mock.patch.object(bootstrap.secrets, 'token_urlsafe', side_effect=lambda n: 'public-token-' + str(n)).start()

    def invoke(self):
        with contextlib.redirect_stdout(self.output), contextlib.redirect_stderr(self.output):
            bootstrap.main()

    def assert_untouched(self):
        self.assertEqual(self.target.read_bytes(), self.original)
        self.assertEqual(self.provider.writes(), [])
        self.assertEqual(self.provider.creates(), [])
        self.assertNotIn(PRIVATE, self.output.getvalue())

    def test_decryption_lookup_failure_is_not_absence(self):
        self.provider.decrypt_error = True
        with self.assertRaises(RuntimeError) as caught:
            self.invoke()
        self.assertNotIn(PRIVATE, str(caught.exception))
        self.assert_untouched()

    def test_existing_key_is_refused_even_when_empty_or_null(self):
        for value in (None, '', False, PRIVATE):
            with self.subTest(value_type=type(value).__name__):
                self.provider.document['hermes_dashboard_env'] = value
                with self.assertRaisesRegex(RuntimeError, 'implicit rotation'):
                    self.invoke()
                self.assert_untouched()

    def test_invalid_decrypted_document_is_not_absence(self):
        for payload in (PRIVATE.encode(), b'null', b'[]', b'"public-fixture"'):
            with self.subTest(payload_type=payload[:1]):
                def provider(argv, **kwargs):
                    result = self.provider.run(argv, **kwargs)
                    if '--output-type' in argv:
                        return subprocess.CompletedProcess(argv, 0, payload, b'')
                    return result

                with mock.patch.object(bootstrap.subprocess, 'run', side_effect=provider):
                    with self.assertRaises((RuntimeError, ValueError)):
                        self.invoke()
                self.assert_untouched()

    def test_provider_lookup_errors_are_private_and_never_write(self):
        for operation in ('decrypt', 'vault-list', 'timeout', 'os-error', 'invalid-json'):
            with self.subTest(operation=operation):
                self.provider.calls.clear()
                self.output = io.StringIO()

                def provider(argv, **kwargs):
                    result = self.provider.run(argv, **kwargs)
                    decrypt = '--output-type' in argv
                    if decrypt and operation == 'timeout':
                        raise subprocess.TimeoutExpired(argv, 120, output=PRIVATE, stderr=PRIVATE)
                    if decrypt and operation == 'os-error':
                        raise OSError(PRIVATE)
                    if decrypt and operation == 'invalid-json':
                        return subprocess.CompletedProcess(argv, 0, PRIVATE.encode(), PRIVATE.encode())
                    if (decrypt and operation == 'decrypt') or (argv[:3] == ['op', 'item', 'list'] and operation == 'vault-list'):
                        return subprocess.CompletedProcess(argv, 1, PRIVATE.encode(), PRIVATE.encode())
                    return result

                with mock.patch.object(bootstrap.subprocess, 'run', side_effect=provider):
                    with contextlib.redirect_stdout(self.output), contextlib.redirect_stderr(self.output):
                        with self.assertRaises(SystemExit) as caught:
                            runpy.run_path(str(SOURCE), run_name='__main__')
                self.assertEqual(caught.exception.code, 1)
                self.assertIn('Credential bootstrap stopped', self.output.getvalue())
                self.assert_untouched()

    def test_absent_key_publishes_verified_ciphertext_without_secret_arguments(self):
        def provider(argv, **kwargs):
            if argv[1:2] == ['set']:
                candidate = Path(argv[-2])
                self.assertNotEqual(candidate, self.target)
                self.assertEqual(candidate.read_bytes(), self.original)
                self.assertEqual(self.target.read_bytes(), self.original)
            return self.provider.run(argv, **kwargs)

        with mock.patch.object(bootstrap.subprocess, 'run', side_effect=provider):
            self.invoke()
        self.assertEqual(self.target.read_bytes(), b'public-updated-ciphertext')
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o640)
        self.assertEqual(len(self.provider.writes()), 1)
        self.assertEqual(len(self.provider.creates()), 1)
        self.assertEqual(list(self.target.parent.iterdir()), [self.target])
        self.assertIn('privately verified', self.output.getvalue())
        arguments = '\n'.join(os.fspath(arg) for argv, _ in self.provider.calls for arg in argv)
        encoded = next(line.split('=', 1)[1].strip("'") for line in self.provider.env.splitlines() if 'PASSWORD_HASH=' in line)
        self.assertTrue(bootstrap.verify_password('public-token-32', encoded))
        for value in (PRIVATE, 'public-token-32', 'public-token-48', encoded, self.provider.env):
            self.assertNotIn(value, arguments)
            self.assertNotIn(value, self.output.getvalue())

    def test_staged_readback_error_never_publishes(self):
        for response in (subprocess.CompletedProcess([], 1, PRIVATE.encode(), PRIVATE.encode()), subprocess.CompletedProcess([], 0, PRIVATE.encode(), b'')):
            with self.subTest(status=response.returncode):
                self.provider = FakeProviders()

                def provider(argv, **kwargs):
                    result = self.provider.run(argv, **kwargs)
                    return response if '--extract' in argv else result

                with mock.patch.object(bootstrap.subprocess, 'run', side_effect=provider):
                    with self.assertRaises(RuntimeError) as caught:
                        self.invoke()
                self.assertNotIn(PRIVATE, str(caught.exception))
                self.assertNotIn(PRIVATE, self.output.getvalue())
                self.assertEqual(self.target.read_bytes(), self.original)
                self.assertEqual(list(self.target.parent.iterdir()), [self.target])

    def test_ciphertext_change_during_lookup_refuses_provider_writes(self):
        changed = b'public-intervening-ciphertext'

        def provider(argv, **kwargs):
            result = self.provider.run(argv, **kwargs)
            if '--output-type' in argv:
                self.target.write_bytes(changed)
            return result

        with mock.patch.object(bootstrap.subprocess, 'run', side_effect=provider):
            with self.assertRaisesRegex(RuntimeError, 'changed'):
                self.invoke()
        self.assertEqual(self.target.read_bytes(), changed)
        self.assertEqual(self.provider.writes(), [])
        self.assertEqual(self.provider.creates(), [])

    def test_intervening_ciphertext_change_is_not_overwritten(self):
        for atomic in (False, True):
            with self.subTest(atomic=atomic):
                self.target.write_bytes(self.original)
                self.provider = FakeProviders()
                changed = b'public-intervening-ciphertext'

                def provider(argv, **kwargs):
                    result = self.provider.run(argv, **kwargs)
                    if '--extract' in argv and bootstrap.KEY in argv:
                        if atomic:
                            other = self.target.with_suffix('.replacement')
                            other.write_bytes(changed)
                            os.replace(other, self.target)
                        else:
                            self.target.write_bytes(changed)
                    return result

                with mock.patch.object(bootstrap.subprocess, 'run', side_effect=provider):
                    with self.assertRaisesRegex(RuntimeError, 'changed'):
                        self.invoke()
                self.assertEqual(self.target.read_bytes(), changed)
                self.assertEqual(len(self.provider.writes()), 1)
                self.assertNotEqual(Path(self.provider.writes()[0][-2]), self.target)
                self.assertEqual(list(self.target.parent.iterdir()), [self.target])

    def test_concurrent_helper_refused_before_and_after_atomic_replacement(self):
        context = multiprocessing.get_context('fork')
        staged, publish, published, finish = [context.Event() for _ in range(4)]
        real_replace = os.replace

        def worker():
            def provider(argv, **kwargs):
                result = self.provider.run(argv, **kwargs)
                if argv[1:2] == ['set']:
                    staged.set()
                    if not publish.wait(10):
                        raise RuntimeError('Synthetic publication gate timed out')
                return result

            def replace(source, target):
                real_replace(source, target)
                published.set()
                if not finish.wait(10):
                    raise RuntimeError('Synthetic completion gate timed out')

            with mock.patch.object(bootstrap.subprocess, 'run', side_effect=provider), mock.patch.object(bootstrap.os, 'replace', side_effect=replace):
                self.invoke()

        process = context.Process(target=worker)
        process.start()
        try:
            self.assertTrue(staged.wait(10), 'First helper did not reach its staged write')
            with self.assertRaisesRegex(RuntimeError, 'another|progress|locked'):
                self.invoke()
            self.assert_untouched()
            publish.set()
            self.assertTrue(published.wait(10), 'First helper did not publish atomically')
            with self.assertRaisesRegex(RuntimeError, 'another|progress|locked'):
                self.invoke()
            self.assertEqual(self.provider.calls, [], 'Contender reached a credential provider')
        finally:
            publish.set()
            finish.set()
            process.join(10)
            if process.is_alive():
                process.terminate()
                process.join(10)
        self.assertEqual(process.exitcode, 0)
        self.assertEqual(self.target.read_bytes(), b'public-updated-ciphertext')


if __name__ == '__main__':
    unittest.main()
