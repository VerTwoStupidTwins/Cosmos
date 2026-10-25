"""Fixed-target, inference-only HTTP gateway for the restricted Hermes UID.

No caller-selected upstream, model management, URL fetching or request-body logs.
The UID-level firewall, not this listener alone, prevents direct upstream access.
"""
import argparse
import base64
import binascii
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading

MODEL = 'gemma4-balanced-q4'
MAX_BODY = 8 * 1024 * 1024
SAMPLING = {'temperature': 0.6, 'top_k': 64, 'top_p': 0.9, 'min_p': 0.05, 'repeat_penalty': 1.1}


def validate_request(data):
    if not isinstance(data, dict) or data.get('model') != MODEL:
        raise ValueError('Only the configured local model is permitted')
    if not isinstance(data.get('messages'), list) or not data['messages']:
        raise ValueError('A nonempty messages array is required')
    if not isinstance(data.get('stream', False), bool):
        raise ValueError('stream must be boolean')
    if any(key in data for key in ('chat_template', 'model_path', 'mmproj', 'lora', 'lora_path')):
        raise ValueError('Runtime model/template changes are not permitted')
    for key in ('max_tokens', 'max_completion_tokens', 'n_predict'):
        if key in data and (type(data[key]) is not int or not 1 <= data[key] <= 8192):
            raise ValueError('Output token limit must be between 1 and 8192')
    if 'n' in data and (type(data['n']) is not int or data['n'] != 1):
        raise ValueError('Only one completion per request is permitted')

    def check(value, depth=0):
        if depth > 48:
            raise ValueError('Request nesting exceeds policy')
        if isinstance(value, list):
            for item in value:
                check(item, depth + 1)
        elif isinstance(value, dict):
            # llama-server can fetch image URLs with its own network identity.
            # Do not let the diagnostic worker use inference as an egress proxy.
            for key, item in value.items():
                if key in ('video_url', 'audio_url', 'input_audio'):
                    raise ValueError('Only text and inline images are permitted')
                if key == 'image_url':
                    url = item.get('url') if isinstance(item, dict) else item
                    if not isinstance(url, str) or not url.startswith(('data:image/png;base64,', 'data:image/jpeg;base64,', 'data:image/webp;base64,', 'data:image/gif;base64,')):
                        raise ValueError('Images must be inline data, never remote or file URLs')
                    try:
                        base64.b64decode(url.split(',', 1)[1], validate=True)
                    except (binascii.Error, ValueError) as exc:
                        raise ValueError('Invalid inline image') from exc
                check(item, depth + 1)
    check(data['messages'])
    data = dict(data)
    data.update(SAMPLING)
    if 'max_tokens' not in data and 'max_completion_tokens' not in data:
        data['max_tokens'] = 8192
    return data


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON keys are not permitted')
        result[key] = value
    return result


class Gateway(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 8

    def __init__(self, address, upstream, timeout=1800, *, endpoint='/v1/chat/completions', model=MODEL, validator=validate_request):
        self.upstream = upstream
        self.upstream_timeout = timeout
        self.endpoint = endpoint
        self.model = model
        self.validator = validator
        self.capacity = threading.BoundedSemaphore(8)
        super().__init__(address, Handler)


class Handler(BaseHTTPRequestHandler):
    server_version = 'CosmosInference'
    sys_version = ''
    protocol_version = 'HTTP/1.0'

    def log_message(self, *_args):
        # Bodies, URL query strings and headers may contain diagnostic data.
        pass

    def setup(self):
        super().setup()
        self.connection.settimeout(30)

    def reply(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def do_GET(self):
        if self.path == '/health':
            self.reply(200, {'status': 'ok'})
        elif self.path == '/v1/models':
            # Do not expose the model-management service or unrelated models.
            self.reply(200, {'object': 'list', 'data': [{'id': self.server.model, 'object': 'model', 'owned_by': 'local', 'created': 0}]})
        else:
            self.reply(403, {'error': 'Only the inference interface is permitted'})

    def do_POST(self):
        if self.path != self.server.endpoint:
            self.reply(403, {'error': 'Only chat inference is permitted'})
            return
        if self.headers.get('Transfer-Encoding') or len(self.headers.get_all('Content-Length', [])) != 1:
            self.reply(400, {'error': 'Exactly one Content-Length is required; transfer encoding is refused'})
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= MAX_BODY:
                self.reply(413, {'error': 'Request body exceeds policy'})
                return
            raw = self.rfile.read(length)
            if len(raw) != length:
                raise ValueError('Incomplete request body')
            data = self.server.validator(json.loads(raw, object_pairs_hook=unique_object))
        except (ValueError, RecursionError, TimeoutError):
            self.reply(400, {'error': 'Request rejected by local inference policy'})
            return
        if not self.server.capacity.acquire(blocking=False):
            self.reply(429, {'error': 'Local inference request queue is full'})
            return
        upstream = http.client.HTTPConnection(*self.server.upstream, timeout=self.server.upstream_timeout)
        response_started = False
        try:
            upstream.request('POST', self.server.endpoint, body=json.dumps(data).encode(), headers={'Content-Type': 'application/json'})
            response = upstream.getresponse()
            self.send_response(response.status)
            self.send_header('Content-Type', response.getheader('Content-Type', 'application/json'))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Connection', 'close')
            self.end_headers()
            response_started = True
            while chunk := response.read1(16384):
                self.wfile.write(chunk)
                self.wfile.flush()
        except (OSError, http.client.HTTPException):
            if not response_started:
                self.reply(502, {'error': 'The local model service is unavailable'})
        finally:
            self.close_connection = True
            upstream.close()
            self.server.capacity.release()

    def do_PUT(self):
        self.reply(403, {'error': 'Operation not permitted'})

    do_DELETE = do_PUT
    do_PATCH = do_PUT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=18090)
    args = parser.parse_args()
    # The upstream is fixed in root-managed code, not supplied by the caller.
    Gateway(('127.0.0.1', args.port), ('127.0.0.1', 8081)).serve_forever()


if __name__ == '__main__':
    main()
