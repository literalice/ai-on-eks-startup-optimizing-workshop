#!/usr/bin/env python3
"""Measure time to first token against a local vLLM OpenAI-compatible server.

Runs *inside* the workload pod (prep.sh loads it as a ConfigMap, bench.sh calls it
with kubectl exec), so there is no port-forward to be flaky and no assumption
about curl being in the image -- a vLLM image has Python by definition.

Ready is not the same as useful. For an inference server the number the business
cares about is submit-to-first-token, and this is the part of it that Ready does
not cover.

Prints one JSON object on stdout so bench.sh can fold it into the run record.
"""

from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8000"
PROMPT = "Explain what a container image layer is, in two sentences."


def wait_for_health(deadline):
    """The probe may arrive a beat before the server accepts connections."""
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(f"{BASE}/health", timeout=5) as response:
                if response.status == 200:
                    return True
        except (urllib.error.URLError, OSError):
            pass
        time.sleep(0.5)
    return False


def served_model_name(deadline):
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(f"{BASE}/v1/models", timeout=5) as response:
                payload = json.loads(response.read())
                data = payload.get("data") or []
                if data:
                    return data[0].get("id")
        except (urllib.error.URLError, OSError, json.JSONDecodeError):
            pass
        time.sleep(0.5)
    return None


def measure(model, max_tokens):
    """Stream a completion and stop the clock on the first token that carries text.

    Streaming matters: without it the server buffers the whole completion and the
    only thing measurable is total latency, which is dominated by how many tokens
    were asked for rather than by how quickly the model started producing.
    """
    body = json.dumps(
        {
            "model": model,
            "prompt": PROMPT,
            "max_tokens": max_tokens,
            "temperature": 0,
            "stream": True,
        }
    ).encode()

    request = urllib.request.Request(
        f"{BASE}/v1/completions",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    started = time.monotonic()
    first_token = None
    tokens = 0

    with urllib.request.urlopen(request, timeout=300) as response:
        for raw in response:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            chunk = line[len("data:"):].strip()
            if chunk == "[DONE]":
                break
            try:
                parsed = json.loads(chunk)
            except json.JSONDecodeError:
                continue
            text = "".join(c.get("text", "") for c in parsed.get("choices") or [])
            if not text:
                continue
            tokens += 1
            if first_token is None:
                first_token = time.monotonic() - started

    return {
        "ttft_seconds": round(first_token, 3) if first_token is not None else None,
        "total_seconds": round(time.monotonic() - started, 3),
        "tokens_received": tokens,
    }


def main() -> int:
    max_tokens = int(sys.argv[1]) if len(sys.argv) > 1 else 64
    deadline = time.monotonic() + 120

    if not wait_for_health(deadline):
        print(json.dumps({"error": "server did not become healthy within 120s"}))
        return 1

    model = served_model_name(deadline)
    if not model:
        print(json.dumps({"error": "no model listed at /v1/models"}))
        return 1

    try:
        result = measure(model, max_tokens)
    except Exception as exc:  # noqa: BLE001 - the probe must not mask the run
        print(json.dumps({"error": f"{type(exc).__name__}: {exc}"}))
        return 1

    result["model"] = model
    print(json.dumps(result))
    return 0 if result.get("ttft_seconds") is not None else 1


if __name__ == "__main__":
    sys.exit(main())
