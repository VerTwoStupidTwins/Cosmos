"""Exercise the pinned owner's startup call seam without launching a real owner."""
import ast
import asyncio
import os
from pathlib import Path
import sys
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
source = Path(os.environ['HERMES_TEST_SOURCE']) / 'gateway/run_runtime.py'
tree = ast.parse(source.read_text())
function = next(n for n in tree.body if isinstance(n, ast.AsyncFunctionDef) and n.name == 'start_gateway_runtime_api')
namespace = {'_authorities': lambda runner: []}
exec(compile(ast.Module(body=[function], type_ignores=[]), str(source), 'exec'), namespace)


class OwnerPortTests(unittest.TestCase):
    def invoke(self):
        self.calls = []
        async def start_api(runner, host='127.0.0.1', port=0):
            self.calls.append((host, port))
            return SimpleNamespace(api_origin=f'http://{host}:{port}')
        run_api = ModuleType('gateway.run_api')
        run_api.start_gateway_api = start_api
        authorities = ModuleType('gateway.session_authorities')
        authorities.owner_scope = None
        bot = ModuleType('gateway.session_bot')
        bot.recover_bot_deliveries = None
        modules = {'gateway.run_api': run_api, 'gateway.session_authorities': authorities, 'gateway.session_bot': bot}
        runner = SimpleNamespace(session_runtime_descriptor={})
        with patch.dict(sys.modules, modules):
            asyncio.run(namespace['start_gateway_runtime_api'](runner))
        return runner

    def test_configured_port_is_passed_to_loopback_listener(self):
        with patch.dict(os.environ, {'HERMES_LOCAL_OWNER_PORT': '18092'}):
            runner = self.invoke()
        self.assertEqual(self.calls, [('127.0.0.1', 18092)])
        self.assertEqual(runner.session_runtime_descriptor['api_origin'], 'http://127.0.0.1:18092')

    def test_unconfigured_behavior_is_unchanged(self):
        with patch.dict(os.environ):
            os.environ.pop('HERMES_LOCAL_OWNER_PORT', None)
            self.invoke()
        self.assertEqual(self.calls, [('127.0.0.1', 0)])

    def test_non_numeric_port_fails_closed(self):
        with patch.dict(os.environ, {'HERMES_LOCAL_OWNER_PORT': 'not-a-port'}):
            with self.assertRaises(ValueError):
                self.invoke()
        self.assertEqual(self.calls, [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
