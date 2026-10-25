"""Deterministic readiness checks without real services or credentials."""
import importlib.util
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock

spec = importlib.util.spec_from_file_location('ready', Path(sys.argv.pop(1)))
ready = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ready)


class ReadyTests(unittest.TestCase):
    def response(self, body=b'{"status":"ok"}', status=200):
        response = io.BytesIO(body)
        response.status = status
        return response

    def test_waits_through_connection_failure_until_healthy(self):
        opener = Mock(side_effect=[ConnectionRefusedError(), self.response()])
        sleep = Mock()
        ready.wait_ready(opener=opener, clock=Mock(side_effect=[0, 0, 1]), sleep=sleep)
        self.assertEqual(opener.call_count, 2)
        sleep.assert_called_once()

    def test_bad_response_fails_by_deadline_without_echoing_body(self):
        opener = Mock(return_value=self.response(b'private-fixture-canary'))
        with self.assertRaises(TimeoutError) as error:
            ready.wait_ready(timeout=2, opener=opener, clock=Mock(side_effect=[0, 0, 3]), sleep=Mock())
        self.assertNotIn('private-fixture-canary', str(error.exception))


if __name__ == '__main__':
    unittest.main()
