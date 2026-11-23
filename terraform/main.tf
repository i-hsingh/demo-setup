# Services, the business service and the dependency graph.
#
#                               ┌──> payment-api (technical)  <- the culprit
#   payments-portal (business) ──┤
#                               └──> checkout              (technical)  <- evicted neighbour
#
# Alerts reach the technical services through the global Event Orchestration
# in orchestration.tf (dynamic routing on custom_details.service). When either
# technical service has an open incident, payments-portal shows as impacted on
# the service graph, the Business Services view and the internal status page.

locals {
  team = var.team_id == "" ? null : var.team_id

  # Keys are stable identifiers; names are what dynamic routing looks up, so
  # they must equal custom_details.service in the payloads.
  technical_services = {
    claims = {
      name        = var.technical_service_name
      description = "Card authorisation and settlement worker: decodes ISO 8583 messages, sends authorisations to the acquirer and submits settlement batches. Runs as a Deployment in the payments namespace and shares a node with checkout and payments-portal."
    }
    scheduling = {
      name        = var.scheduling_service_name
      description = "Cart confirmation and payment submission for customers, backed by the RDS checkout-db. Runs as a Deployment in the payments namespace on the same node as payment-api."
    }
  }
}

data "pagerduty_user" "responder" {
  email = var.responder_email
}

resource "pagerduty_escalation_policy" "claims" {
  name        = "${var.technical_service_name} escalation"
  description = "Level 1 is Paige (SRE Agent, added in the UI). The human responder is the backstop. Shared by payment-api and checkout."
  num_loops   = 1
  teams       = local.team == null ? null : [local.team]

  rule {
    escalation_delay_in_minutes = 10
    target {
      type = "user_reference"
      id   = data.pagerduty_user.responder.id
    }
  }

  # Paige is added as level 1 in the UI (EA: "Paige on Escalation Policies"),
  # which the provider cannot express. Ignoring rule changes stops a later
  # apply from deleting her.
  lifecycle {
    ignore_changes = [rule]
  }
}

resource "pagerduty_service" "tech" {
  for_each = local.technical_services

  name                    = each.value.name
  description             = each.value.description
  escalation_policy       = pagerduty_escalation_policy.claims.id
  acknowledgement_timeout = "null"
  auto_resolve_timeout    = "null"

  incident_urgency_rule {
    type    = "constant"
    urgency = "high"
  }
}

# Change events go straight to each service through its own integration
# (/v2/change/enqueue). The app picks the key by the change event's
# custom_details.service. Alerts use the global orchestration's routing key.
resource "pagerduty_service_integration" "changes" {
  for_each = pagerduty_service.tech

  name    = "CI/CD change events (Events API v2)"
  service = each.value.id
  type    = "events_api_v2_inbound_integration"
}

resource "pagerduty_alert_grouping_setting" "tech" {
  name     = "payments node grouping"
  type     = var.alert_grouping_type
  services = [for s in pagerduty_service.tech : s.id]

  config {
    time_window = var.alert_grouping_type == "intelligent" ? var.alert_grouping_window_seconds : null
    # Cross-service: one setting covering both services lets an alert on
    # checkout join the payment-api incident (same node).
    iag_fields = var.alert_grouping_type == "intelligent" ? var.iag_fields : null
    timeout    = var.alert_grouping_type == "time" ? var.alert_grouping_window_seconds : null
    aggregate  = var.alert_grouping_type == "content_based" ? "all" : null
    # Every alert in the scenario carries the node name as `source`.
    fields = var.alert_grouping_type == "content_based" ? ["source"] : null
  }
}

resource "pagerduty_business_service" "patient_portal" {
  name             = var.business_service_name
  description      = "Customers pay for orders and manage saved cards. Customer-facing. Depends on payment-api and checkout."
  point_of_contact = "Payments Experience on-call"
  team             = local.team
}

resource "pagerduty_service_dependency" "portal_on_tech" {
  for_each = pagerduty_service.tech

  dependency {
    dependent_service {
      id   = pagerduty_business_service.patient_portal.id
      type = "business_service"
    }
    supporting_service {
      id   = each.value.id
      type = "service"
    }
  }
}

# Renamed resources: keep an existing payment-api (and its incidents)
# instead of destroying and recreating it on the next apply.
moved {
  from = pagerduty_service.claims
  to   = pagerduty_service.tech["claims"]
}

moved {
  from = pagerduty_service_integration.changes
  to   = pagerduty_service_integration.changes["claims"]
}

moved {
  from = pagerduty_alert_grouping_setting.claims
  to   = pagerduty_alert_grouping_setting.tech
}

moved {
  from = pagerduty_business_service.this["patient_portal"]
  to   = pagerduty_business_service.patient_portal
}

moved {
  from = pagerduty_event_orchestration_service.claims
  to   = pagerduty_event_orchestration_service.tech["claims"]
}
