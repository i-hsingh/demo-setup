package main

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Dynamic routing looks services up by name, and PagerDuty takes a while
// (minutes, sometimes much longer) to learn the names of newly created
// services. Until then it accepts alerts sent to the orchestration and drops
// them: no incident, no error. So after creating the services, and before
// any demo run, we send one test alert per service through the orchestration
// until each one opens an incident, then resolve them.
//
// <root>/.routing-ready holds the orchestration ID that passed, so the check
// runs once per (re)created orchestration.

const (
	routingCheckEvery   = 30 * time.Second
	routingCheckTimeout = 30 * time.Minute
)

func routingReadyPath(root string) string { return filepath.Join(root, ".routing-ready") }

// routingReady reports whether this orchestration already passed the check.
func routingReady(root, orchestrationID string) bool {
	raw, err := os.ReadFile(routingReadyPath(root))
	return err == nil && strings.TrimSpace(string(raw)) == orchestrationID
}

type tfService struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// ensureRouting runs the routing check unless this orchestration has passed
// it. s may be nil (demo run): settings then come from the saved values,
// asking only if there are none.
func ensureRouting(c *common, sp *settings) error {
	oid, err := terraformOutput(c.tfDir(), "event_orchestration_id")
	if err != nil {
		return c.notReady(err)
	}
	if routingReady(c.root, oid) {
		return nil
	}
	var s settings
	switch {
	case sp != nil:
		s = *sp
	case confirmed != nil:
		s = *confirmed
	case os.Getenv(envToken) != "":
		s = settings{token: os.Getenv(envToken), region: normRegion(os.Getenv(envRegion))}
		if s.region == "" {
			s.region = "us"
		}
	default:
		if s, err = ensureSetup(c.root); err != nil {
			return err
		}
	}
	key, err := c.key()
	if err != nil {
		return err
	}
	raw, err := terraformOutput(c.tfDir(), "services")
	if err != nil {
		return c.notReady(err)
	}
	var byKey map[string]tfService
	if err := json.Unmarshal([]byte(raw), &byKey); err != nil {
		return fmt.Errorf("reading the services output: %w", err)
	}
	var services []tfService
	for _, svc := range byKey {
		services = append(services, svc)
	}
	sort.Slice(services, func(i, j int) bool { return services[i].Name < services[j].Name })

	fmt.Println("Checking that PagerDuty routes alerts to the new services…")
	fmt.Println("  New services take PagerDuty a while to learn (often a few minutes). Until then,")
	fmt.Println("  alerts are accepted but silently dropped, so the demo would show nothing.")
	fmt.Printf("  Sending a test alert to each service every %s until it arrives (up to %s).\n", routingCheckEvery, routingCheckTimeout)

	snd := newSender(key, nil, false)
	stamp := time.Now().UTC().Format("20060102T150405")
	dedup := func(svc tfService) string { return "reinvent/routing-check/" + svc.Name + "/" + stamp }
	body := func(svc tfService, action string) map[string]any {
		return map[string]any{
			"event_action": action,
			"dedup_key":    dedup(svc),
			"payload": map[string]any{
				"summary":        "Reinvent routing check for " + svc.Name + " (resolves itself)",
				"source":         "reinvent-setup",
				"severity":       "warning",
				"custom_details": map[string]any{"service": svc.Name},
			},
		}
	}
	defer func() { // resolve whatever we opened, success or not
		for _, svc := range services {
			_ = snd.send("alert", body(svc, "resolve"))
		}
	}()

	since := time.Now().Add(-time.Minute).UTC().Format(time.RFC3339)
	pending := map[string]tfService{}
	for _, svc := range services {
		pending[svc.ID] = svc
	}
	start := time.Now()
	for len(pending) > 0 {
		for _, svc := range pending {
			if err := snd.send("alert", body(svc, "trigger")); err != nil {
				return fmt.Errorf("sending the routing test alert: %w", err)
			}
		}
		time.Sleep(routingCheckEvery)
		ids := make([]string, 0, len(services))
		for _, svc := range services {
			ids = append(ids, svc.ID)
		}
		if got, err := routedAlerts(s, ids, since); err == nil {
			for id, svc := range pending {
				if got[id][dedup(svc)] {
					fmt.Printf("  %s✓%s %s receives alerts (%s)\n", cGreen, cReset, svc.Name, time.Since(start).Round(time.Second))
					delete(pending, id)
				}
			}
		}
		if len(pending) > 0 {
			if time.Since(start) > routingCheckTimeout {
				return fmt.Errorf("PagerDuty still isn't routing alerts to the new services after %s.\n"+
					"  Nothing is wrong with your setup: PagerDuty is slow to learn new service names.\n"+
					"  Try DEMO → 1 again later: it repeats this check first", routingCheckTimeout)
			}
			fmt.Printf("  still waiting… (%s so far)\n", time.Since(start).Round(time.Second))
		}
	}
	if err := os.WriteFile(routingReadyPath(c.root), []byte(oid+"\n"), 0o644); err != nil {
		return err
	}
	fmt.Println("  Routing works. The test incidents are being resolved.")
	return nil
}

// routedAlerts returns the dedup keys of alerts that reached each service
// (service ID → set of keys) on incidents since `since`. It looks at alerts,
// not incidents: cross-service grouping can put one service's alert on
// another service's incident.
func routedAlerts(s settings, serviceIDs []string, since string) (map[string]map[string]bool, error) {
	q := url.Values{}
	for _, id := range serviceIDs {
		q.Add("service_ids[]", id)
	}
	q.Set("since", since)
	q.Set("limit", "100")
	for _, st := range []string{"triggered", "acknowledged", "resolved"} {
		q.Add("statuses[]", st)
	}
	var r struct {
		Incidents []struct {
			ID string `json:"id"`
		} `json:"incidents"`
	}
	if _, err := apiGet(s.token, s.region, "/incidents?"+q.Encode(), &r); err != nil {
		return nil, err
	}
	got := map[string]map[string]bool{}
	for _, inc := range r.Incidents {
		var a struct {
			Alerts []struct {
				AlertKey string `json:"alert_key"`
				Service  struct {
					ID string `json:"id"`
				} `json:"service"`
			} `json:"alerts"`
		}
		if _, err := apiGet(s.token, s.region, "/incidents/"+inc.ID+"/alerts?limit=100", &a); err != nil {
			return nil, err
		}
		for _, al := range a.Alerts {
			if got[al.Service.ID] == nil {
				got[al.Service.ID] = map[string]bool{}
			}
			got[al.Service.ID][al.AlertKey] = true
		}
	}
	return got, nil
}
