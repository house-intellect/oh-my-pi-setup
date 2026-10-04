#!/usr/bin/env python3
"""
Standalone Vision CLI & Client Library for OpenAI-compatible / FastAPI endpoints.
Formats images into base64 data URIs inside the content array:
{
  "role": "user",
  "content": [
    {"type": "text", "text": "..."},
    {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,..."}}
  ]
}
"""

import os
import sys
import json
import base64
import mimetypes
import argparse
from pathlib import Path
from typing import List, Union, Optional, Dict, Any

DEFAULT_API_BASE = os.environ.get("OPENAI_BASE_URL", os.environ.get("API_BASE", "http://127.0.0.1:8000/v1")).rstrip("/")
DEFAULT_MODEL = os.environ.get("VISION_MODEL", os.environ.get("MODEL", "gemini-flash"))

# Ensure MIME types are known
mimetypes.init()
mimetypes.add_type("image/webp", ".webp")
mimetypes.add_type("image/jpeg", ".jpg")
mimetypes.add_type("image/jpeg", ".jpeg")
mimetypes.add_type("image/png", ".png")
mimetypes.add_type("image/gif", ".gif")
mimetypes.add_type("image/bmp", ".bmp")


def detect_mime_type(data: bytes, fallback_path: Optional[Union[str, Path]] = None) -> str:
    """Detect MIME type from file header bytes, with extension fallback."""
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if data.startswith(b"GIF87a") or data.startswith(b"GIF89a"):
        return "image/gif"
    if data.startswith(b"RIFF") and len(data) >= 12 and data[8:12] == b"WEBP":
        return "image/webp"
    if data.startswith(b"BM"):
        return "image/bmp"

    if fallback_path:
        guessed, _ = mimetypes.guess_type(str(fallback_path))
        if guessed and guessed.startswith("image/"):
            return guessed

    return "image/jpeg"


def encode_image_data_uri(image_path_or_url: Union[str, Path]) -> str:
    """
    Converts a local image path, data URI, or URL into an OpenAI-compatible data URI.
    Returns: 'data:<mime>;base64,<encoded_data>'
    """
    path_str = str(image_path_or_url).strip()

    # Already a data URI
    if path_str.startswith("data:image/"):
        return path_str

    # HTTP / HTTPS URL
    if path_str.startswith("http://") or path_str.startswith("https://"):
        import urllib.request
        req = urllib.request.Request(path_str, headers={"User-Agent": "vision-tool/1.0"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = resp.read()
            mime = resp.headers.get_content_type() or detect_mime_type(data, path_str)
            b64_str = base64.b64encode(data).decode("ascii")
            return f"data:{mime};base64,{b64_str}"

    # Local file path
    resolved_path = Path(os.path.expanduser(path_str)).resolve()
    if not resolved_path.exists():
        raise FileNotFoundError(f"Image file not found: {resolved_path}")

    with open(resolved_path, "rb") as f:
        data = f.read()

    mime = detect_mime_type(data, resolved_path)
    b64_str = base64.b64encode(data).decode("ascii")
    return f"data:{mime};base64,{b64_str}"


def build_vision_payload(
    image_inputs: List[Union[str, Path]],
    prompt: str,
    model: str = DEFAULT_MODEL,
    detail: str = "auto",
    stream: bool = False,
    system_prompt: Optional[str] = None
) -> Dict[str, Any]:
    """
    Builds an OpenAI-compatible / FastAPI JSON payload containing image_url items.
    """
    content: List[Dict[str, Any]] = [
        {"type": "text", "text": prompt}
    ]

    for img_input in image_inputs:
        data_uri = encode_image_data_uri(img_input)
        img_item: Dict[str, Any] = {
            "type": "image_url",
            "image_url": {
                "url": data_uri,
                "detail": detail
            }
        }
        content.append(img_item)

    messages: List[Dict[str, Any]] = []
    if system_prompt:
        messages.append({"role": "system", "content": system_prompt})

    messages.append({
        "role": "user",
        "content": content
    })

    payload: Dict[str, Any] = {
        "model": model,
        "messages": messages,
        "stream": stream
    }
    return payload


def query_vision_model(
    image_inputs: Union[str, Path, List[Union[str, Path]]],
    prompt: str = "Describe this image in detail and answer any questions presented.",
    model: str = DEFAULT_MODEL,
    api_base: str = DEFAULT_API_BASE,
    api_key: Optional[str] = None,
    detail: str = "auto",
    stream: bool = True,
    system_prompt: Optional[str] = None,
    timeout: int = 60
) -> str:
    """
    Sends the vision payload to the OpenAI / FastAPI endpoint and returns the text response.
    """
    import urllib.request
    import urllib.error

    if isinstance(image_inputs, (str, Path)):
        p = Path(os.path.expanduser(str(image_inputs)))
        if p.is_dir():
            img_list = sorted(list(p.glob("*.png")) + list(p.glob("*.jpg")) + list(p.glob("*.jpeg")) + list(p.glob("*.webp")))
            if not img_list:
                raise ValueError(f"No supported images (png/jpg/webp) found in directory: {p}")
            image_inputs = img_list
        else:
            image_inputs = [image_inputs]

    payload = build_vision_payload(
        image_inputs=image_inputs,
        prompt=prompt,
        model=model,
        detail=detail,
        stream=stream,
        system_prompt=system_prompt
    )

    url = f"{api_base}/chat/completions"
    headers = {
        "Content-Type": "application/json",
        "User-Agent": "vision-tool/1.0"
    }
    auth_token = api_key or os.environ.get("OPENAI_API_KEY", os.environ.get("GEMINI_API_KEY"))
    if auth_token:
        headers["Authorization"] = f"Bearer {auth_token}"

    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST"
    )

    # Bypass loopback proxy for localhost calls
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    if not stream:
        try:
            with opener.open(req, timeout=timeout) as resp:
                resp_json = json.loads(resp.read().decode("utf-8"))
                choice = resp_json.get("choices", [{}])[0]
                msg = choice.get("message", {})
                return msg.get("content", "")
        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Vision API error (HTTP {e.code}): {err_body}")

    # Streaming mode
    full_content = []
    full_thoughts = []
    in_thought = False
    is_tty = sys.stdout.isatty()

    try:
        with opener.open(req, timeout=timeout) as resp:
            for line_bytes in resp:
                line = line_bytes.decode("utf-8").strip()
                if not line or not line.startswith("data: "):
                    continue
                data_part = line[6:].strip()
                if data_part == "[DONE]":
                    break

                try:
                    chunk = json.loads(data_part)
                except Exception:
                    continue

                choices = chunk.get("choices", [])
                if not choices:
                    continue

                delta = choices[0].get("delta", {})

                # Check reasoning/thought tokens
                thought = delta.get("reasoning_content") or (delta.get("model_extra", {}) or {}).get("reasoning_content")
                if thought:
                    if not in_thought:
                        if is_tty:
                            sys.stdout.write("\n\033[1;36m🧠 Thinking Process:\033[0m\n\033[0;36m")
                            sys.stdout.flush()
                        in_thought = True
                    full_thoughts.append(thought)
                    if is_tty:
                        sys.stdout.write(thought)
                        sys.stdout.flush()

                # Text content
                content_chunk = delta.get("content")
                if content_chunk:
                    if in_thought:
                        if is_tty:
                            sys.stdout.write("\033[0m\n\n")
                            sys.stdout.flush()
                        in_thought = False
                    full_content.append(content_chunk)
                    if is_tty:
                        sys.stdout.write(content_chunk)
                        sys.stdout.flush()

        if in_thought and is_tty:
            sys.stdout.write("\033[0m\n")
            sys.stdout.flush()

        if is_tty and full_content:
            sys.stdout.write("\n")
            sys.stdout.flush()

        return "".join(full_content)

    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Vision API streaming error (HTTP {e.code}): {err_body}")


def main():
    parser = argparse.ArgumentParser(
        description="OpenAI / FastAPI Vision Payload CLI. Encodes images into standard content array with image_url."
    )
    parser.add_argument(
        "-i", "--image",
        action="append",
        required=True,
        help="Path to image file, directory of images, or URL (can be specified multiple times)"
    )
    parser.add_argument(
        "prompt",
        nargs="*",
        default=["What is in this image?"],
        help="Question or prompt regarding the image(s)"
    )
    parser.add_argument(
        "-m", "--model",
        default=DEFAULT_MODEL,
        help=f"Vision model name (default: {DEFAULT_MODEL})"
    )
    parser.add_argument(
        "-t", "--thinking",
        action="store_true",
        help="Use thinking / reasoning model (gemini-pro)"
    )
    parser.add_argument(
        "--api-base",
        default=DEFAULT_API_BASE,
        help=f"OpenAI / FastAPI endpoint base URL (default: {DEFAULT_API_BASE})"
    )
    parser.add_argument(
        "--detail",
        choices=["auto", "low", "high"],
        default="auto",
        help="Detail resolution for image processing (default: auto)"
    )
    parser.add_argument(
        "--no-stream",
        action="store_true",
        help="Disable response streaming"
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print raw JSON request payload instead of querying the server"
    )

    args = parser.parse_args()

    # Clear proxy environment variables for loopback safety
    for k in ["all_proxy", "ALL_PROXY", "http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY"]:
        os.environ.pop(k, None)

    prompt_text = " ".join(args.prompt).strip() if args.prompt else "What is in this image?"
    model_to_use = "gemini-pro" if args.thinking else args.model

    # Collect images
    images_to_process = []
    for img in args.image:
        p = Path(os.path.expanduser(img))
        if p.is_dir():
            found = sorted(list(p.glob("*.png")) + list(p.glob("*.jpg")) + list(p.glob("*.jpeg")) + list(p.glob("*.webp")))
            images_to_process.extend(found)
        else:
            images_to_process.append(img)

    if not images_to_process:
        print("Error: No valid image paths provided.", file=sys.stderr)
        sys.exit(1)

    if args.json:
        payload = build_vision_payload(
            image_inputs=images_to_process,
            prompt=prompt_text,
            model=model_to_use,
            detail=args.detail,
            stream=not args.no_stream
        )
        print(json.dumps(payload, indent=2))
        sys.exit(0)

    try:
        is_streaming = not args.no_stream
        result = query_vision_model(
            image_inputs=images_to_process,
            prompt=prompt_text,
            model=model_to_use,
            api_base=args.api_base,
            detail=args.detail,
            stream=is_streaming
        )
        # If not a TTY or if streaming was disabled, print result
        if not sys.stdout.isatty() or not is_streaming:
            print(result)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
