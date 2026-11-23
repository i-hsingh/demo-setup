# Runbook: scheduling

| | |
|---|---|
| **Service** | `scheduling` (PagerDuty technical service): appointment booking for clinics and patients |
| **Supports** | `payments-portal` (business service): booking pages return 503 when scheduling is down |
| **Runs on** | Kubernetes, namespace `payments`, Deployment `scheduling`, container `api` |
| **Co-located with** | `payment-api`, `payments-portal` pods (same node) |
| **Resources** | requests `memory: 16Mi`, limits `memory: 64Mi` |

## Read this first

Scheduling is small and well-behaved: it has a memory limit and rarely fails on its own. When its pods are **evicted**, the cause is almost always **another workload on the same node** using up memory. Restarting scheduling won't help, because the kubelet evicts it again. Find the neighbour first.

## Diagnose

**1. Is scheduling running at all?**

```bash
kubectl -n payments get pods -l app=scheduling -o wide
kubectl -n payments get deployment scheduling
```

`0/1` ready with `Evicted` or `Pending` pods means it was pushed off the node, not that it crashed.

**2. Why did it stop?**

```bash
kubectl -n payments describe pod -l app=scheduling | grep -A3 -E 'Reason|Message|Events'
kubectl -n payments get events --sort-by=.lastTimestamp | grep -iE 'evict|memorypressure|scheduling' | tail -20
```

| What you see | What it means | Go to |
|---|---|---|
| `Evicted`, "node had MemoryPressure" | The node ran out of memory | step 3 |
| `Pending`, "untolerated taint node.kubernetes.io/memory-pressure" | Can't be placed until the node recovers | step 3 |
| `OOMKilled` | Scheduling itself went over its 64Mi limit (rare) | step 5 |
| `CrashLoopBackOff` | The app fails on start | step 6 |
| `ImagePullBackOff` | The image can't be pulled | step 6 |

**3. Which node, and is it under memory pressure?**

```bash
kubectl get nodes
kubectl describe node <node> | grep -A6 Conditions
kubectl describe node <node> | grep -A8 'Allocated resources'
```

`MemoryPressure=True` confirms the node is the problem.

**4. Who is using the memory?**

```bash
kubectl top pods -A --sort-by=memory | head      # needs metrics-server
kubectl get pods -A -o wide --field-selector spec.nodeName=<node>
```

Look for a pod that is large, growing, and has **no memory limit**:

```bash
kubectl -n payments get pods -o custom-columns='POD:.metadata.name,LIMIT:.spec.containers[*].resources.limits.memory'
```

In this estate the usual suspect is `payment-api`. If it is the top consumer with no limit, follow the **payment-api runbook**. Check its recent change events, then restart it and apply a memory limit. Scheduling recovers on its own once the node does.

**5. Scheduling OOMKilled (its own limit)**

```bash
kubectl -n payments logs deploy/scheduling --previous --tail=50
kubectl -n payments rollout history deployment/scheduling
```

If memory grew after a recent rollout, roll back: `kubectl -n payments rollout undo deployment/scheduling`.

**6. Crash or image problems**

```bash
kubectl -n payments logs deploy/scheduling --tail=50
kubectl -n payments describe pod -l app=scheduling | grep -A2 Image
```

Roll back if the problem started with a rollout.

## Recover

Once the node reports `MemoryPressure=False`, scheduling is rescheduled automatically. To speed it up:

```bash
kubectl -n payments rollout restart deployment/scheduling
kubectl -n payments rollout status deployment/scheduling --timeout=120s
```

## Verify

- [ ] `kubectl -n payments get pods -l app=scheduling` shows `1/1 Running`.
- [ ] No `Evicted` pods left behind. Clear them with `kubectl -n payments delete pod --field-selector=status.phase=Failed`.
- [ ] Node `MemoryPressure=False`.
- [ ] Appointment booking in `payments-portal` loads (no 503).

## Follow-up (not during the incident)

- Give scheduling a `PriorityClass` above batch workloads so it is evicted last.
- Add a `LimitRange` to `payments` so no neighbour ships without a memory limit.
