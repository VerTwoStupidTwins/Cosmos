"""Synthetic loopback-only tests; never contact a model or cloud provider."""
import base64
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import threading
import unittest

PATH = Path(__file__).resolve().parents[1] / 'packages' / 'hermes-inference-gateway.py'
spec = importlib.util.spec_from_file_location('gateway', PATH)
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)

class FakeInference(BaseHTTPRequestHandler):
    calls = []
    def log_message(self, *_args):
        pass
    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.calls.append(payload)
        if payload.get('stream'):
            body = b'data: {"choices":[{"delta":{"content":"fixture"}}]}\n\ndata: [DONE]\n\n'
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
        else:
            body = json.dumps({'choices':[{'message':{'content':'fixture'}}]}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

class GatewayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream = ThreadingHTTPServer(('127.0.0.1',0), FakeInference)
        cls.frontend = gateway.Gateway(('127.0.0.1',0), cls.upstream.server_address, timeout=3)
        cls.threads = []
        for server in [cls.upstream,cls.frontend]:
            t=threading.Thread(target=server.serve_forever,daemon=True);t.start();cls.threads.append(t)
    @classmethod
    def tearDownClass(cls):
        for server in [cls.frontend,cls.upstream]:
            server.shutdown();server.server_close()
        for t in cls.threads:t.join(timeout=5)
    def payload(self):
        return {'model':gateway.MODEL,'messages':[{'role':'user','content':'Public synthetic fixture'}]}
    def request(self,method,path,data=None,raw=None):
        conn=http.client.HTTPConnection(*self.frontend.server_address,timeout=5)
        try:
            body=raw if raw is not None else json.dumps(data).encode() if data is not None else None
            conn.request(method,path,body=body,headers={'Content-Type':'application/json'})
            response=conn.getresponse();return response.status,response.read()
        finally:conn.close()
    def test_generation_alias_cannot_bypass_token_bound(self):
        data=self.payload();data['n_predict']=-1
        with self.assertRaises(ValueError):gateway.validate_request(data)
    def test_model_is_pinned(self):
        data=self.payload();data['model']='other-model'
        self.assertEqual(self.request('POST','/v1/chat/completions',data)[0],400)
    def test_management_and_passthrough_routes_denied(self):
        for method,path in [('POST','/unload'),('POST','/v1/completions'),('GET','/running'),('GET','/upstream/gemma4-balanced-q4/props'),('PUT','/v1/chat/completions')]:
            with self.subTest(path=path):self.assertEqual(self.request(method,path,self.payload())[0],403)
    def test_remote_and_file_images_denied(self):
        for url in ['https://outside.invalid/fixture','http://127.0.0.1/private','file:///etc/passwd']:
            data=self.payload();data['messages'][0]['content']=[{'type':'image_url','image_url':{'url':url}}]
            self.assertEqual(self.request('POST','/v1/chat/completions',data)[0],400)
    def test_inline_image_allowed(self):
        data=self.payload();data['messages'][0]['content']=[{'type':'image_url','image_url':{'url':'data:image/png;base64,'+base64.b64encode(b'public-fixture').decode()}}]
        self.assertEqual(gateway.validate_request(data)['model'],gateway.MODEL)
    def test_sampling_pinned(self):
        data=self.payload();data['temperature']=1.8
        result=gateway.validate_request(data)
        for key,value in gateway.SAMPLING.items():self.assertEqual(result[key],value)
    def test_token_bound(self):
        for count in [-1,0,8193,True]:
            data=self.payload();data['max_tokens']=count
            with self.assertRaises(ValueError):gateway.validate_request(data)
    def test_duplicate_json_keys_denied(self):
        self.assertEqual(self.request('POST','/v1/chat/completions',raw=b'{"model":"a","model":"b"}')[0],400)
    def test_json_and_streaming_reach_fixed_upstream(self):
        for stream in [False,True]:
            data=self.payload();data['stream']=stream
            code,body=self.request('POST','/v1/chat/completions',data)
            self.assertEqual(code,200)
            self.assertIn(b'[DONE]' if stream else b'fixture',body)
            self.assertEqual(FakeInference.calls[-1]['model'],gateway.MODEL)
    def test_only_selected_model_is_advertised(self):
        code,body=self.request('GET','/v1/models')
        self.assertEqual(code,200)
        self.assertEqual([m['id'] for m in json.loads(body)['data']],[gateway.MODEL])
    def test_upstream_failure_is_sanitized(self):
        server=gateway.Gateway(('127.0.0.1',0),('127.0.0.1',1),timeout=1)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        conn=http.client.HTTPConnection(*server.server_address,timeout=3)
        try:
            conn.request('POST','/v1/chat/completions',json.dumps(self.payload()),{'Content-Type':'application/json'})
            response=conn.getresponse();body=response.read()
            self.assertEqual(response.status,502)
            self.assertNotIn(b'Traceback',body)
        finally:
            conn.close();server.shutdown();server.server_close();thread.join(timeout=3)

if __name__=='__main__':unittest.main()
