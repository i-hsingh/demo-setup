# What the two Kubernetes workflows print. The commands are plain `echo`s run
# inside a pod through the Kubernetes Cluster connector: the output is staged
# (not read from the cluster) so it always matches the story in the payloads,
# whatever is actually running. Each workflow copies its output to the
# incident as a note.
#
# Keep these free of single quotes: each line becomes  echo '<line>'.

locals {
  k8s_diagnostics_lines = [
    "== Kubernetes diagnostics: ${var.k8s_namespace}/${var.technical_service_name} ==",
    "",
    "$ kubectl -n ${var.k8s_namespace} get pods -o wide",
    "NAME                                     READY   STATUS    RESTARTS   AGE   NODE",
    "${var.technical_service_name}-7f9c6d8b5-x2kqp   1/1     Running   0          47m   reinvent-control-plane",
    "scheduling-5d7b9c4f6-mz8wt               0/1     Evicted   0          3h    reinvent-control-plane",
    "scheduling-5d7b9c4f6-q4hrn               0/1     Pending   0          6m    <none>",
    "patient-portal-6b8d5f7c9-tl2vd           0/1     Evicted   0          5h    reinvent-control-plane",
    "",
    "$ kubectl -n ${var.k8s_namespace} top pod",
    "NAME                                     CPU(cores)   MEMORY(bytes)",
    "${var.technical_service_name}-7f9c6d8b5-x2kqp   1840m        7412Mi",
    "",
    "$ kubectl describe node reinvent-control-plane | grep -A3 Conditions",
    "  MemoryPressure   True    KubeletHasInsufficientMemory   kubelet has insufficient memory available",
    "  Allocatable memory: 7.7Gi   Available: 212Mi (eviction threshold 300Mi)",
    "",
    "$ kubectl -n ${var.k8s_namespace} get deploy ${var.technical_service_name} -o jsonpath={.spec.template.spec.containers[0].resources}",
    "{}    <- no requests or limits: QoS BestEffort, the kubelet evicts its neighbours instead",
    "",
    "$ kubectl -n ${var.k8s_namespace} rollout history deploy/${var.technical_service_name}",
    "REVISION  CHANGE-CAUSE",
    "41        image registry.internal/claims/${var.technical_service_name}:v2.13.4",
    "42        image registry.internal/claims/${var.technical_service_name}:v2.14.0 (x12-claims-parser 4.2.1 -> 5.0.0), 47m ago",
    "",
    "$ kubectl -n ${var.k8s_namespace} logs deploy/${var.technical_service_name} --tail=4",
    "WARN  x12parser  835 batch 18233: buffered 41,882 segments, streaming disabled",
    "WARN  x12parser  heap 7.1Gi after GC (was ~600Mi on v2.13.4)",
    "ERROR worker     heartbeat missed for 240s, reconciliation queue depth 12,904",
    "ERROR worker     clearinghouse ACK timeout (batch 18231, 18232)",
    "",
    "$ kubectl -n ${var.k8s_namespace} get events --field-selector reason=Evicted",
    "6m   Warning  Evicted  pod/scheduling-5d7b9c4f6-mz8wt       The node was low on resource: memory.",
    "6m   Warning  Evicted  pod/patient-portal-6b8d5f7c9-tl2vd   The node was low on resource: memory.",
    "",
    "SUMMARY",
    "- ${var.technical_service_name} v2.14.0 grows ~150Mi/min since the x12-claims-parser 5.0.0 upgrade 47m ago.",
    "- It has no memory limit, so the node hit MemoryPressure and evicted scheduling and patient-portal.",
    "- Suggested fix: Kubernetes Remediation (memory limit + parser streaming), then roll back to v2.13.4 if it recurs.",
  ]

  k8s_remediation_lines = [
    "== Kubernetes remediation: ${var.k8s_namespace}/${var.technical_service_name} ==",
    "",
    "$ kubectl -n ${var.k8s_namespace} set resources deploy/${var.technical_service_name} -c app --requests=memory=256Mi --limits=memory=512Mi",
    "deployment.apps/${var.technical_service_name} resource requirements updated",
    "",
    "$ kubectl -n ${var.k8s_namespace} set env deploy/${var.technical_service_name} -c app X12_PARSER_STREAMING=true X12_MAX_BATCH_SEGMENTS=5000 GOMEMLIMIT=450MiB",
    "deployment.apps/${var.technical_service_name} env updated",
    "",
    "$ kubectl -n ${var.k8s_namespace} rollout status deploy/${var.technical_service_name} --timeout=120s",
    "Waiting for deployment \"${var.technical_service_name}\" rollout to finish: 0 of 1 updated replicas are available...",
    "deployment \"${var.technical_service_name}\" successfully rolled out (revision 43)",
    "",
    "$ kubectl -n ${var.k8s_namespace} get deploy ${var.technical_service_name} -o jsonpath={.spec.template.spec.containers[0].resources}",
    "{\"limits\":{\"memory\":\"512Mi\"},\"requests\":{\"memory\":\"256Mi\"}}   <- QoS Burstable",
    "",
    "$ kubectl -n ${var.k8s_namespace} get pods -o wide",
    "NAME                                     READY   STATUS    RESTARTS   AGE   NODE",
    "${var.technical_service_name}-84c7b9d6f-h7m2s   1/1     Running   0          58s   reinvent-control-plane",
    "scheduling-5d7b9c4f6-q4hrn               1/1     Running   0          8m    reinvent-control-plane",
    "patient-portal-6b8d5f7c9-w9xpk           1/1     Running   0          41s   reinvent-control-plane",
    "",
    "$ kubectl -n ${var.k8s_namespace} top pod ${var.technical_service_name}-84c7b9d6f-h7m2s",
    "NAME                                     CPU(cores)   MEMORY(bytes)",
    "${var.technical_service_name}-84c7b9d6f-h7m2s   420m         318Mi",
    "",
    "$ kubectl describe node reinvent-control-plane | grep MemoryPressure",
    "  MemoryPressure   False   KubeletHasSufficientMemory   kubelet has sufficient memory available",
    "",
    "RESULT",
    "- New settings: memory request 256Mi, limit 512Mi; X12 parser streaming on, batches capped at 5,000 segments.",
    "- Node MemoryPressure cleared; scheduling and patient-portal are back to 1/1 Ready.",
    "- Reconciliation queue draining. Follow-up: fix the x12-claims-parser 5.0.0 buffering, or pin 4.2.1.",
  ]

  # Shell for Run Pod Command: one echo per line.
  k8s_diagnostics_command = join("\n", [for l in local.k8s_diagnostics_lines : "echo '${l}'"])
  k8s_remediation_command = join("\n", [for l in local.k8s_remediation_lines : "echo '${l}'"])
}
