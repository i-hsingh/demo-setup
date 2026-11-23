# payment-api memory leak: ready-to-send events

Generated from `payloads/scenario.json` by `./trigger export`. Plain JSON for the PagerDuty Events API v2: send them with `./send.sh`, Postman or any HTTP client, then close the alerts with `./resolve.sh`.

| # | File | Endpoint | Routed to |
|---|---|---|---|
| 1 | `01-change-event-checkout-v5-2-0-config-only-red-herring.json` | `/v2/change/enqueue` | `checkout` (its change integration key) |
| 2 | `02-change-event-payment-api-v2-14-0-rollout-codec-library-upgrade.json` | `/v2/change/enqueue` | `payment-api` (its change integration key) |
| 3 | `03-noise-probe-latency-info-suppressed-by-eo.json` | `/v2/enqueue` | `payment-api` (Reinvent Patient orchestration, dynamic routing) |
| 4 | `04-payment-api-memory-leak-worker-hung.json` | `/v2/enqueue` | `payment-api` (Reinvent Patient orchestration, dynamic routing) |
| 5 | `05-splunk-payment-api-iso-8583-decode-error-spike.json` | `/v2/enqueue` | `payment-api` (Reinvent Patient orchestration, dynamic routing) |
| 6 | `06-checkout-latency-readiness-failing.json` | `/v2/enqueue` | `checkout` (Reinvent Patient orchestration, dynamic routing) |
| 7 | `07-rds-checkout-db-read-latency.json` | `/v2/enqueue` | `checkout` (Reinvent Patient orchestration, dynamic routing) |
| 8 | `08-node-memorypressure-kubelet-evicting.json` | `/v2/enqueue` | `payment-api` (Reinvent Patient orchestration, dynamic routing) |
| 9 | `09-checkout-and-payments-portal-pods-evicted.json` | `/v2/enqueue` | `checkout` (Reinvent Patient orchestration, dynamic routing) |
| 10 | `10-checkout-503s-at-the-ingress.json` | `/v2/enqueue` | `checkout` (Reinvent Patient orchestration, dynamic routing) |
| 11 | `11-synthetics-complete-a-purchase-journey-failing.json` | `/v2/enqueue` | `checkout` (Reinvent Patient orchestration, dynamic routing) |
| 12 | `12-card-authorisation-queue-backing-up.json` | `/v2/enqueue` | `payment-api` (Reinvent Patient orchestration, dynamic routing) |
| 13 | `13-acquirer-settlement-batch-acknowledgements-overdue.json` | `/v2/enqueue` | `payment-api` (Reinvent Patient orchestration, dynamic routing) |

## Notes

- **Routing keys.** Alerts use the global orchestration key, and change events use each service's own change key. In the committed copy these are placeholders (`YOUR_ORCHESTRATION_ROUTING_KEY`, `YOUR_<SERVICE>_CHANGE_KEY`). Export with `./trigger export -keys` (menu: Export payloads) to get a copy with your real keys.
- **Timestamps.** Alerts have none, so PagerDuty uses the time it receives them. Change events keep a timestamp backdated from the export time; re-export for a fresh one.
- **Resolve** files are the full alert with `event_action: resolve`, so dynamic routing takes them to the same service.
- Every alert carries `custom_details.service`, which the orchestration routes on and uses to add `custom_details.runbook.github`.

## Postman

Import `reinvent.postman_collection.json` (File → Import). It never contains keys: paste yours into the collection variables (each one says where to find it). Run the folder **1. Run the demo** with the Collection Runner: it keeps the demo's pacing and starts a new run ID, so every run opens fresh incidents and change events are timestamped at send time. Run **2. Resolve the demo** when you're done.
