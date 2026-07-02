# Load / stress test harness — all gated by var.enable_loadtest (default false),
# so a normal deploy creates none of this. Runner scripts live in ../loadtest.
#
# Design: a k6 image (custom, script baked in) lives in a STANDARD Artifact
# Registry repo (the ghcr mirror is pull-through/read-only). A k6 Cloud Run Job
# runs it with task parallelism; each task mounts the results bucket (gcsfuse RW)
# at /work, reads the per-run config the runner uploaded, and writes its summary
# back. The Job needs no LiteLLM master key — data-plane calls use the per-run
# virtual keys carried in the config; key setup/teardown happens in run.sh with
# operator credentials.

# STANDARD repo to HOST our k6 image (distinct from the pull-through mirror).
resource "google_artifact_registry_repository" "loadtest" {
  count = var.enable_loadtest ? 1 : 0

  location      = var.region
  repository_id = local.loadtest_repo_id
  description   = "Custom k6 load-test image for ${local.name}."
  format        = "DOCKER"
  mode          = "STANDARD_REPOSITORY"
  labels        = local.labels

  depends_on = [google_project_service.services]
}

# Private bucket for per-run config + k6 summaries.
resource "google_storage_bucket" "loadtest" {
  count = var.enable_loadtest ? 1 : 0

  name                        = "${var.project_id}-${local.name}-loadtest-${random_id.bucket_suffix.hex}"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = var.gcs_force_destroy
  public_access_prevention    = "enforced"

  labels = local.labels

  depends_on = [google_project_service.services]
}

# Dedicated least-privilege SA for the k6 Job: only writes the results bucket
# (via the gcsfuse volume). No secret access, no data-plane IAM.
resource "google_service_account" "loadtest" {
  count = var.enable_loadtest ? 1 : 0

  account_id   = "${local.name}-loadtest"
  display_name = "LiteLLM k6 load-test runner"

  depends_on = [google_project_service.services]
}

resource "google_storage_bucket_iam_member" "loadtest_runner" {
  count = var.enable_loadtest ? 1 : 0

  bucket = google_storage_bucket.loadtest[0].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.loadtest[0].email}"
}

# Cloud Run service agent pulls the k6 image from the STANDARD repo.
resource "google_artifact_registry_repository_iam_member" "loadtest_pull" {
  count = var.enable_loadtest ? 1 : 0

  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.loadtest[0].repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:service-${data.google_project.this.number}@serverless-robot-prod.iam.gserviceaccount.com"
}

# Cloud Build (used to build the k6 image) runs as the Compute Engine default SA
# on new projects; grant it the builder role so `gcloud builds submit` can push
# to the STANDARD repo. Broad-ish but standard; tighten with a dedicated build SA
# if desired.
resource "google_project_iam_member" "loadtest_cloudbuild" {
  count = var.enable_loadtest ? 1 : 0

  project = var.project_id
  role    = "roles/cloudbuild.builds.builder"
  member  = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"

  depends_on = [google_project_service.services]
}

# Build + push the k6 image so a fresh `terraform apply` works in one pass
# (the Job below can't be created until the image exists). Rebuilds when the k6
# sources change. Mirrors the migration local-exec pattern; needs gcloud on the
# machine running terraform. Use `loadtest/run.sh build` for manual rebuilds.
resource "terraform_data" "k6_build" {
  count = var.enable_loadtest ? 1 : 0

  triggers_replace = {
    dockerfile = filemd5("${path.module}/../loadtest/k6/Dockerfile")
    script     = filemd5("${path.module}/../loadtest/k6/loadtest.js")
    entrypoint = filemd5("${path.module}/../loadtest/k6/run-k6.sh")
    image      = local.k6_image
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      # brief retry to absorb IAM propagation of the builder role
      for i in 1 2 3; do
        gcloud builds submit "${path.module}/../loadtest/k6" \
          --tag "${local.k6_image}" --project "${var.project_id}" --quiet && exit 0
        echo "build attempt $i failed; retrying in 20s" >&2; sleep 20
      done
      exit 1
    EOT
  }

  depends_on = [
    google_artifact_registry_repository.loadtest,
    google_project_iam_member.loadtest_cloudbuild,
    google_project_service.services,
  ]
}

# k6 Cloud Run Job. task_count/parallelism are set per-run by run.sh
# (`gcloud run jobs update --tasks --parallelism`) and ignored here to avoid drift.
resource "google_cloud_run_v2_job" "loadtest" {
  count = var.enable_loadtest ? 1 : 0

  name                = "${local.name}-loadtest"
  location            = var.region
  labels              = local.labels
  deletion_protection = false

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account = google_service_account.loadtest[0].email
      max_retries     = 0
      timeout         = var.loadtest_task_timeout

      containers {
        image = local.k6_image

        resources {
          limits = {
            cpu    = var.loadtest_cpu
            memory = var.loadtest_memory
          }
        }

        # The runner writes gs://<bucket>/runs/current/config.json before each
        # execute; the entrypoint reads it from the mounted volume. RUN_ID/BASE_URL
        # /keys/scenarios all live in that config, so no per-run env mutation.
        env {
          name  = "WORK_DIR"
          value = "/work"
        }

        volume_mounts {
          name       = "work"
          mount_path = "/work"
        }
      }

      volumes {
        name = "work"
        gcs {
          bucket    = google_storage_bucket.loadtest[0].name
          read_only = false
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].task_count,
      template[0].parallelism,
    ]
  }

  depends_on = [
    google_artifact_registry_repository.loadtest,
    google_artifact_registry_repository_iam_member.loadtest_pull,
    google_storage_bucket_iam_member.loadtest_runner,
    terraform_data.k6_build,
    google_project_service.services,
  ]
}
