# Incident workflows: exact names, descriptions, triggers and steps for all
# four. Terraform owns every step, so change them here, not in the UI (the
# next apply reverts UI edits). Every action ID was checked against
# GET /incident_workflows/actions on the account.
#
# The two Kubernetes workflows run staged `echo` output (k8s_workflow_output.tf)
# through the Kubernetes Cluster connector and copy it to the incident as a
# note. Without a connector (k8s_connection_id empty) they post the same output
# as a note directly, so the demo still works.

# Major Incident sets this priority when a person declares it.
data "pagerduty_priority" "p1" {
  count = var.enable_priority ? 1 : 0
  name  = var.priority_name
}

locals {
  responder_ref = [{ id = data.pagerduty_user.responder.id, type = "user_reference" }]
  stakeholders = concat(
    local.responder_ref,
    local.team == null ? [] : [{ id = local.team, type = "team_reference" }],
  )
  use_gchat = var.major_incident_conference == "google_chat"
  use_slack = var.slack_workspace_id != ""

  managed_workflows = var.manage_incident_workflows ? {
    paige_slack = {
      name        = "🏥 Paige Virtual Responder - Dedicated Slack Channel"
      description = "Creates a dedicated Slack channel for the incident and brings in Paige to investigate."
      trigger     = "conditional"
      services    = [for s in pagerduty_service.tech : s.id]
      steps = concat(
        local.use_slack ? [{
          name   = "Create Incident Dedicated Channel" # Add Paige's defaults reference this exact name
          action = "pagerduty.com:slack:create-a-channel:4"
          inputs = { "Workspace" = var.slack_workspace_id }
        }] : [],
        [{
          name   = "Add Paige"
          action = "pagerduty.com:pagerduty-advance:auto-triage:5"
          inputs = {
            "Post in Paige in Pagerduty"           = "true"
            "Post investigation results as a Note" = "true"
            "Post investigation results in Slack"  = local.use_slack ? "true" : "false"
          }
        }],
      )
    }
    major_incident = {
      name        = "🏥 Major Incident"
      description = "For P1 incidents with customer impact. Adds responders and stakeholders, opens a Google Chat space for the response and posts its link on the incident."
      trigger     = "manual"
      services    = [for s in pagerduty_service.tech : s.id]
      steps = concat(
        var.enable_priority ? [{
          name   = "Set priority ${var.priority_name}"
          action = "pagerduty.com:incident-workflows:update-incident-priority:1"
          inputs = { "Priority" = data.pagerduty_priority.p1[0].id }
        }] : [],
        [
          {
            name   = "Add responders"
            action = "pagerduty.com:incident-workflows:add-responders:2"
            inputs = { "Responders" = jsonencode(local.responder_ref) }
          },
          {
            name   = "Add stakeholders"
            action = "pagerduty.com:incident-workflows:add-stakeholders:3"
            inputs = { "Stakeholders" = jsonencode(local.stakeholders) }
          },
        ],
        local.use_gchat ? [
          {
            name   = "Create Google Chat space"
            action = "pagerduty.com:google-chat:create-private-space:1"
            inputs = merge(
              { "Space Display Name" = "INC-{{incident.incident_number}} ${var.business_service_name} major incident" },
              var.google_workspace == "" ? {} : { "Google Workspace" = var.google_workspace },
            )
          },
          {
            name   = "Add responders to the space"
            action = "pagerduty.com:google-chat:add-space-member:1"
            inputs = merge(
              {
                "Space Name"  = "{{steps['Create Google Chat space'].fields['Space Name']}}"
                "User Emails" = var.responder_email
              },
              var.google_workspace == "" ? {} : { "Google Workspace" = var.google_workspace },
            )
          },
          {
            name   = "Post the space link"
            action = "pagerduty.com:incident-workflows:add-notes-to-incident:1"
            inputs = {
              "Incident ID" = "{{incident.id}}"
              "Message"     = "Major incident declared. Google Chat space: {{steps['Create Google Chat space'].fields['Space URL']}}"
            }
          },
        ] : [],
      )
    }
    k8s_diagnostics = {
      name        = "🏥 Kubernetes diagnostics"
      description = "Collects pod, node, rollout and log diagnostics for ${var.technical_service_name} through the Kubernetes Cluster connector and copies them to the incident as a note."
      trigger     = "conditional"
      services    = [pagerduty_service.tech["claims"].id]
      steps       = local.k8s_steps["diagnostics"]
    }
    k8s_remediation = {
      name        = "🏥 Kubernetes Remediation"
      description = "Applies a memory limit and parser streaming to the ${var.technical_service_name} deployment, waits for the rollout and copies the result to the incident as a note. Run only after a person approves Paige's recommendation."
      trigger     = "manual"
      services    = [pagerduty_service.tech["claims"].id]
      steps       = local.k8s_steps["remediation"]
    }
  } : {}

  # Kubernetes workflow steps: run the echo script in a pod, then copy its
  # output to a note. No connector: the note carries the same text directly.
  k8s_steps = {
    for k, v in {
      diagnostics = { step = "Collect pod diagnostics", title = "Kubernetes diagnostics", command = local.k8s_diagnostics_command, text = local.k8s_diagnostics_lines }
      remediation = { step = "Deploy new settings", title = "Kubernetes remediation", command = local.k8s_remediation_command, text = local.k8s_remediation_lines }
      } : k => var.k8s_connection_id != "" ? [
      {
        name   = v.step
        action = "pagerduty.com:kubernetes-clusters:run-pod-command:3"
        inputs = {
          "Connection Input" = var.k8s_connection_id
          "Pod Name"         = var.k8s_exec_pod
          "Namespace"        = var.k8s_namespace
          "Container"        = var.k8s_exec_container
          "Shell"            = "/bin/sh"
          "Command"          = v.command
        }
      },
      {
        name   = "Copy output to incident notes"
        action = "pagerduty.com:incident-workflows:add-notes-to-incident:1"
        inputs = {
          "Incident ID" = "{{incident.id}}"
          "Message"     = "{{steps['${v.step}'].fields['Command Output']}}"
        }
      },
      ] : [
      {
        name   = "Copy output to incident notes"
        action = "pagerduty.com:incident-workflows:add-notes-to-incident:1"
        inputs = {
          "Incident ID" = "{{incident.id}}"
          "Message"     = join("\n", v.text)
        }
      },
    ]
  }

}

resource "pagerduty_incident_workflow" "managed" {
  for_each = local.managed_workflows

  name        = each.value.name
  description = each.value.description
  team        = local.team

  dynamic "step" {
    for_each = each.value.steps
    content {
      name   = step.value.name
      action = step.value.action
      dynamic "input" {
        for_each = step.value.inputs
        content {
          name  = input.key
          value = input.value
        }
      }
    }
  }
}

resource "pagerduty_incident_workflow_trigger" "this" {
  for_each = local.managed_workflows

  workflow                   = pagerduty_incident_workflow.managed[each.key].id
  type                       = each.value.trigger
  services                   = each.value.services
  subscribed_to_all_services = false
  condition                  = each.value.trigger == "conditional" ? var.conditional_trigger_expression : null
}

# The workflows used to be one resource; keep the existing ones (same IDs).
moved {
  from = pagerduty_incident_workflow.this["paige_slack"]
  to   = pagerduty_incident_workflow.managed["paige_slack"]
}

moved {
  from = pagerduty_incident_workflow.this["major_incident"]
  to   = pagerduty_incident_workflow.managed["major_incident"]
}

moved {
  from = pagerduty_incident_workflow.this["k8s_diagnostics"]
  to   = pagerduty_incident_workflow.manual["k8s_diagnostics"]
}

moved {
  from = pagerduty_incident_workflow.manual["k8s_diagnostics"]
  to   = pagerduty_incident_workflow.managed["k8s_diagnostics"]
}

moved {
  from = pagerduty_incident_workflow.this["k8s_remediation"]
  to   = pagerduty_incident_workflow.manual["k8s_remediation"]
}

moved {
  from = pagerduty_incident_workflow.manual["k8s_remediation"]
  to   = pagerduty_incident_workflow.managed["k8s_remediation"]
}
