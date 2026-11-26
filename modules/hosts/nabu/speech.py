"""OpenAI speech API in front of qwentts.cpp's tts-server.

tts-server answers only in WAV or raw PCM and forgets cloned voices when it stops. This starts it on a free local
port, registers every voice in the voices folder (<name>.spk and <name>.rvq from qwen-codec, <name>.txt with what the
reference clip says), and turns its WAV into the format a client asks for (Hermes asks for mp3 or opus) with ffmpeg.
A request for a voice it doesn't have gets the default one.

    speech.py --port PORT --voices DIR --voice NAME -- tts-server --model ... --codec ...
"""

import argparse
import base64
import http.client
import http.server
import json
import os
import pathlib
import signal
import socket
import subprocess
import sys
import threading
import time

# ffmpeg output arguments for each OpenAI response_format, and the content type it is served with.
FORMATS = {
    "mp3": (["-c:a", "libmp3lame", "-b:a", "96k", "-f", "mp3"], "audio/mpeg"),
    "opus": (["-c:a", "libopus", "-b:a", "48k", "-f", "ogg"], "audio/ogg"),
    "aac": (["-c:a", "aac", "-b:a", "96k", "-f", "adts"], "audio/aac"),
    "flac": (["-c:a", "flac", "-f", "flac"], "audio/flac"),
}


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def call(port, method, path, body=None, headers=None, timeout=600):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    conn.request(method, path, body=body, headers=headers or {})
    return conn, conn.getresponse()


def wait_ready(port, child):
    for _ in range(300):
        if child.poll() is not None:
            sys.exit(f"tts-server exited with {child.returncode}")
        try:
            conn, resp = call(port, "GET", "/v1/models", timeout=2)
            resp.read()
            conn.close()
            if resp.status == 200:
                return
        except OSError:
            pass
        time.sleep(1)
    sys.exit("tts-server did not come up")


def register_voices(port, folder):
    names = []
    for spk in sorted(pathlib.Path(folder).glob("*.spk")):
        name = spk.stem
        body = json.dumps({
            "name": name,
            "ref_text": spk.with_suffix(".txt").read_text().strip(),
            "spk_b64": base64.b64encode(spk.read_bytes()).decode(),
            "rvq_b64": base64.b64encode(spk.with_suffix(".rvq").read_bytes()).decode(),
        })
        conn, resp = call(port, "POST", "/v1/audio/voices", body, {"Content-Type": "application/json"})
        answer = resp.read()
        conn.close()
        if resp.status != 200:
            sys.exit(f"registering voice {name} failed: {resp.status} {answer[:200]!r}")
        names.append(name)
    return names


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--voices", required=True)
    parser.add_argument("--voice", required=True, help="the voice for requests that name one it doesn't have")
    parser.add_argument("server", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    server_cmd = args.server[1:] if args.server[:1] == ["--"] else args.server

    inner = free_port()
    child = subprocess.Popen(server_cmd + ["--host", "127.0.0.1", "--port", str(inner)])

    def stop(*_):
        child.terminate()
        try:
            child.wait(10)
        except subprocess.TimeoutExpired:
            child.kill()
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    wait_ready(inner, child)
    voices = register_voices(inner, args.voices)
    if args.voice not in voices:
        sys.exit(f"default voice {args.voice} not in {args.voices}")
    print(f"speech: tts-server on {inner}, voices {', '.join(voices)}", flush=True)

    # The adapter can't serve without tts-server; llama-swap starts both again on the next request.
    def watch():
        child.wait()
        print(f"speech: tts-server exited with {child.returncode}", flush=True)
        os._exit(1)

    threading.Thread(target=watch, daemon=True).start()

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def send_body(self, status, content_type, data):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def forward(self, body=None):
            headers = {k: v for k, v in self.headers.items() if k.lower() in ("content-type", "accept")}
            conn, resp = call(inner, self.command, self.path, body, headers)
            data = resp.read()
            conn.close()
            self.send_body(resp.status, resp.getheader("Content-Type", "application/json"), data)

        def do_GET(self):
            self.forward()

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            if self.path.split("?")[0] != "/v1/audio/speech":
                return self.forward(body)
            try:
                req = json.loads(body)
            except ValueError:
                return self.send_body(400, "application/json", b'{"error":"body is not JSON"}')
            fmt = req.get("response_format") or "mp3"
            if req.get("voice") not in voices:
                req["voice"] = args.voice
            # The Base model clones; style instructions belong to the VoiceDesign and CustomVoice models.
            req.pop("instructions", None)
            req.pop("speed", None)
            if fmt == "pcm":
                return self.stream_pcm(req)
            req["response_format"] = "wav"
            conn, resp = call(inner, "POST", "/v1/audio/speech", json.dumps(req), {"Content-Type": "application/json"})
            wav = resp.read()
            conn.close()
            if resp.status != 200:
                return self.send_body(resp.status, resp.getheader("Content-Type", "application/json"), wav)
            if fmt == "wav":
                return self.send_body(200, "audio/wav", wav)
            if fmt not in FORMATS:
                return self.send_body(400, "application/json",
                                      json.dumps({"error": f"response_format {fmt} not supported"}).encode())
            out_args, content_type = FORMATS[fmt]
            encoded = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", "pipe:0", *out_args, "pipe:1"],
                                     input=wav, capture_output=True)
            if encoded.returncode != 0:
                return self.send_body(500, "application/json",
                                      json.dumps({"error": encoded.stderr.decode()[-500:]}).encode())
            self.send_body(200, content_type, encoded.stdout)

        def stream_pcm(self, req):
            conn, resp = call(inner, "POST", "/v1/audio/speech", json.dumps(req), {"Content-Type": "application/json"})
            self.send_response(resp.status)
            self.send_header("Content-Type", resp.getheader("Content-Type", "audio/pcm"))
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            while chunk := resp.read1(16384):
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            conn.close()

        def log_message(self, fmt, *a):
            pass

    http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
