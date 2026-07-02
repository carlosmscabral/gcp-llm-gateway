# Updating LiteLLM (and other components)

How to upgrade the LiteLLM version running behind this gateway safely — the
mechanics in this module, the risks, a step-by-step runbook, rollback, and
resilience recommendations.

> **The one thing to internalize:** container images roll back cleanly, but
> **database migrations do not**. `prisma migrate deploy` only moves the schema
> *forward*, and this module runs it automatically on every version change.
> Everything below is organized around making that one-way door safe.

---

## 1. Mental model

A LiteLLM upgrade in this stack is **four images moving in lockstep plus a
forward database migration**:

- `litellm-gateway`, `litellm-backend`, `litellm-ui`, `litellm-migrations` — all
  pinned to a single version via `image_tag` (or overridden per-component).
- On apply, the **migration job runs first** (`prisma migrate deploy`), then the
  gateway/backend/UI roll to new Cloud Run revisions that depend on it.

The images are pulled through the Artifact Registry **remote mirror** of
`ghcr.io/berriai` (created by the module), so nothing is pushed by hand.

Relevant files/vars:
- `image_tag` (default `v1.89.2` — the verified baseline; prefer stable release
  tags over `-dev`) and `image_registry` — `variables.tf`
- per-component overrides: `gateway_image`, `backend_image`, `ui_image`,
  `migrations_image`
- migration trigger: `bootstrap.tf` → `terraform_data.migration`
  (`triggers_replace.job_image = local.migrations_image`)
- image composition: `locals.tf` (`local.*_image`)
- mirror: `artifact_registry.tf`

---

## 2. What happens during `terraform apply` when the version changes

1. **`local.migrations_image` changes** → `terraform_data.migration`'s
   `triggers_replace` fires → it executes the migration Cloud Run Job with the
   new image and **waits** (`gcloud run jobs execute --wait`).
2. Gateway/backend/UI `depend_on terraform_data.migration`, so they only roll to
   the **new revision after the migration succeeds**. If the migration fails,
   `apply` stops and the old revisions keep serving (but the schema may already
   be partially/fully migrated — see risks).
3. Each Cloud Run service creates a new revision; Cloud Run shifts **100% of
   traffic to the latest healthy revision** (a revision that fails its startup
   probe receives no traffic).
4. The remote mirror **lazily fetches** the new tag from ghcr.io on first pull.

---

## 3. Step-by-step update runbook

### 3.1 Pre-flight (before touching anything)

- [ ] **Read the LiteLLM release notes / changelog** for the target version.
      Look for: `config.yaml` schema changes, env-var renames/deprecations,
      DB/schema changes, master-key or auth changes, provider behavior changes.
- [ ] **Confirm the target tag exists upstream** for **all four** images (a
      missing tag fails the deploy mid-apply):
      ```bash
      TAG=v1.90.0
      for img in litellm-gateway litellm-backend litellm-ui litellm-migrations; do
        tok=$(curl -s "https://ghcr.io/token?scope=repository:berriai/${img}:pull" \
              | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
        code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $tok" \
          -H "Accept: application/vnd.oci.image.index.v1+json" \
          "https://ghcr.io/v2/berriai/${img}/manifests/${TAG}")
        echo "berriai/${img}:${TAG} -> HTTP $code"   # want 200 for all four
      done
      ```
- [ ] **Prefer an immutable tag** (a real release, not `-dev`/`latest`). Even
      better, resolve it to a **digest** and pin that (see §5).
- [ ] **Back up the database** (the safety net for the forward-only migration):
      ```bash
      gcloud sql backups create \
        --instance="$(terraform output -raw ... )"   # e.g. <tenant>-litellm-<env>
        --project="$(terraform output -raw project_id)"
      ```
      (Automated backups + PITR are already enabled; an on-demand backup gives a
      clean, known pre-upgrade restore point.)
- [ ] **Record the current tag** for rollback (`terraform output` / your tfvars).

### 3.2 Stage first (strongly recommended)

Deploy the bump to a **separate environment** before production — same module,
different `env`:

```bash
# staging.tfvars: same as prod but env = "staging"
terraform workspace select staging   # or a separate state/dir
terraform apply -var-file=staging.tfvars -var="image_tag=v1.90.0"
./examples/smoke-test.sh             # exercise the flow end-to-end
```

Validate: models list, a real completion, UI login, and (once resolved) traces.

### 3.3 Apply

```bash
# edit image_tag in your tfvars, or pass -var
terraform plan  -var-file=dev.tfvars -var="image_tag=v1.90.0"   # expect 4 image URIs to change
terraform apply -var-file=dev.tfvars -var="image_tag=v1.90.0"
```

Watch the apply: the migration job should complete before the services roll.

### 3.4 Verify

```bash
# services healthy
gcloud run services list --project="$(terraform output -raw project_id)" --region=us-central1

# end-to-end
./examples/smoke-test.sh

# confirm the running revision uses the new image
gcloud run services describe <tenant>-litellm-<env>-gateway \
  --region=us-central1 --project=<project> \
  --format="value(status.traffic[0].revisionName, spec.template.spec.containers[0].image)"
```

Then watch logs, error rate, and latency for a few minutes.

---

## 4. Rollback

**Application (fast, safe):** shift Cloud Run traffic back to the previous
revision — instant and independent of Terraform:

```bash
gcloud run services update-traffic <tenant>-litellm-<env>-gateway \
  --region=us-central1 --project=<project> --to-revisions=<PREVIOUS_REVISION>=100
# repeat for backend/ui
```

**Via Terraform:** set `image_tag` back to the previous value and `apply`. Note
this re-runs the migration trigger with the *old* migrations image, but
`prisma migrate deploy` is forward-only — it will **not** undo schema changes.

**Database:** the schema does **not** roll back with the image. If the new
schema is incompatible with the old app version, restore from the pre-upgrade
backup (§3.1) — a heavier, higher-RPO operation. This is exactly why the backup
and backward-compatible migrations matter.

> Keep the previous revisions around (Cloud Run retains them) so traffic
> rollback is always available.

---

## 5. Risks & considerations

| Risk | Why it bites | Mitigation |
|---|---|---|
| **Forward-only migration** | Image rollback doesn't revert schema | Pre-upgrade backup; prefer backward-compatible (expand/contract) releases; stage first |
| **Rollout skew** | During the shift, old + new revisions can briefly coexist against one schema | Favor backward-compatible migrations; canary (§6) |
| **Mutable tags** (`-dev`, `latest`) | Non-reproducible; the **mirror caches** artifacts, so re-pushing the same tag may serve a stale image and won't roll a revision (the image string didn't change) | Use immutable release tags or pin **digests** |
| **Version skew across the 4 images** | They share a schema + API contract | Use one `image_tag`; don't mix per-component versions |
| **Missing upstream tag** | Cloud Run revision fails to pull mid-apply | Verify all four tags exist first (§3.1) |
| **Breaking config/env changes** | New version rejects old `config.yaml`/env | Read changelog; test in staging |
| **Migration partially applied on failure** | Apply halts but schema may have advanced | Backup first; investigate before retry/rollback |
| **`local-exec` migration** | Runs from the operator/CI machine; needs `gcloud` + creds; not GitOps-friendly | Move to a pipeline step (roadmap §4.7) |
| **100%-to-latest rollout** | No gradual exposure | Add canary traffic splitting (§6) |

### Pinning to a digest (reproducible, cache-proof)

Resolve the tag to a digest and pass it as a per-component override:

```bash
gcloud artifacts docker images describe \
  us-central1-docker.pkg.dev/<project>/<tenant>-litellm-<env>-mirror/berriai/litellm-gateway:v1.90.0 \
  --format='value(image_summary.digest)'
```
```hcl
gateway_image    = ".../berriai/litellm-gateway@sha256:..."
backend_image    = ".../berriai/litellm-backend@sha256:..."
ui_image         = ".../berriai/litellm-ui@sha256:..."
migrations_image = ".../berriai/litellm-migrations@sha256:..."
```
Keep them at matching versions.

---

## 6. Resilience recommendations (ordered by leverage)

1. **Stage before prod** — deploy the bump to a separate `env`, run the smoke
   test, then promote the *same* tag/digest to prod.
2. **Back up the DB pre-migration** — on-demand backup + verified restore path.
3. **Pin digests** — reproducible and immune to mirror-cache staleness.
4. **Canary via Cloud Run traffic splitting** — release the new revision at a
   small % with a revision tag, validate, then shift to 100%; roll back by
   shifting traffic. (Not wired today — the module sends 100% to latest.)
5. **Keep the last-good tag/digest recorded** for one-step rollback (schema
   caveat still applies).
6. **Stagger multi-region** — bump a canary region first (roadmap §4.8).
7. **CI/CD gate** — `plan` on PR, apply on merge, automated post-deploy smoke
   test, auto-rollback on SLO breach; run migrations as a pipeline step instead
   of `local-exec` (roadmap §4.7).

Where this module sits vs. the resilient target is summarized in
[`PRODUCTION_READINESS.md`](./PRODUCTION_READINESS.md) §4.1 and §4.7.

---

## 7. Updating the other moving parts

These are independent of LiteLLM version bumps:

- **Models** (`vertex_gemini_models`, `proxy_config`): low-risk config change →
  new gateway/backend revision (config remount), **no migration**. Safe to do
  on its own.
- **OTel collector** (`otel_collector_image`, default
  `otelcol-google:0.151.0`): bump the tag → new revision. Check the collector
  starts ("Everything is ready" in logs).
- **Terraform providers** (`versions.tf`, `google ~> 6`): run `terraform init
  -upgrade`, review the plan for provider-driven diffs, apply in staging first.
- **Terraform CLI**: pinned by `required_version >= 1.6.0`; upgrade the binary,
  re-run `plan` to confirm no state format surprises.

---

## 8. Quick reference

```bash
# 1. verify tags exist upstream (see §3.1), then back up the DB
# 2. stage
terraform apply -var-file=staging.tfvars -var="image_tag=vX.Y.Z" && ./examples/smoke-test.sh
# 3. prod
terraform plan  -var-file=dev.tfvars -var="image_tag=vX.Y.Z"
terraform apply -var-file=dev.tfvars -var="image_tag=vX.Y.Z"
./examples/smoke-test.sh
# rollback (app): gcloud run services update-traffic ... --to-revisions=<prev>=100
# rollback (schema): restore the pre-upgrade Cloud SQL backup
```

See also: [`../terraform/README.md`](../terraform/README.md) (deploy/usage),
[`DESIGN_DECISIONS.md`](./DESIGN_DECISIONS.md) (why the migration runs this way),
[`PRODUCTION_READINESS.md`](./PRODUCTION_READINESS.md) (canary, CI/CD, multi-region).
