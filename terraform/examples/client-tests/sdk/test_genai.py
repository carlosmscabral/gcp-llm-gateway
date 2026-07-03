"""Google GenAI SDK (google-genai) against the gateway — verifies the FLAGGED
item: LiteLLM documents only the JS SDK via passthrough base_url; the Python SDK
pattern is unverified upstream. This test settles it empirically.

All-Vertex deployment => target the /vertex_ai passthrough in the SDK's Vertex
mode, and carry the gateway's virtual/master key as `x-litellm-api-key` so LiteLLM
(not the caller) authenticates to Vertex via ADC. Prints the outcome either way.
"""
import os
import sys

BASE = os.environ["BASE_URL"].rstrip("/")
MK = os.environ["MASTER_KEY"]
PROJECT = os.environ.get("PROJECT", "")
LOCATION = os.environ.get("PT_LOCATION", "us-central1")
GEMINI = os.environ.get("GEMINI_MODEL", "gemini-3.5-flash")

try:
    from google import genai
    from google.genai import types
except Exception as e:  # noqa: BLE001
    print(f"[C6] google-genai import FAILED: {e}")
    sys.exit(1)

print(f"[C6] google-genai via /vertex_ai passthrough (project={PROJECT} loc={LOCATION})")
try:
    client = genai.Client(
        vertexai=True,
        project=PROJECT,
        location=LOCATION,
        http_options=types.HttpOptions(
            base_url=f"{BASE}/vertex_ai",
            headers={"x-litellm-api-key": f"Bearer {MK}"},
        ),
    )
    resp = client.models.generate_content(
        model=GEMINI, contents="Reply with exactly: gateway ok"
    )
    print(f"[C6] google-genai passthrough OK -> {(resp.text or '')[:60]!r}")
    sys.exit(0)
except Exception as e:  # noqa: BLE001
    # A failure here is itself a documented finding (limitation L4).
    print(f"[C6] google-genai passthrough NOT working via this pattern: {e}")
    print("      -> Document as a limitation; native Gemini is reachable via the "
          "OpenAI SDK (/chat/completions) or raw /vertex_ai passthrough (curl).")
    sys.exit(1)
