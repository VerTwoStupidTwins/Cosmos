"""Exercise the pinned owner's startup call seam without launching a real owner."""
import ast
import asyncio
import logging
import os
from pathlib import Path
import sys
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import AsyncMock, Mock, patch

sys.dont_write_bytecode = True
source = Path(os.environ['HERMES_TEST_SOURCE']) / 'gateway/run_runtime.py'
tree = ast.parse(source.read_text())
function = next(n for n in tree.body if isinstance(n, ast.AsyncFunctionDef) and n.name == 'start_gateway_runtime_api')
namespace = {'logger': logging.getLogger(__name__)}
exec(compile(ast.Module(body=[function], type_ignores=[]), str(source), 'exec'), namespace)


class BrowserCredentialError(OSError):
    pass


class OwnerPortTests(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(os.environ)
        environment.start()
        self.addCleanup(environment.stop)
        os.environ.pop('HERMES_LOCAL_OWNER_PORT', None)
        self.calls = []
        self.webapp = SimpleNamespace(public_url='https://webapp.example')
        self.home = Path('/unused-owner-port-fixture')
        self.register = Mock()
        self.rotate = Mock()
        self.recover = AsyncMock()
        self.authorities = [object(), object()]
        self.addCleanup(patch.stopall)
        patch.dict(namespace, {
            '_authorities': lambda runner: self.authorities,
            '_recover_profile_bot_mailbox': self.recover,
            'logger': Mock(),
        }).start()

    def invoke(self, *, webapp=None, unusable=None, failures=(), rotate_error=None):
        self.register.reset_mock()
        self.recover.reset_mock()
        async def start_api(runner, **kwargs):
            self.calls.append(kwargs)
            index = len(self.calls) - 1
            if index < len(failures) and failures[index] is not None:
                raise failures[index]
            host = kwargs.get('host', '127.0.0.1')
            port = kwargs.get('port', 0)
            return SimpleNamespace(api_origin=f'http://{host}:{port}')
        gateway = ModuleType('gateway')
        run_api = ModuleType('gateway.run_api')
        run_api.start_gateway_api = start_api
        gateway.run_api = run_api
        listener = ModuleType('gateway.webapp_listener')
        listener.STARTING = {'state': 'starting', 'url': None, 'reason': None}
        listener.BrowserCredentialError = BrowserCredentialError
        listener.browser_session_token = self.rotate
        self.rotate.side_effect = rotate_error
        listener.dial_origin = lambda host, port: f'http://127.0.0.1:{port}'
        listener.listener_plan = lambda home: ('0.0.0.0', 9137, webapp, unusable)
        listener.register_control_verbs = self.register
        constants = ModuleType('hermes_constants')
        constants.get_hermes_home = lambda: self.home
        modules = {'gateway': gateway, 'gateway.run_api': run_api,
                   'gateway.webapp_listener': listener, 'hermes_constants': constants}
        self.runner = SimpleNamespace(session_runtime_descriptor={})
        with patch.dict(sys.modules, modules):
            asyncio.run(namespace['start_gateway_runtime_api'](self.runner))
        self.register.assert_called_once_with(self.runner, self.home)
        self.assertEqual(self.recover.await_args_list,
                         [unittest.mock.call(self.runner, authority) for authority in self.authorities])
        self.assertEqual(self.runner.session_runtime_descriptor['api_origin'], self.runner.session_api.api_origin)
        return self.runner

    def test_configured_port_is_passed_to_loopback_listener(self):
        os.environ['HERMES_LOCAL_OWNER_PORT'] = '18092'
        runner = self.invoke()
        self.assertEqual(self.calls, [{'host': '127.0.0.1', 'port': 18092}])
        self.assertEqual(runner.session_runtime_descriptor['api_origin'], 'http://127.0.0.1:18092')
        self.assertEqual(runner.webapp_status, {'state': 'off', 'url': None, 'reason': None})
        self.rotate.assert_not_called()

    def test_unconfigured_behavior_is_unchanged(self):
        self.invoke()
        self.assertEqual(self.calls, [{}])

    def test_malformed_port_fails_closed_before_any_listener(self):
        for value in ('not-a-port', '', '0', '-1', '65536', '1.5'):
            for webapp in (None, self.webapp):
                with self.subTest(port=value, webapp=webapp is not None):
                    self.calls = []
                    os.environ['HERMES_LOCAL_OWNER_PORT'] = value
                    with self.assertRaises(ValueError):
                        self.invoke(webapp=webapp)
                    self.assertEqual(self.calls, [])
        self.rotate.assert_not_called()
        self.recover.assert_not_awaited()

    def test_fixed_port_bind_failure_does_not_retry_ephemeral(self):
        os.environ['HERMES_LOCAL_OWNER_PORT'] = '18092'
        with self.assertRaises(OSError):
            self.invoke(failures=(OSError('private port taken'),))
        self.assertEqual(self.calls, [{'host': '127.0.0.1', 'port': 18092}])
        self.recover.assert_not_awaited()

    def test_webapp_success_preserves_configured_listener(self):
        for port in (None, '18092'):
            with self.subTest(owner_port=port):
                if port is not None:
                    os.environ['HERMES_LOCAL_OWNER_PORT'] = port
                self.calls = []
                self.register.reset_mock()
                self.recover.reset_mock()
                runner = self.invoke(webapp=self.webapp)
                self.assertEqual(self.calls, [{'host': '0.0.0.0', 'port': 9137, 'webapp': self.webapp}])
                self.assertEqual(runner.webapp_status,
                                 {'state': 'serving', 'url': 'http://127.0.0.1:9137', 'reason': None})
        self.rotate.assert_not_called()

    def test_unusable_webapp_uses_fixed_private_listener(self):
        os.environ['HERMES_LOCAL_OWNER_PORT'] = '18092'
        runner = self.invoke(unusable='invalid Webapp configuration')
        self.assertEqual(self.calls, [{'host': '127.0.0.1', 'port': 18092}])
        self.assertEqual(runner.webapp_status,
                         {'state': 'unavailable', 'url': None, 'reason': 'invalid Webapp configuration'})

    def test_webapp_failure_falls_back_to_fixed_loopback_port(self):
        os.environ['HERMES_LOCAL_OWNER_PORT'] = '18092'
        for failure in (OSError('address in use'), SystemExit('sign-in required'),
                        BrowserCredentialError('credential not storable'),
                        OSError(13, 'permission denied', '/fixture/browser-token')):
            with self.subTest(error=type(failure).__name__):
                self.calls = []
                self.register.reset_mock()
                self.recover.reset_mock()
                self.rotate.reset_mock()
                runner = self.invoke(webapp=self.webapp, failures=(failure,))
                self.assertEqual(self.calls, [
                    {'host': '0.0.0.0', 'port': 9137, 'webapp': self.webapp},
                    {'host': '127.0.0.1', 'port': 18092},
                ])
                self.assertEqual(runner.webapp_status['state'], 'unavailable')
                self.assertIsNone(runner.webapp_status['url'])
                self.assertTrue(runner.webapp_status['reason'])
                self.assertEqual(runner.session_runtime_descriptor['api_origin'], 'http://127.0.0.1:18092')
                self.rotate.assert_called_once_with(self.home, rotate=True)

    def test_webapp_fallback_without_env_is_unchanged(self):
        runner = self.invoke(webapp=self.webapp, failures=(OSError('address in use'),))
        self.assertEqual(self.calls, [
            {'host': '0.0.0.0', 'port': 9137, 'webapp': self.webapp}, {},
        ])
        self.assertEqual(runner.webapp_status['state'], 'unavailable')
        self.rotate.assert_called_once_with(self.home, rotate=True)

    def test_failed_credential_rotation_still_uses_fixed_fallback(self):
        os.environ['HERMES_LOCAL_OWNER_PORT'] = '18092'
        self.invoke(webapp=self.webapp, failures=(OSError('address in use'),),
                    rotate_error=OSError('read-only credential'))
        self.assertEqual(self.calls[-1], {'host': '127.0.0.1', 'port': 18092})
        self.rotate.assert_called_once_with(self.home, rotate=True)

    def test_failed_fixed_fallback_does_not_retry_ephemeral(self):
        os.environ['HERMES_LOCAL_OWNER_PORT'] = '18092'
        with self.assertRaisesRegex(OSError, 'private port taken'):
            self.invoke(webapp=self.webapp,
                        failures=(OSError('Webapp port taken'), OSError('private port taken')))
        self.assertEqual(self.calls, [
            {'host': '0.0.0.0', 'port': 9137, 'webapp': self.webapp},
            {'host': '127.0.0.1', 'port': 18092},
        ])
        self.recover.assert_not_awaited()


if __name__ == '__main__':
    unittest.main(verbosity=2)
