# Runs the prisma schema migration as part of `terraform apply`. Gateway and
# backend depend on this (in cloudrun.tf) so they don't go live until the
# schema exists. Requires `gcloud` on the machine running terraform with creds
# able to invoke Cloud Run admin APIs.

resource "terraform_data" "migration" {
  triggers_replace = {
    job_id    = google_cloud_run_v2_job.migrations.id
    job_image = local.migrations_image
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      JOB     = google_cloud_run_v2_job.migrations.name
      REGION  = var.region
      PROJECT = var.project_id
    }
    command = <<-EOT
      set -euo pipefail
      gcloud run jobs execute "$JOB" \
        --region "$REGION" \
        --project "$PROJECT" \
        --wait
    EOT
  }

  depends_on = [
    google_cloud_run_v2_job.migrations,
    google_sql_user.app,
  ]
}
