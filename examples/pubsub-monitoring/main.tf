/**
 * Copyright 2022 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

resource "random_id" "random_topic_id_suffix" {
  byte_length = 2
}

resource "google_pubsub_topic" "secret" {
  project = var.project_id
  name    = "topic-${random_id.random_topic_id_suffix.hex}"
}

resource "google_pubsub_subscription" "secret_subscription" {
  name    = "subscription-${random_id.random_topic_id_suffix.hex}"
  topic   = google_pubsub_topic.secret.name
  project = var.project_id
}

resource "google_project_service_identity" "secretmanager_identity" {
  provider = google-beta
  project  = var.project_id
  service  = "secretmanager.googleapis.com"
}

resource "google_pubsub_topic_iam_member" "sm_sa_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_project_service_identity.secretmanager_identity.email}"
  topic   = google_pubsub_topic.secret.name
}

module "secret-manager" {
  source  = "GoogleCloudPlatform/secret-manager/google"
  version = "~> 0.4"

  project_id = var.project_id
  secrets = [
    {
      name               = "secret-pubsub-1"
      next_rotation_time = "2024-11-02T15:01:23Z"
      rotation_period    = "31536000s"
      secret_data        = "secret information"
    },
  ]
  topics = {
    secret-pubsub-1 = [
      {
        name = google_pubsub_topic.secret.id
      }
    ]
  }
  depends_on = [
    google_pubsub_topic_iam_member.sm_sa_publisher
  ]
}

resource "google_monitoring_notification_channel" "email_channel" {
  project      = var.project_id
  display_name = "Secret deletion alert channel"
  type         = "email"
  description  = "Sends email notifications for secret deletion alerts"

  labels = {
    email_address = "alisboa@google.com"
  }
}

resource "google_monitoring_alert_policy" "alert_policy" {
  project      = var.project_id
  display_name = "Secret Deletion Alert"
  documentation {
    content = "Secret manager alert! $${metric.display_name} from $${resource.project} there was a change on one of your secrets from ${join(" ", module.secret-manager.secret_names)}"
  }
  combiner = "OR"
  conditions {
    display_name = "Condition 1"
    condition_threshold {
      comparison = "COMPARISON_GT"
      duration   = "300s"
      filter     = "resource.type = \"pubsub_subscription\" AND resource.labels.subscription_id = \"${google_pubsub_subscription.secret_subscription.id}\" AND metric.type = \"pubsub.googleapis.com/subscription/num_undelivered_messages\""
    }
  }

  alert_strategy {
    notification_channel_strategy {
      renotify_interval          = "1800s"
      notification_channel_names = [google_monitoring_notification_channel.email_channel.name]
    }
  }

  notification_channels = [google_monitoring_notification_channel.email_channel.name]

  user_labels = {
    severity = "warning"
  }
}
