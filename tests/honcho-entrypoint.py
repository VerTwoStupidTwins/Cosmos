"""Synthetic launcher checks; no database, models or credentials are contacted."""
import importlib.util
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import urllib.parse

SCRIPT = Path(sys.argv.pop(1))


class EntrypointTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('honcho_entrypoint', SCRIPT)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def environment(self):
        return {'HONCHO_DB_USER': 'honcho', 'HONCHO_DB_NAME': 'honcho', 'HONCHO_DB_SOCKET': '/run/postgresql', 'HONCHO_API_PORT': '8000'}

    def test_api_migrates_configures_empty_vectors_then_binds_loopback(self):
        with patch.dict(os.environ, self.environment(), clear=True), patch.object(self.module.subprocess, 'run') as run, patch.object(self.module.os, 'execv') as execute:
            self.module.main(['api'])
            calls = run.call_args_list
            self.assertEqual(len(calls), 2)
            self.assertEqual(calls[0].args[0][-1], 'scripts/provision_db.py')
            self.assertEqual(calls[1].args[0][-2:], ['scripts/configure_embeddings.py', '--yes'])
            self.assertTrue(all(call.kwargs['check'] for call in calls))
            args = execute.call_args.args[1]
            self.assertEqual(args[args.index('--host') + 1], '127.0.0.1')
            self.assertEqual(args[args.index('--port') + 1], '8000')
            self.assertIn('--no-access-log', args)
            parsed = urllib.parse.urlsplit(os.environ['DB_CONNECTION_URI'])
            self.assertEqual(parsed.scheme, 'postgresql+psycopg')
            self.assertEqual(parsed.username, 'honcho')
            self.assertIsNone(parsed.password)
            self.assertFalse(parsed.hostname)
            self.assertEqual(urllib.parse.parse_qs(parsed.query)['host'], ['/run/postgresql'])

    def test_worker_does_not_race_database_migrations(self):
        with patch.dict(os.environ, self.environment(), clear=True), patch.object(self.module.subprocess, 'run') as run, patch.object(self.module.os, 'execv') as execute:
            self.module.main(['worker'])
            run.assert_not_called()
            self.assertEqual(execute.call_args.args[1][-2:], ['-m', 'src.deriver'])

    def test_relative_socket_is_rejected(self):
        env = self.environment()
        env['HONCHO_DB_SOCKET'] = 'not/absolute'
        with patch.dict(os.environ, env, clear=True), self.assertRaises(ValueError):
            self.module.main(['worker'])


if __name__ == '__main__':
    unittest.main()
