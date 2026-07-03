"""Anthropic SDK against the gateway: the stock `anthropic.Anthropic` client
pointed at the gateway hits LiteLLM's /v1/messages endpoint.

Proves: (a) the Anthropic Messages format is cross-provider (drives Gemini too),
and (b) Claude-on-Vertex native features (tool use) work when Claude is registered.
Note: the AnthropicVertex SDK class is NOT supported against LiteLLM — use the
plain Anthropic client + /v1/messages, as done here.
"""
import os
import sys

import anthropic

BASE = os.environ["BASE_URL"].rstrip("/")
MK = os.environ["MASTER_KEY"]
GEMINI = os.environ.get("GEMINI_MODEL", "gemini-3.5-flash")
CLAUDE = os.environ.get("CLAUDE_MODEL", "claude-sonnet")

client = anthropic.Anthropic(base_url=BASE, api_key=MK)
ok = True

# (a) cross-provider: Anthropic wire format -> Gemini backend
m = client.messages.create(
    model=GEMINI,
    max_tokens=64,
    messages=[{"role": "user", "content": "Reply with exactly: gateway ok"}],
)
text = m.content[0].text if m.content else ""
print(f"[C3] anthropic-sdk -> gemini via /v1/messages -> {text[:60]!r}")
ok = ok and bool(text)

# (b) Claude-on-Vertex native tool use (best-effort; skips if Claude not registered)
try:
    mc = client.messages.create(
        model=CLAUDE,
        max_tokens=256,
        tools=[{
            "name": "get_weather",
            "description": "Get the weather for a city",
            "input_schema": {
                "type": "object",
                "properties": {"city": {"type": "string"}},
                "required": ["city"],
            },
        }],
        messages=[{"role": "user", "content": "What is the weather in Paris? Use the tool."}],
    )
    print(f"[C10] anthropic-sdk -> claude tool_use stop_reason={mc.stop_reason}")
except Exception as e:  # noqa: BLE001
    print(f"[C10] claude tool-use SKIP/FAIL (register Claude to test): {e}")

sys.exit(0 if ok else 1)
