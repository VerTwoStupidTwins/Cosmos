"""Synthetic HTTP policy checks; no real model or external endpoint."""
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import sys
import threading
import unittest

CORE, SCRIPT = Path(sys.argv.pop(1)), Path(sys.argv.pop(1))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Upstream(BaseHTTPRequestHandler):
    calls = []

    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.calls.append((self.path, body))
        response = json.dumps({'data': [{'embedding': [0.0] * 768}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.end_headers()
        self.wfile.write(response)


class InferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.core = load('honcho_core', CORE)
        cls.module = load('honcho_inference', SCRIPT)
        cls.upstream = ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        cls.server = cls.core.Gateway(('127.0.0.1', 0), cls.upstream.server_address, timeout=3, endpoint='/v1/embeddings', model='embeddinggemma2', validator=cls.module.validate_embedding_request)
        cls.threads = []
        for server in [cls.upstream, cls.server]:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            cls.threads.append(thread)

    @classmethod
    def tearDownClass(cls):
        for server in [cls.server, cls.upstream]:
            server.shutdown()
            server.server_close()
        for thread in cls.threads:
            thread.join(timeout=5)

    def request(self, method, path, data=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        try:
            connection.request(method, path, body=json.dumps(data).encode() if data is not None else None, headers={'Content-Type': 'application/json'})
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def test_text_reaches_only_fixed_embeddings_route(self):
        status, _ = self.request('POST', '/v1/embeddings', {'model': 'embeddinggemma2', 'input': ['public fixture'], 'encoding_format': 'float'})
        self.assertEqual(status, 200)
        self.assertEqual(Upstream.calls[-1][0], '/v1/embeddings')

    def test_wrong_models_remote_media_token_arrays_and_overrides_refused(self):
        payloads = [
            {'model': 'other', 'input': 'fixture'},
            {'model': 'embeddinggemma2', 'input': {'image_url': 'https://outside.invalid/image'}},
            {'model': 'embeddinggemma2', 'input': [1, 2]},
            {'model': 'embeddinggemma2', 'input': 'fixture', 'model_path': '/private'},
            {'model': 'embeddinggemma2', 'input': 'fixture', 'dimensions': 1536},
            {'model': 'embeddinggemma2', 'input': 'fixture', 'encoding_format': 'base64'},
        ]
        count = len(Upstream.calls)
        for payload in payloads:
            with self.subTest(payload=payload):
                self.assertEqual(self.request('POST', '/v1/embeddings', payload)[0], 400)
        self.assertEqual(len(Upstream.calls), count)

    def test_only_embedding_model_advertised(self):
        status, body = self.request('GET', '/v1/models')
        self.assertEqual(status, 200)
        self.assertEqual([model['id'] for model in json.loads(body)['data']], ['embeddinggemma2'])

    def test_chat_management_and_url_passthrough_refused(self):
        for path in ['/v1/chat/completions', '/unload', '/upstream/embeddinggemma2/embeddings', '/v1/embeddings?url=https://outside.invalid']:
            self.assertEqual(self.request('POST', path, {})[0], 403)

    def test_large_batches_and_empty_inputs_refused(self):
        for value in ['', [], ['fixture'] * 9, 'x' * (256 * 1024 + 1)]:
            self.assertEqual(self.request('POST', '/v1/embeddings', {'model': 'embeddinggemma2', 'input': value})[0], 400)

    def test_original_chat_listener_does_not_gain_embedding_route(self):
        original = self.core.Gateway(('127.0.0.1', 0), self.upstream.server_address, timeout=3)
        thread = threading.Thread(target=original.serve_forever, daemon=True)
        thread.start()
        connection = http.client.HTTPConnection(*original.server_address, timeout=3)
        try:
            connection.request('POST', '/v1/embeddings', b'{}', {'Content-Type': 'application/json'})
            response = connection.getresponse()
            self.assertEqual(response.status, 403)
            response.read()
        finally:
            connection.close()
            original.shutdown()
            original.server_close()
            thread.join(timeout=5)


if __name__ == '__main__':
    unittest.main()
