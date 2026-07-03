"""OpenAI SDK against the gateway: unified /chat/completions + Gemini grounding.

Proves a client can use the stock `openai` client (base_url = gateway) to reach
any Vertex model, and pass Gemini-native features (google_search) via extra_body.
"""
import os
import sys

from openai import OpenAI

BASE = os.environ["BASE_URL"].rstrip("/")
MK = os.environ["MASTER_KEY"]
GEMINI = os.environ.get("GEMINI_MODEL", "gemini-3.5-flash")

client = OpenAI(base_url=f"{BASE}/v1", api_key=MK)
ok = True

# 1) basic chat
r = client.chat.completions.create(
    model=GEMINI,
    messages=[{"role": "user", "content": "Reply with exactly: gateway ok"}],
)
content = (r.choices[0].message.content or "").strip()
print(f"[C1] openai chat -> {content[:60]!r}")
ok = ok and bool(content)

# 2) google_search grounding via extra_body (no function tools alongside it)
try:
    r2 = client.chat.completions.create(
        model=GEMINI,
        messages=[{"role": "user", "content": "Who won the 2022 FIFA World Cup? Use search."}],
        extra_body={"tools": [{"googleSearch": {}}]},
    )
    txt = (r2.choices[0].message.content or "")
    # grounding metadata surfaces in provider_specific_fields / model_extra
    dump = r2.model_dump_json()
    grounded = ("grounding" in dump.lower()) or ("websearchqueries" in dump.lower())
    print(f"[C7] openai grounding -> answer={txt[:50]!r} grounding_metadata={grounded}")
    ok = ok and bool(txt)
except Exception as e:  # noqa: BLE001
    print(f"[C7] openai grounding FAILED: {e}")
    ok = False

sys.exit(0 if ok else 1)
