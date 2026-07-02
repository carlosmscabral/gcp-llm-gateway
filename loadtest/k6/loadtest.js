// k6 load test for the LiteLLM gateway.
//
// Config arrives as a JSON string in $CONFIG_JSON (the entrypoint reads the
// per-run config.json the runner uploaded to the mounted results bucket). Each
// enabled profile becomes a k6 scenario; execution segments (set by the
// entrypoint from CLOUD_RUN_TASK_INDEX/COUNT) split total load across tasks.
//
// Summary is written to $K6_SUMMARY_PATH (under the mounted bucket) so the
// runner can pull + merge per-task summaries afterward.

import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';
import { Counter } from 'k6/metrics';

const cfg = JSON.parse(__ENV.CONFIG_JSON);
const profilesByName = {};
for (const p of cfg.profiles) profilesByName[p.name] = p;

// Count of non-200 responses, labeled by profile + status — powers the
// rate-limit / budget / model-ACL assertions in the report.
const rejects = new Counter('litellm_rejects');

export const options = {
  discardResponseBodies: true, // we only need status/timing at load
  scenarios: buildScenarios(cfg),
  thresholds: cfg.thresholds || {},
};

function buildScenarios(cfg) {
  const s = {};
  for (const p of cfg.profiles) {
    if (p.enabled === false) continue; // run.sh already includes only enabled profiles
    if (p.executor === 'ramping-vus') {
      s[p.name] = {
        executor: 'ramping-vus',
        startVUs: p.startVUs || 0,
        stages: p.stages,
        exec: 'runProfile',
        tags: { profile: p.name },
        gracefulStop: '30s',
      };
    } else {
      // default: constant request rate (RPS), independent of response time
      s[p.name] = {
        executor: 'constant-arrival-rate',
        rate: p.rate,
        timeUnit: '1s',
        duration: p.duration,
        preAllocatedVUs: p.preAllocatedVUs || 50,
        maxVUs: p.maxVUs || 1000,
        exec: 'runProfile',
        tags: { profile: p.name },
      };
    }
  }
  return s;
}

function makePrompt(tokens) {
  return 'ping '.repeat(Math.max(1, tokens || 8)).trim();
}

export function runProfile() {
  const name = exec.scenario.name;
  const p = profilesByName[name];
  const url = `${cfg.base_url}/v1/chat/completions`;
  const payload = JSON.stringify({
    model: p.model,
    messages: [{ role: 'user', content: makePrompt(p.prompt_tokens) }],
    stream: !!p.stream,
    max_tokens: p.max_tokens || 32,
  });
  const params = {
    headers: { Authorization: `Bearer ${p.key}`, 'Content-Type': 'application/json' },
    tags: { profile: name, model: p.model },
    timeout: p.timeout || '60s',
  };

  const res = http.post(url, payload, params);

  // A profile is "healthy" if it returns 200, or the reject code it's meant to
  // provoke (429 for ratelimit, 400 for budget/model-acl).
  check(res, {
    'ok or expected-reject': (r) =>
      r.status === 200 || (p.expect_status && r.status === p.expect_status),
  });
  if (res.status !== 200) {
    rejects.add(1, { profile: name, status: String(res.status) });
  }
}

export function handleSummary(data) {
  const out = {};
  const path = __ENV.K6_SUMMARY_PATH || 'summary.json';
  out[path] = JSON.stringify(data, null, 2);
  out['stdout'] = miniSummary(data); // keep a readable line in the task logs
  return out;
}

function miniSummary(data) {
  const m = data.metrics || {};
  const httpReqs = (m.http_reqs && m.http_reqs.values && m.http_reqs.values.count) || 0;
  const rate = (m.http_reqs && m.http_reqs.values && m.http_reqs.values.rate) || 0;
  const dur = (m.http_req_duration && m.http_req_duration.values) || {};
  const failed = (m.http_req_failed && m.http_req_failed.values && m.http_req_failed.values.rate) || 0;
  return (
    `\nk6 task summary: reqs=${httpReqs} rps=${rate.toFixed(1)} ` +
    `p95=${(dur['p(95)'] || 0).toFixed(0)}ms p99=${(dur['p(99)'] || 0).toFixed(0)}ms ` +
    `avg=${(dur.avg || 0).toFixed(0)}ms failed=${(failed * 100).toFixed(2)}%\n`
  );
}
