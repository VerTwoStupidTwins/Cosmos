"""Serves OpenAI image requests from ComfyUI, for llama-swap to manage like a model.

ComfyUI runs all the time in its container, but shares the B580 with the helper model. llama-swap starts
this adapter when an image is asked for, after stopping the helper, and stops it to give the card back.
Stopping tells ComfyUI to unload its models and free the card's memory.

A request draws one MOSS-Image picture per `n`. `"fast": true` uses the 8-step distillation LoRA (about
20 seconds); otherwise it uses the templates' 25-step settings (about 85 seconds).

Krita drives ComfyUI directly, through comfyui-gate, which sends each of its jobs here to /comfy/prompt. That
queues the job and answers with ComfyUI's reply straight away, but keeps the response open until the job ends,
so llama-swap counts it as running and won't hand the card back to the helper mid-job.
"""

import argparse
import base64
import json
import os
import random
import re
import signal
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# The image-fast plugin used to send stable-diffusion.cpp's settings in the prompt. They mean "fast".
SD_CPP_ARGS = re.compile(r"<sd_cpp_extra_args>.*?</sd_cpp_extra_args>", re.S)
# The template's negative prompt, without "nsfw": explicit images are allowed on this system.
NEGATIVE = "worst quality, bad anatomy, watermark, jpeg artifact"
MAX_PIXELS = 2048 * 2048


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--comfyui-url", required=True)
    p.add_argument("--diffusion-model", required=True)
    p.add_argument("--text-encoder", required=True)
    p.add_argument("--vae", required=True)
    p.add_argument("--fast-lora", required=True)
    p.add_argument("--timeout", type=float, default=900, help="Seconds one image may take, queueing included")
    return p.parse_args()


ARGS = None


def comfy(path, body=None, timeout=30):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(ARGS.comfyui_url + path, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        raw = response.read()
    return json.loads(raw) if raw[:1] in (b"{", b"[") else raw


def graph(prompt, width, height, fast):
    g = {
        "unet": {"class_type": "UNETLoader", "inputs": {"unet_name": ARGS.diffusion_model, "weight_dtype": "default"}},
        "clip": {"class_type": "CLIPLoader", "inputs": {"clip_name": ARGS.text_encoder, "type": "moss_image", "device": "default"}},
        "vae": {"class_type": "VAELoader", "inputs": {"vae_name": ARGS.vae}},
        "positive": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt, "clip": ["clip", 0]}},
        "negative": {"class_type": "CLIPTextEncode", "inputs": {"text": "" if fast else NEGATIVE, "clip": ["clip", 0]}},
        "latent": {"class_type": "EmptyFlux2LatentImage", "inputs": {"width": width, "height": height, "batch_size": 1}},
        "sample": {
            "class_type": "KSampler",
            "inputs": {
                "model": ["lora", 0] if fast else ["unet", 0],
                "positive": ["positive", 0],
                "negative": ["negative", 0],
                "latent_image": ["latent", 0],
                "seed": random.randint(0, 2**53),
                # The LoRA's own settings: 8 steps without CFG. Otherwise the MOSS-Image templates' settings.
                "steps": 8 if fast else 25,
                "cfg": 1.0 if fast else 2.5,
                "sampler_name": "euler" if fast else "er_sde",
                "scheduler": "simple",
                "denoise": 1.0,
            },
        },
        "decode": {"class_type": "VAEDecode", "inputs": {"samples": ["sample", 0], "vae": ["vae", 0]}},
        # A preview lands in ComfyUI's temp folder, which it empties itself, so served images aren't kept.
        "image": {"class_type": "PreviewImage", "inputs": {"images": ["decode", 0]}},
    }
    if fast:
        g["lora"] = {"class_type": "LoraLoaderModelOnly", "inputs": {"model": ["unet", 0], "lora_name": ARGS.fast_lora, "strength_model": 1.0}}
    return g


def draw(prompt, width, height, fast):
    """One picture as PNG bytes."""
    prompt_id = comfy("/prompt", {"prompt": graph(prompt, width, height, fast)})["prompt_id"]
    deadline = time.time() + ARGS.timeout
    while time.time() < deadline:
        time.sleep(0.5)
        history = comfy(f"/history/{prompt_id}")
        if prompt_id not in history:
            continue
        entry = history[prompt_id]
        status = entry.get("status", {})
        if status.get("status_str") == "error":
            errors = [m[1] for m in status.get("messages", []) if m[0] == "execution_error"]
            detail = errors[0].get("exception_message", "").strip() if errors else "unknown error"
            raise RuntimeError(f"ComfyUI failed: {detail}")
        images = entry.get("outputs", {}).get("image", {}).get("images", [])
        if images:
            im = images[0]
            query = urllib.parse.urlencode({"filename": im["filename"], "subfolder": im.get("subfolder", ""), "type": im.get("type", "temp")})
            return comfy(f"/view?{query}", timeout=60)
        if status.get("completed"):
            raise RuntimeError("ComfyUI finished without an image")
    # Stops the job so it doesn't hold the card after the caller has given up.
    try:
        comfy("/queue", {"delete": [prompt_id]})
        comfy("/interrupt", {"prompt_id": prompt_id})
    except Exception:
        pass
    raise TimeoutError(f"no image after {ARGS.timeout:.0f} seconds")


def size_of(value):
    try:
        width, height = (int(x) for x in str(value or "1024x1024").lower().split("x"))
    except ValueError:
        raise ValueError(f"size must look like 1024x1024, not {value!r}")
    # MOSS-Image needs multiples of 16.
    width, height = max(256, width // 16 * 16), max(256, height // 16 * 16)
    if width * height > MAX_PIXELS:
        raise ValueError(f"{width}x{height} is larger than MOSS-Image draws well")
    return width, height


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self.reply(200, {"status": "ok"})
        elif self.path == "/v1/models":
            self.reply(200, {"object": "list", "data": [{"id": "image", "object": "model"}]})
        else:
            self.reply(404, {"error": {"message": "not found"}})

    def do_POST(self):
        if self.path == "/comfy/prompt":
            self.queue_and_hold()
            return
        if self.path.rstrip("/") not in ("/v1/images/generations", "/images/generations"):
            self.reply(404, {"error": {"message": "not found"}})
            return
        started = time.time()
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
            raw = str(body.get("prompt") or "")
            fast = bool(body.get("fast")) or bool(SD_CPP_ARGS.search(raw))
            prompt = SD_CPP_ARGS.sub("", raw).strip()
            if not prompt:
                raise ValueError("prompt is empty")
            width, height = size_of(body.get("size"))
            n = max(1, min(int(body.get("n") or 1), 4))
        except (ValueError, TypeError, json.JSONDecodeError) as exc:
            self.reply(400, {"error": {"message": str(exc), "type": "invalid_request_error"}})
            return
        try:
            data = [{"b64_json": base64.b64encode(draw(prompt, width, height, fast)).decode()} for _ in range(n)]
        except Exception as exc:
            print(f"image failed: {exc}", file=sys.stderr, flush=True)
            self.reply(500, {"error": {"message": str(exc), "type": "server_error"}})
            return
        # Never logs the prompt.
        print(f"{n} {'fast' if fast else 'quality'} {width}x{height} image(s) in {time.time() - started:.1f}s", flush=True)
        self.reply(200, {"created": int(time.time()), "data": data})

    def queue_and_hold(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        request = urllib.request.Request(ARGS.comfyui_url + "/prompt", data=body, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                reply = response.read()
        except urllib.error.HTTPError as exc:
            # ComfyUI rejected the job, such as for a missing model. Krita shows its reply.
            data = exc.read()
            self.send_response(exc.code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        except Exception as exc:
            self.reply(502, {"error": {"message": f"ComfyUI isn't answering: {exc}"}})
            return
        prompt_id = json.loads(reply).get("prompt_id")
        # No length, so the body runs until the connection closes, and llama-swap passes the first line on at once.
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(reply.strip() + b"\n")
        self.wfile.flush()
        started = time.time()
        while prompt_id and time.time() - started < 3600:
            time.sleep(1)
            try:
                if prompt_id in comfy(f"/history/{prompt_id}"):
                    break
                queue = comfy("/queue")
                # Gone from the queue without a history entry: cancelled before it started.
                if not any(job[1] == prompt_id for job in queue.get("queue_running", []) + queue.get("queue_pending", [])):
                    break
            except Exception:
                pass
        self.close_connection = True

    def log_message(self, *args):
        pass


def wait_for_comfyui(limit=600):
    """ComfyUI may still be starting, or its image still building, when llama-swap starts this."""
    deadline = time.time() + limit
    while True:
        try:
            comfy("/system_stats", timeout=5)
            return
        except Exception:
            if time.time() > deadline:
                sys.exit("ComfyUI isn't answering")
            time.sleep(2)


def free_and_exit(*_):
    # Unloads every model and empties PyTorch's cache, so the helper gets the whole card back.
    try:
        comfy("/free", {"unload_models": True, "free_memory": True}, timeout=20)
    except Exception as exc:
        print(f"couldn't free ComfyUI's memory: {exc}", file=sys.stderr, flush=True)
    os._exit(0)


def main():
    global ARGS
    ARGS = parse_args()
    wait_for_comfyui()
    signal.signal(signal.SIGTERM, free_and_exit)
    signal.signal(signal.SIGINT, free_and_exit)
    server = ThreadingHTTPServer((ARGS.host, ARGS.port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"serving images from {ARGS.comfyui_url} on port {ARGS.port}", flush=True)
    signal.pause()


if __name__ == "__main__":
    main()
