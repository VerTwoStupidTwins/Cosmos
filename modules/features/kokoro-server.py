"""An OpenAI-compatible speech endpoint for Kokoro.

Kokoro takes several seconds to load, so this server loads it once and keeps it in
memory. It reads the model and voices from a local directory and never downloads.
"""

import argparse
import io
import json
import os
import subprocess
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
import torch
from kokoro import KModel, KPipeline

SAMPLE_RATE = 24000
# Only names the voices in log messages. Every file comes from the local directory.
REPO_ID = "hexgrad/Kokoro-82M"
# The first letter of a voice's name is its accent: a for American, b for British.
ACCENTS = ("a", "b")

# Formats the OpenAI API offers, with the ffmpeg arguments that produce them from WAV.
ENCODERS = {
    "mp3": ("audio/mpeg", ["-f", "mp3"]),
    "opus": ("audio/ogg", ["-c:a", "libopus", "-b:a", "48k", "-f", "ogg"]),
    "aac": ("audio/aac", ["-f", "adts"]),
    "flac": ("audio/flac", ["-f", "flac"]),
}


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--default-voice", default="af_heart")
    parser.add_argument("--threads", type=int, default=8)
    return parser.parse_args()


class Speaker:
    def __init__(self, model_dir, default_voice):
        self.model_dir = model_dir
        self.default_voice = default_voice
        model = KModel(
            repo_id=REPO_ID,
            config=os.path.join(model_dir, "config.json"),
            model=os.path.join(model_dir, "kokoro-v1_0.pth"),
        ).eval()
        self.pipelines = {code: KPipeline(lang_code=code, repo_id=REPO_ID, model=model) for code in ACCENTS}
        # One request at a time, since each already uses every thread it was given.
        self.lock = threading.Lock()

    def voice_path(self, voice):
        name = os.path.basename(voice or self.default_voice)
        path = os.path.join(self.model_dir, "voices", f"{name}.pt")
        if not os.path.isfile(path):
            raise ValueError(f"Unknown voice {name!r}")
        return name, path

    def speak(self, text, voice=None, speed=1.0):
        name, path = self.voice_path(voice)
        pipeline = self.pipelines.get(name[0], self.pipelines["a"])
        with self.lock, torch.inference_mode():
            chunks = [audio.numpy() for _, _, audio in pipeline(text, voice=path, speed=speed) if audio is not None]
        if not chunks:
            raise ValueError("Nothing to say")
        return np.concatenate(chunks)


def encode(audio, fmt, ffmpeg):
    samples = (np.clip(audio, -1.0, 1.0) * 32767).astype("<i2").tobytes()
    if fmt == "pcm":
        return "audio/pcm", samples
    wav = io.BytesIO()
    with wave.open(wav, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(SAMPLE_RATE)
        out.writeframes(samples)
    if fmt == "wav":
        return "audio/wav", wav.getvalue()
    content_type, args = ENCODERS[fmt]
    result = subprocess.run(
        [ffmpeg, "-loglevel", "error", "-f", "wav", "-i", "pipe:0", *args, "pipe:1"],
        input=wav.getvalue(),
        capture_output=True,
        check=True,
    )
    return content_type, result.stdout


def make_handler(speaker, ffmpeg):
    class Handler(BaseHTTPRequestHandler):
        def send(self, status, content_type, body):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def send_error_json(self, status, message):
            self.send(status, "application/json", json.dumps({"error": {"message": message}}).encode())

        def do_GET(self):
            if self.path in ("/", "/health"):
                self.send(200, "text/plain", b"ok")
            elif self.path == "/v1/models":
                self.send(200, "application/json", json.dumps({"data": [{"id": "kokoro"}]}).encode())
            else:
                self.send_error_json(404, "Not found")

        def do_POST(self):
            if self.path != "/v1/audio/speech":
                return self.send_error_json(404, "Not found")
            try:
                request = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
                text = str(request.get("input") or "").strip()
                if not text:
                    return self.send_error_json(400, "input is required")
                fmt = str(request.get("response_format") or "mp3")
                if fmt not in ("wav", "pcm", *ENCODERS):
                    return self.send_error_json(400, f"Unsupported response_format {fmt!r}")
                speed = min(4.0, max(0.25, float(request.get("speed") or 1.0)))
                audio = speaker.speak(text, request.get("voice"), speed)
                content_type, body = encode(audio, fmt, ffmpeg)
            except ValueError as exc:
                return self.send_error_json(400, str(exc))
            except Exception as exc:
                self.log_error("speech failed: %r", exc)
                return self.send_error_json(500, "Speech generation failed")
            self.send(200, content_type, body)

    return Handler


def main():
    args = parse_args()
    torch.set_num_threads(args.threads)
    speaker = Speaker(args.model_dir, args.default_voice)
    # The first request would otherwise also pay for loading the text processing and a voice.
    speaker.speak("Ready.")
    server = ThreadingHTTPServer((args.host, args.port), make_handler(speaker, args.ffmpeg))
    server.serve_forever()


if __name__ == "__main__":
    main()
