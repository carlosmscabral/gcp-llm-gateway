#!/usr/bin/env python3
"""Merge the k6 per-task summaries and query Cloud Monitoring for the run
window, then emit a Markdown + JSON report.

Client-side (k6) gives throughput / error / reject counts; server-side (Cloud
Monitoring) gives the authoritative latency distribution and the saturation
signals for Cloud Run, Cloud SQL, and Memorystore Valkey.

Stdlib only. Auth uses the ADC access token from `gcloud auth print-access-token`.
Metric types that return no data are reported as "n/a" (e.g. if a Valkey metric
name differs on your project — refine METRICS below after a first run using
`gcloud monitoring metric-descriptors list`).
"""
import argparse
import glob
import json
import subprocess
import sys
import urllib.request
import urllib.error

MON_API = "https://monitoring.googleapis.com/v3/projects/{project}/timeSeries"


def token():
    return subprocess.check_output(["gcloud", "auth", "print-access-token"], text=True).strip()


def query(project, tok, metric_filter, aligner, reducer, start, end, align_period="60s", combine="max"):
    """Aggregate the aligned series over the window: combine='max' (peak, for
    gauges/percentiles) or 'sum' (total, for counters). Returns None if no data."""
    import urllib.parse

    params = {
        "filter": metric_filter,
        "interval.startTime": start,
        "interval.endTime": end,
        "aggregation.alignmentPeriod": align_period,
        "aggregation.perSeriesAligner": aligner,
        "aggregation.crossSeriesReducer": reducer,
        "view": "FULL",
    }
    url = MON_API.format(project=project) + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {tok}"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return None
    vals = []
    for ts in data.get("timeSeries", []):
        for pt in ts.get("points", []):
            v = pt.get("value", {})
            for k in ("doubleValue", "int64Value", "distributionValue"):
                if k in v:
                    if k == "int64Value":
                        vals.append(float(v[k]))
                    elif k == "doubleValue":
                        vals.append(v[k])
                    else:
                        m = v[k].get("mean")
                        if m is not None:
                            vals.append(m)
    if not vals:
        return None
    return sum(vals) if combine == "sum" else max(vals)


def run_metric_filter(service, metric):
    return (
        f'resource.type="cloud_run_revision" '
        f'AND resource.labels.service_name="{service}" '
        f'AND metric.type="{metric}"'
    )


def sql_filter(instance_id, metric):
    return (
        f'resource.type="cloudsql_database" '
        f'AND resource.labels.database_id="{instance_id}" '
        f'AND metric.type="{metric}"'
    )


def valkey_filter(metric):
    # Memorystore Valkey — resource type / metric names may vary; degrade to n/a.
    return f'metric.type="{metric}"'


def merge_k6(results_dir):
    out = {"tasks": 0, "reqs": 0, "rps": 0.0, "failed_rate": 0.0, "p95_max_ms": 0.0, "rejects": {}}
    files = glob.glob(f"{results_dir}/summary-*.json")
    out["tasks"] = len(files)
    total_reqs = 0
    fail_weighted = 0.0
    for fp in files:
        try:
            d = json.load(open(fp))
        except Exception:
            continue
        m = d.get("metrics", {})
        reqs = m.get("http_reqs", {}).get("values", {}).get("count", 0)
        rate = m.get("http_reqs", {}).get("values", {}).get("rate", 0.0)
        failed = m.get("http_req_failed", {}).get("values", {}).get("rate", 0.0)
        p95 = m.get("http_req_duration", {}).get("values", {}).get("p(95)", 0.0)
        out["reqs"] += reqs
        out["rps"] += rate
        out["p95_max_ms"] = max(out["p95_max_ms"], p95)
        total_reqs += reqs
        fail_weighted += failed * reqs
        rj = m.get("litellm_rejects", {}).get("values", {}).get("count", 0)
        if rj:
            out["rejects"]["total"] = out["rejects"].get("total", 0) + rj
    out["failed_rate"] = (fail_weighted / total_reqs) if total_reqs else 0.0
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results-dir", required=True)
    ap.add_argument("--project", required=True)
    ap.add_argument("--name-prefix", required=True, help="e.g. cabral-litellm-dev")
    ap.add_argument("--sql-instance-id", required=True, help="project:instance")
    ap.add_argument("--start", required=True)
    ap.add_argument("--end", required=True)
    ap.add_argument("--run-id", required=True)
    args = ap.parse_args()

    # Pad the window: Cloud Run counters/latencies are per-minute aligned and lag
    # a few minutes, so a tight test window misses buckets. Widen it for queries.
    from datetime import datetime, timedelta, timezone

    def parse(t):
        return datetime.strptime(t, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)

    def fmt_t(dt):
        return dt.strftime("%Y-%m-%dT%H:%M:%SZ")

    q_start = fmt_t(parse(args.start) - timedelta(minutes=2))
    q_end = fmt_t(parse(args.end) + timedelta(minutes=3))
    args.start, args.end = q_start, q_end

    k6 = merge_k6(args.results_dir)
    tok = token()

    def q(f, aligner, reducer="REDUCE_MAX", combine="max"):
        return query(args.project, tok, f, aligner, reducer, args.start, args.end, combine=combine)

    gw = f"{args.name_prefix}-gateway"
    be = f"{args.name_prefix}-backend"
    server = {
        "gateway": {
            "req_count": q(run_metric_filter(gw, "run.googleapis.com/request_count"), "ALIGN_DELTA", "REDUCE_SUM", combine="sum"),
            "p95_latency_ms": q(run_metric_filter(gw, "run.googleapis.com/request_latencies"), "ALIGN_PERCENTILE_95", "REDUCE_MEAN"),
            "p99_latency_ms": q(run_metric_filter(gw, "run.googleapis.com/request_latencies"), "ALIGN_PERCENTILE_99", "REDUCE_MEAN"),
            "max_instances": q(run_metric_filter(gw, "run.googleapis.com/container/instance_count"), "ALIGN_MAX"),
        },
        "backend": {
            "req_count": q(run_metric_filter(be, "run.googleapis.com/request_count"), "ALIGN_DELTA", "REDUCE_SUM", combine="sum"),
            "p95_latency_ms": q(run_metric_filter(be, "run.googleapis.com/request_latencies"), "ALIGN_PERCENTILE_95", "REDUCE_MEAN"),
            "max_instances": q(run_metric_filter(be, "run.googleapis.com/container/instance_count"), "ALIGN_MAX"),
        },
        "cloudsql": {
            "cpu_util_max": q(sql_filter(args.sql_instance_id, "cloudsql.googleapis.com/database/cpu/utilization"), "ALIGN_MAX"),
            "connections_max": q(sql_filter(args.sql_instance_id, "cloudsql.googleapis.com/database/postgresql/num_backends"), "ALIGN_MAX"),
            "mem_util_max": q(sql_filter(args.sql_instance_id, "cloudsql.googleapis.com/database/memory/utilization"), "ALIGN_MAX"),
        },
        # Memorystore Valkey metric names can vary by project/engine; degrade to n/a.
        "valkey": {
            "cpu_util_max": q(valkey_filter("memorystore.googleapis.com/instance/cpu/average_utilization"), "ALIGN_MAX"),
            "memory_util_max": q(valkey_filter("memorystore.googleapis.com/instance/memory/usage_ratio"), "ALIGN_MAX"),
        },
    }

    report = {"run_id": args.run_id, "window": {"start": args.start, "end": args.end}, "k6": k6, "server": server}
    with open(f"{args.results_dir}/metrics.json", "w") as f:
        json.dump(report, f, indent=2)

    def fmt(v, unit=""):
        return "n/a" if v is None else f"{v:.2f}{unit}"

    md = []
    md.append(f"# Load-test report — {args.run_id}\n")
    md.append(f"Window: {args.start} → {args.end}\n")
    md.append("## Client (k6, summed across tasks)\n")
    md.append(f"- tasks: {k6['tasks']}")
    md.append(f"- total requests: {int(k6['reqs'])}")
    md.append(f"- aggregate RPS: {k6['rps']:.1f}")
    md.append(f"- failed rate: {k6['failed_rate']*100:.2f}%")
    md.append(f"- p95 (per-task max, approx): {k6['p95_max_ms']:.0f} ms")
    md.append(f"- non-200 responses (rejects): {k6['rejects'].get('total', 0)}\n")
    md.append("## Server (Cloud Monitoring)\n")
    md.append("### Cloud Run — gateway")
    md.append(f"- requests: {fmt(server['gateway']['req_count'])}")
    md.append(f"- latency p95 / p99: {fmt(server['gateway']['p95_latency_ms'],' ms')} / {fmt(server['gateway']['p99_latency_ms'],' ms')}")
    md.append(f"- max instances (ceiling 10): {fmt(server['gateway']['max_instances'])}\n")
    md.append("### Cloud Run — backend")
    md.append(f"- requests: {fmt(server['backend']['req_count'])}")
    md.append(f"- latency p95: {fmt(server['backend']['p95_latency_ms'],' ms')}")
    md.append(f"- max instances (ceiling 4): {fmt(server['backend']['max_instances'])}\n")
    md.append("### Cloud SQL (single ZONAL instance)")
    md.append(f"- CPU util max: {fmt(server['cloudsql']['cpu_util_max'])}")
    md.append(f"- connections max: {fmt(server['cloudsql']['connections_max'])}   ← watch: fan-out ceiling")
    md.append(f"- memory util max: {fmt(server['cloudsql']['mem_util_max'])}\n")
    md.append("### Memorystore Valkey (single node)")
    md.append(f"- CPU util max: {fmt(server['valkey']['cpu_util_max'])}")
    md.append(f"- memory util max: {fmt(server['valkey']['memory_util_max'])}")
    md.append("  (if n/a, refine Valkey metric names in lib/collect.py via `gcloud monitoring metric-descriptors list`)\n")
    md.append("## Notes\n")
    md.append("- Authoritative latency = Cloud Run `request_latencies`; k6 p95 is a per-task approximation.")
    md.append("- First bottleneck at current defaults is typically Cloud SQL connections or single-shard Valkey — see docs/PRODUCTION_READINESS.md §4.2–4.3.")
    with open(f"{args.results_dir}/report.md", "w") as f:
        f.write("\n".join(md) + "\n")
    print(f"wrote {args.results_dir}/report.md and metrics.json")


if __name__ == "__main__":
    main()
