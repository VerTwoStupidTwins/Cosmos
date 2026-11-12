"""A second image tool for the slower, higher-quality local model.

Hermes' image tool always uses the one configured model, so the agent could not
choose between a fast and a quality model per request. This tool calls the
quality model directly and returns its result the way the built-in tool does.
"""

import json
import logging
import urllib.error
import urllib.request

logger = logging.getLogger(__name__)

DEFAULT_BASE_URL = "http://127.0.0.1:8080/v1"
DEFAULT_MODEL = "image-quality"
# Covers loading the model, waiting for the helper's running requests, and a large image.
DEFAULT_TIMEOUT = 900
# Anima's recommended quality tags. The server adds the negative prompt itself.
QUALITY_TAGS = "masterpiece, best quality, score_7, "

SIZES = {"landscape": "1536x1024", "square": "1024x1024", "portrait": "1024x1536"}

SCHEMA = {
    "name": "image_generate_quality",
    "description": (
        "Generate an image from text with the slower, higher-quality local model. A square image "
        "takes about 2 minutes, and landscape or portrait about 3. Use image_generate for everyday "
        "images. Use this tool only when the user asks for higher quality or more detail, or says "
        "to take your time. The model draws anime and illustration styles, not photorealism, and "
        "it cannot edit images. Returns the result in the `image` field as an absolute file path; "
        "reference it in your response using the current platform's file-delivery convention."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "prompt": {
                "type": "string",
                "description": (
                    "The image description, in at least two detailed sentences. Start with one "
                    "safety tag that matches the request: safe, sensitive, nsfw or explicit. "
                    "Danbooru-style tags can be mixed in, and artist names need an @ in front."
                ),
            },
            "aspect_ratio": {
                "type": "string",
                "enum": list(SIZES),
                "description": (
                    "The aspect ratio of the image. 'square' is 1:1 and the fastest. 'landscape' "
                    "is wide and 'portrait' is tall, and both take longer."
                ),
                "default": "square",
            },
        },
        "required": ["prompt"],
    },
}


def _error(message, error_type, **fields):
    return json.dumps({"success": False, "error": message, "error_type": error_type, **fields})


def _generate(ctx, args):
    prompt = str(args.get("prompt") or "").strip()
    if not prompt:
        return _error("A prompt is required.", "invalid_request")
    aspect = str(args.get("aspect_ratio") or "square").strip().lower()
    if aspect not in SIZES:
        aspect = "square"

    # Hermes reserves global names such as "model", so these settings use names of their own.
    base_url = str(ctx.get_config("endpoint", DEFAULT_BASE_URL)).rstrip("/")
    model = str(ctx.get_config("image_model", DEFAULT_MODEL))
    timeout = float(ctx.get_config("request_timeout", DEFAULT_TIMEOUT))
    context = {"model": model, "prompt": prompt, "aspect_ratio": aspect}

    body = json.dumps(
        {"model": model, "prompt": QUALITY_TAGS + prompt, "size": SIZES[aspect], "n": 1}
    ).encode()
    request = urllib.request.Request(
        f"{base_url}/images/generations", data=body, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:500]
        return _error(f"Image server returned HTTP {exc.code}: {detail}", "api_error", **context)
    except Exception as exc:
        return _error(f"Image request failed: {exc}", "api_error", **context)

    data = payload.get("data") or []
    b64 = data[0].get("b64_json") if data else None
    if not b64:
        return _error("The image server returned no image.", "empty_response", **context)

    # Hermes' own helpers put the file where the built-in tool's images go and shape the result.
    from agent.image_gen_provider import save_b64_image, success_response

    try:
        path = save_b64_image(b64, prefix=f"local_{model}")
    except Exception as exc:
        return _error(f"Could not save the image: {exc}", "io_error", **context)

    return json.dumps(
        success_response(
            image=str(path),
            model=model,
            prompt=prompt,
            aspect_ratio=aspect,
            provider="llama-swap",
            extra={"size": SIZES[aspect]},
        )
    )


def register(ctx):
    def handler(args, **kwargs):
        try:
            return _generate(ctx, args)
        except Exception as exc:
            logger.exception("image_generate_quality failed")
            return _error(f"Unexpected error: {exc}", "provider_error")

    # Joining the built-in image toolset means the tool is enabled and disabled with it.
    ctx.register_tool(
        name="image_generate_quality",
        toolset="image_gen",
        schema=SCHEMA,
        handler=handler,
        description="Slower, higher-quality local image generation.",
        emoji="🎨",
    )
