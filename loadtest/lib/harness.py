#!/usr/bin/env python3
"""Set up / tear down the load-test's LiteLLM virtual keys and build the
per-run k6 config.

setup:    mint one virtual key per enabled profile (via /key/generate with the
          master key), then write results/<run>/config.json (the file the k6 Job
          reads) and results/<run>/keys.json (for teardown).
teardown: delete every key recorded in keys.json (safety: only aliases that
          start with 'loadtest-').

Uses only the stdlib (urllib) so there are no pip dependencies.
"""
import argparse
import json
import sys
import urllib.request
import urllib.error


def api_post(base_url, path, master_key, payload):
    req = urllib.request.Request(
        f"{base_url}{path}",
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {master_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:500]}


def cmd_setup(args):
    cfg = json.load(open(args.config))
    enabled = [p for p in cfg["profiles"] if p.get("enabled")]
    keys = {}
    run_profiles = []
    for p in enabled:
        alias = f"loadtest-{args.run_id}-{p['name']}"
        body = {
            "key_alias": alias,
            "models": p.get("key_models", []),
            "max_budget": p.get("key_budget"),
            "rpm_limit": p.get("key_rpm"),
            "tpm_limit": p.get("key_tpm"),
            "metadata": {"loadtest_run": args.run_id, "profile": p["name"]},
        }
        status, resp = api_post(args.base_url, "/key/generate", args.master_key, body)
        if status != 200 or "key" not in resp:
            print(f"  ! failed to create key for {p['name']}: {status} {resp}", file=sys.stderr)
            sys.exit(1)
        keys[p["name"]] = {"key": resp["key"], "alias": alias}
        print(f"  + key for profile '{p['name']}' (alias {alias})")
        # profile entry for the k6 config, with the minted key injected
        rp = {k: v for k, v in p.items() if not k.startswith("key_") and k != "enabled"}
        rp["key"] = resp["key"]
        run_profiles.append(rp)

    run_cfg = {
        "run_id": args.run_id,
        "base_url": args.base_url,
        "tasks": cfg.get("tasks", 1),
        "thresholds": cfg.get("thresholds", {}),
        "profiles": run_profiles,
    }
    with open(f"{args.out}/config.json", "w") as f:
        json.dump(run_cfg, f, indent=2)
    with open(f"{args.out}/keys.json", "w") as f:
        json.dump(keys, f, indent=2)
    print(f"  created {len(keys)} keys; wrote {args.out}/config.json")


def cmd_teardown(args):
    try:
        keys = json.load(open(f"{args.out}/keys.json"))
    except FileNotFoundError:
        print("  no keys.json — nothing to delete")
        return
    to_delete = [v["key"] for v in keys.values() if v.get("alias", "").startswith("loadtest-")]
    if not to_delete:
        print("  no loadtest- keys to delete")
        return
    status, resp = api_post(args.base_url, "/key/delete", args.master_key, {"keys": to_delete})
    if status != 200:
        print(f"  ! key delete failed: {status} {resp}", file=sys.stderr)
        sys.exit(1)
    print(f"  deleted {len(to_delete)} keys")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["setup", "teardown"])
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--master-key", required=True)
    ap.add_argument("--config", default="config.json")
    ap.add_argument("--out", required=True)
    ap.add_argument("--run-id", default="current")
    args = ap.parse_args()
    (cmd_setup if args.action == "setup" else cmd_teardown)(args)


if __name__ == "__main__":
    main()
