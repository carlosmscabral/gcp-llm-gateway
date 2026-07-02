# Google Cloud Model Armor — LLM prompt/response safety, wired as a LiteLLM
# guardrail (see the guardrail registration in locals.tf, and the modelarmor.user
# grant in iam.tf). Gated by var.enable_model_armor (default false).
#
# Measurement-friendly defaults: enforcement INSPECT_ONLY (observe + log, don't
# block) and fail_on_error=false on the guardrail, so you can quantify Model
# Armor's impact (latency, hit rates) before deciding to enforce/sample.

locals {
  model_armor_location = var.model_armor_location != "" ? var.model_armor_location : var.region
  model_armor_template_id = var.model_armor_template_id != "" ? var.model_armor_template_id : (
    var.enable_model_armor ? google_model_armor_template.this[0].template_id : ""
  )
}

resource "google_model_armor_template" "this" {
  count = var.enable_model_armor && var.model_armor_template_id == "" ? 1 : 0

  location    = local.model_armor_location
  template_id = "${local.name}-armor"

  filter_config {
    rai_settings {
      rai_filters {
        filter_type      = "HATE_SPEECH"
        confidence_level = "MEDIUM_AND_ABOVE"
      }
      rai_filters {
        filter_type      = "HARASSMENT"
        confidence_level = "MEDIUM_AND_ABOVE"
      }
      rai_filters {
        filter_type      = "SEXUALLY_EXPLICIT"
        confidence_level = "MEDIUM_AND_ABOVE"
      }
      rai_filters {
        filter_type      = "DANGEROUS"
        confidence_level = "MEDIUM_AND_ABOVE"
      }
    }
    pi_and_jailbreak_filter_settings {
      filter_enforcement = "ENABLED"
      confidence_level   = "MEDIUM_AND_ABOVE"
    }
    malicious_uri_filter_settings {
      filter_enforcement = "ENABLED"
    }
    sdp_settings {
      basic_config {
        filter_enforcement = "ENABLED"
      }
    }
  }

  template_metadata {
    enforcement_type        = var.model_armor_enforcement
    log_sanitize_operations = true # emit Cloud Logging sanitize logs (for latency/analysis)

    # Multi-language detection (default on). NOTE: Model Armor "filter version"
    # (the Stable alias shown in the console) is not exposed by the Terraform
    # provider as of google ~> 6.x; the API defaults to Stable, so templates use
    # Stable filters by default. Pin explicitly via API/gcloud if ever required.
    multi_language_detection {
      enable_multi_language_detection = var.model_armor_multi_language
    }
  }

  depends_on = [google_project_service.services]
}
