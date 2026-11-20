# 05: Incident workflows

Terraform creates all four workflows complete (names start with 🏥 so they are easy to find): **exact names**, descriptions, triggers and steps. Nothing needs building in the UI.

If you set `manage_incident_workflows = false`, create each workflow from its template instead, and set the name, trigger and service scope by hand to match the table.

| Workflow (exact name) | Trigger | Created by Terraform |
|---|---|---|
| 🏥 Paige Virtual Responder - Dedicated Slack Channel | Conditional on creation (`incident.urgency matches 'high'`), both services | 🟢 complete, steps included |
| 🏥 Kubernetes diagnostics | Conditional on creation, claims-reconciliation | 🟢 complete, steps included |
| 🏥 Major Incident | Manual, both services | 🟢 complete, steps included |
| 🏥 Kubernetes Remediation | Manual, claims-reconciliation | 🟢 complete, steps included |

Terraform owns every step, so make changes in `terraform/workflows.tf`, not the UI: the next apply reverts UI edits.

---

## Paige Virtual Responder - Dedicated Slack Channel

- **Description:** Creates a dedicated Slack channel for the incident and brings in Paige to investigate.
- **Steps (Terraform):** **Add Paige** posts her investigation in PagerDuty and as an incident note. If `slack_workspace_id` is set in `terraform.tfvars` (your Slack workspace ID, which starts with `T`), a **Create Incident Dedicated Channel** step comes first and Paige also posts in that channel.
- **Check:** Paige's findings appear on the incident within about a minute. With Slack on, the channel appears too. If it doesn't, see the Slack reauth note in 04.

## Kubernetes diagnostics

Plain kubectl output, no commentary, staged as `echo` lines in `terraform/k8s_workflow_output.tf` so it always matches the payloads: pods, deployments, `top`, warning events, the missing memory limit, rollout history, logs.

1. **Collect pod diagnostics**: *Kubernetes Clusters: Run Pod Command* runs the echo script in `k8s_exec_pod` (default `claims-toolbox`, container `worker`, namespace `healthcare`) through the connection in `k8s_connection_id`.
2. **Copy output to incident notes**: *Add Notes to Incident* with the step 1 `Command Output`.

Without `k8s_connection_id`, step 1 is left out and step 2 posts the same text directly, so the note still appears.

## Major Incident

- **Description:** For P1 incidents with customer impact. Assigns incident roles, adds responders, stakeholders and Scribe, opens a Google Chat space for the response and posts its link on the incident.
- **Trigger:** manual. It runs only when Paige recommends it and a person approves.
- **Steps (Terraform), in order:**
  1. **Set priority P1** (skipped if `enable_priority = false`)
  2. **Assign <role>**: one step per entry in `major_incident_roles`, each assigning that role to you. Roles must be given **by ID**: names fail, and the API can't list roles. Copy IDs from an existing workflow's *Assign an Incident Role* step. An unknown ID stops the workflow.
  3. **Add responders**: you, as a stand-in for a Patient Experience team
  4. **Add stakeholders**: you, plus `team_id` if set
  5. **Add Scribe**: flags the Scribe agent for the incident
  6. **Create Google Chat space**: a private space named `INC-<number> patient-portal major incident`. Needs Google Chat connected (04). Set `google_workspace` if more than one workspace is connected; set `major_incident_conference = "none"` to drop steps 6–8.
  7. **Add responders to the space**: adds the responder's email
  8. **Post the space link**: an incident note with the space URL

## Kubernetes Remediation

Manual. Plain kubectl output of a deployment with new settings (memory request 256Mi / limit 512Mi, `X12_PARSER_STREAMING=true`, `X12_MAX_BATCH_SEGMENTS=5000`, `GOMEMLIMIT=450MiB`), the rollout, then everything healthy: all pods Running, node memory 41%, no warning events, clean logs.

1. **Deploy new settings**: *Run Pod Command*, same pod and connection as diagnostics.
2. **Copy output to incident notes**: the step 1 output as a note.

Same fallback: no connection, the note carries the text directly. The commands only `echo`; nothing in the cluster changes.

---

## Not verified here

Action names, field labels and the *Surface → Slack* path all come from the brief and the templates, and EA builds change them. Run each workflow once by hand against a test incident before the demo ([07](07-preflight.md)).
