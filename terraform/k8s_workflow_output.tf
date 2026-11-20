# What the two Kubernetes workflows print: plain kubectl output, no commentary.
# The commands are `echo`s run inside a pod through the Kubernetes Cluster
# connector, so the output always matches the story in the payloads whatever
# is actually running. Each workflow copies its output to the incident as a
# note.
#
# Keep these free of single quotes: each line becomes  echo '<line>'.

locals {
  k8s_ns   = var.k8s_namespace
  k8s_app  = var.technical_service_name
  k8s_node = "reinvent-control-plane"

  # Diagnostics: the broken state.
  k8s_diagnostics_lines = [
    "$ kubectl -n ${local.k8s_ns} get pods -o wide",
    "NAME                                    READY   STATUS    RESTARTS   AGE   IP            NODE                     NOMINATED NODE   READINESS GATES",
    "${local.k8s_app}-7f9c6d8b5-x2kqp   1/1     Running   0          47m   10.244.0.23   ${local.k8s_node}   <none>           <none>",
    "patient-portal-6b8d5f7c9-tl2vd          0/1     Evicted   0          5h    <none>        ${local.k8s_node}   <none>           <none>",
    "scheduling-5d7b9c4f6-mz8wt              0/1     Evicted   0          3h    <none>        ${local.k8s_node}   <none>           <none>",
    "scheduling-5d7b9c4f6-q4hrn              0/1     Pending   0          6m    <none>        <none>                   <none>           <none>",
    "",
    "$ kubectl -n ${local.k8s_ns} get deploy",
    "NAME                    READY   UP-TO-DATE   AVAILABLE   AGE",
    "${local.k8s_app}   1/1     1            1           12d",
    "patient-portal          0/1     1            0           12d",
    "scheduling              0/1     1            0           12d",
    "",
    "$ kubectl -n ${local.k8s_ns} top pods",
    "NAME                                    CPU(cores)   MEMORY(bytes)",
    "${local.k8s_app}-7f9c6d8b5-x2kqp   1840m        7412Mi",
    "",
    "$ kubectl top node",
    "NAME                     CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)",
    "${local.k8s_node}   2310m        57%      7491Mi          97%",
    "",
    "$ kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp",
    "NAMESPACE    LAST SEEN   TYPE      REASON                 OBJECT                                MESSAGE",
    "default      9m          Warning   EvictionThresholdMet   node/${local.k8s_node}   Attempting to reclaim memory",
    "${local.k8s_ns}   6m          Warning   Evicted                pod/scheduling-5d7b9c4f6-mz8wt        The node was low on resource: memory. Threshold quantity: 300Mi, available: 212Mi. Container app was using 188Mi, request is 128Mi, has larger consumption of memory.",
    "${local.k8s_ns}   6m          Warning   Evicted                pod/patient-portal-6b8d5f7c9-tl2vd    The node was low on resource: memory. Threshold quantity: 300Mi, available: 212Mi. Container web was using 164Mi, request is 128Mi, has larger consumption of memory.",
    "${local.k8s_ns}   6m          Warning   FailedScheduling       pod/scheduling-5d7b9c4f6-q4hrn        0/1 nodes are available: 1 node(s) had untolerated taint {node.kubernetes.io/memory-pressure: }. preemption: 0/1 nodes are available: 1 Preemption is not helpful for scheduling.",
    "",
    "$ kubectl -n ${local.k8s_ns} get deploy ${local.k8s_app} -o jsonpath={.spec.template.spec.containers[0].resources}",
    "{}",
    "",
    "$ kubectl -n ${local.k8s_ns} rollout history deploy/${local.k8s_app}",
    "deployment.apps/${local.k8s_app}",
    "REVISION  CHANGE-CAUSE",
    "41        image registry.internal/claims/${local.k8s_app}:v2.13.4",
    "42        image registry.internal/claims/${local.k8s_app}:v2.14.0",
    "",
    "$ kubectl -n ${local.k8s_ns} logs deploy/${local.k8s_app} --tail=5",
    "level=warn component=x12parser msg=\"segment buffer grew\" batch=18233 segments=41882 streaming=false",
    "level=warn component=x12parser msg=\"heap after GC\" heap_inuse=7.1GiB",
    "level=error component=worker msg=\"heartbeat missed\" since=240s queue_depth=12904",
    "level=error component=clearinghouse msg=\"ACK timeout\" batch=18231",
    "level=error component=clearinghouse msg=\"ACK timeout\" batch=18232",
  ]

  # Remediation: the deployment with new settings, then everything healthy.
  k8s_remediation_lines = [
    "$ kubectl -n ${local.k8s_ns} set resources deploy/${local.k8s_app} -c app --requests=memory=256Mi --limits=memory=512Mi",
    "deployment.apps/${local.k8s_app} resource requirements updated",
    "",
    "$ kubectl -n ${local.k8s_ns} set env deploy/${local.k8s_app} -c app X12_PARSER_STREAMING=true X12_MAX_BATCH_SEGMENTS=5000 GOMEMLIMIT=450MiB",
    "deployment.apps/${local.k8s_app} env updated",
    "",
    "$ kubectl -n ${local.k8s_ns} rollout status deploy/${local.k8s_app} --timeout=120s",
    "Waiting for deployment \"${local.k8s_app}\" rollout to finish: 1 old replicas are pending termination...",
    "deployment \"${local.k8s_app}\" successfully rolled out",
    "",
    "$ kubectl -n ${local.k8s_ns} get deploy ${local.k8s_app} -o jsonpath={.spec.template.spec.containers[0].resources}",
    "{\"limits\":{\"memory\":\"512Mi\"},\"requests\":{\"memory\":\"256Mi\"}}",
    "",
    "$ kubectl -n ${local.k8s_ns} get pods -o wide",
    "NAME                                    READY   STATUS    RESTARTS   AGE   IP            NODE                     NOMINATED NODE   READINESS GATES",
    "${local.k8s_app}-84c7b9d6f-h7m2s   1/1     Running   0          94s   10.244.0.31   ${local.k8s_node}   <none>           <none>",
    "patient-portal-6b8d5f7c9-w9xpk          1/1     Running   0          71s   10.244.0.33   ${local.k8s_node}   <none>           <none>",
    "scheduling-5d7b9c4f6-q4hrn              1/1     Running   0          9m    10.244.0.32   ${local.k8s_node}   <none>           <none>",
    "",
    "$ kubectl -n ${local.k8s_ns} get deploy",
    "NAME                    READY   UP-TO-DATE   AVAILABLE   AGE",
    "${local.k8s_app}   1/1     1            1           12d",
    "patient-portal          1/1     1            1           12d",
    "scheduling              1/1     1            1           12d",
    "",
    "$ kubectl -n ${local.k8s_ns} top pods",
    "NAME                                    CPU(cores)   MEMORY(bytes)",
    "${local.k8s_app}-84c7b9d6f-h7m2s   420m         318Mi",
    "patient-portal-6b8d5f7c9-w9xpk          35m          141Mi",
    "scheduling-5d7b9c4f6-q4hrn              62m          176Mi",
    "",
    "$ kubectl top node",
    "NAME                     CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)",
    "${local.k8s_node}   690m         17%      3184Mi          41%",
    "",
    "$ kubectl get events -A --field-selector type=Warning",
    "No resources found",
    "",
    "$ kubectl -n ${local.k8s_ns} logs deploy/${local.k8s_app} --tail=4",
    "level=info component=x12parser msg=\"streaming enabled\" max_batch_segments=5000",
    "level=info component=worker msg=\"heartbeat\" queue_depth=8711",
    "level=info component=clearinghouse msg=\"ACK received\" batch=18231",
    "level=info component=clearinghouse msg=\"ACK received\" batch=18232",
  ]

  # Shell for Run Pod Command: one echo per line.
  k8s_diagnostics_command = join("\n", [for l in local.k8s_diagnostics_lines : "echo '${l}'"])
  k8s_remediation_command = join("\n", [for l in local.k8s_remediation_lines : "echo '${l}'"])
}
