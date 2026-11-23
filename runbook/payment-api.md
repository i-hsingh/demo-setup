# Runbook: payment-api

| | |
|---|---|
| **Service** | `payment-api` (PagerDuty technical service): card authorisation and settlement worker |
| **Supports** | `payments-portal` (business service) |
| **Runs on** | Kubernetes, cluster `eks-sre-demo`, namespace `payments`, Deployment `payment-api`, container `app` |
| **Co-located with** | `checkout`, `payments-portal` pods (same node) |
| **Watch** | Card authorisations time out at the card network after a few seconds and fall back to stand-in processing, and acquirer settlement batches have a contractual 15-minute acknowledgement SLA. Check the `payments.authorisations.requests` backlog early. |

## What it does

Consumes card authorisation requests from the `payments.authorisations.requests` queue, decodes ISO 8583 messages with `iso8583-codec`, sends them to the acquirer, and submits settlement batches. It does not serve user traffic directly, but it shares a node with services that do.

## Known failure: memory leak → node memory pressure

**Signature**

- Container working set grows linearly after a rollout and never plateaus.
- The container has **no memory limit**, so it is not OOM-killed. It grows until the node hits `MemoryPressure`.
- The kubelet evicts *other* pods on the node first (`payments-portal`, `checkout`), so customer-facing checkout fails before payment-api does.
- The authorisation worker blocks: heartbeat stops, the queue consumer stops acking, `payments.authorisations.requests` backs up, and settlement acknowledgements go overdue.

**Most likely cause**

A dependency change in the most recent rollout. Check change events on the service first. `iso8583-codec` 4.x pools message buffers per acquirer connection and does not release them. This was introduced in `v2.14.0`.

A config-only change to `checkout` (session cache TTL) may also appear in recent changes. It changes no dependencies or resources and is not the cause.

## Diagnose

```bash
# Which pod, which node, how long since the rollout
kubectl -n payments get pods -l app=payment-api -o wide
kubectl -n payments rollout history deployment/payment-api

# Memory (requires metrics-server)
kubectl -n payments top pod -l app=payment-api
kubectl describe node <node> | grep -A5 Conditions

# Confirm there is no limit
kubectl -n payments get deployment payment-api \
  -o jsonpath='{.spec.template.spec.containers[0].resources}'

# Hung worker
kubectl -n payments logs deploy/payment-api --tail=50 | grep -E 'blocked|heartbeat'

# Collateral
kubectl -n payments get pods --field-selector=status.phase=Failed
```

Confirm the leak if **all** of these are true:

- Memory has been growing since the last rollout.
- No memory limit is set.
- Co-located pods were evicted for `MemoryPressure`.

## Remediate (approved fix)

**Restart the pod and apply a memory limit.** Both steps are needed. A restart alone frees the memory, but the leak will take the node down again in about an hour.

### A. Pod created through a Deployment (normal case)

PagerDuty workflow: **Kubernetes Remediation** → *Pod Created through Deployment*.

```bash
# 1. Restart: delete the leaking pod; the Deployment recreates it
kubectl -n payments delete pod -l app=payment-api

# 2. Wait for the replacement
kubectl -n payments rollout status deployment/payment-api --timeout=120s

# 3. Apply a memory limit (run from the payments-toolbox pod, which may patch Deployments)
kubectl -n payments set resources deployment/payment-api -c app \
  --requests=memory=256Mi --limits=memory=512Mi
```

### B. Pod created ad hoc (no Deployment)

PagerDuty workflow: **Kubernetes Remediation** → *Pod Created Adhoc*.

```bash
kubectl -n payments delete pod payment-api
sleep 15
kubectl apply -f k8s/payment-api-adhoc-pod.yaml   # same spec, with memory limit
```

## Verify

- [ ] New `payment-api` pod is `Running` and `Ready`. Its limits show `memory: 512Mi`.
- [ ] Node `MemoryPressure=False`.
- [ ] `checkout` and `payments-portal` pods are rescheduled and `Ready 1/1`.
- [ ] Queue depth on `payments.authorisations.requests` is falling and the consumer is acking.
- [ ] Settlement acknowledgements are arriving from the acquirer.
- [ ] No new `KubePodMemoryNearNodeAllocatable` or `KubeNodeMemoryPressure` alerts for 15 minutes.

## Follow-up (not during the incident)

- Pin `iso8583-codec` to `3.4.2` or roll back to `v2.13.4` until upstream fixes buffer pooling.
- Add a `LimitRange` to `payments` so no container ships without a memory limit.
- Add an alert on working-set growth rate, not only absolute usage.
