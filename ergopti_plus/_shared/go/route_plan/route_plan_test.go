package routeplan

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"testing"
)

// The route plan is pure policy: these tests run on every OS, Windows included.

type routeVectors struct {
	Plans []struct {
		Name    string       `json:"name"`
		Entries []RouteEntry `json:"entries"`
		Expect  struct {
			Proxy   string `json:"proxy"`
			NoProxy string `json:"no_proxy"`
			Reason  string `json:"reason"`
		} `json:"expect"`
	} `json:"plans"`
	Redirects struct {
		Plan    []RouteEntry `json:"plan"`
		Targets []struct {
			Name   string `json:"name"`
			URL    string `json:"url"`
			Expect struct {
				Route  string `json:"route"`
				Reason string `json:"reason"`
			} `json:"expect"`
		} `json:"targets"`
	} `json:"redirects"`
}

// The Lua and shell twins answer this same corpus; a divergence between the
// three implementations fails here before it reaches a managed Mac.
func loadRouteVectors(t *testing.T) routeVectors {
	t.Helper()
	path := filepath.Join("..", "..", "tests", "corpus", "network", "route_plan_vectors.json")
	bytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("route plan vectors: %v", err)
	}
	var vectors routeVectors
	if err := json.Unmarshal(bytes, &vectors); err != nil {
		t.Fatalf("route plan vectors: %v", err)
	}
	return vectors
}

func TestRoutePlanAnswersEverySharedVector(t *testing.T) {
	vectors := loadRouteVectors(t)
	if len(vectors.Plans) == 0 {
		t.Fatal("the vector corpus is empty")
	}
	for _, c := range vectors.Plans {
		plan, reason := NewRoutePlan(c.Entries)
		if c.Expect.Reason != "" {
			if plan != nil || reason != c.Expect.Reason {
				t.Errorf("%s: got plan=%v reason=%q, want reason %q", c.Name, plan, reason, c.Expect.Reason)
			}
			continue
		}
		if plan == nil || reason != "" {
			t.Errorf("%s: unexpected refusal %q", c.Name, reason)
			continue
		}
		if plan.Proxy != c.Expect.Proxy || plan.NoProxy() != c.Expect.NoProxy {
			t.Errorf("%s: got %q / %q, want %q / %q", c.Name, plan.Proxy, plan.NoProxy(), c.Expect.Proxy, c.Expect.NoProxy)
		}
	}
}

func TestRoutePlanReevaluatesEveryRedirectTarget(t *testing.T) {
	vectors := loadRouteVectors(t)
	plan, reason := NewRoutePlan(vectors.Redirects.Plan)
	if plan == nil {
		t.Fatalf("the redirect plan was refused: %q", reason)
	}
	for _, c := range vectors.Redirects.Targets {
		route, refusal := plan.Redirect(c.URL)
		if route != c.Expect.Route || refusal != c.Expect.Reason {
			t.Errorf("%s: got %q / %q, want %q / %q", c.Name, route, refusal, c.Expect.Route, c.Expect.Reason)
		}
	}
}

func TestRoutePlanReasonsNeverEchoTheirInput(t *testing.T) {
	secret := "https://u:topsecret@leak.example/path"
	_, reason := NewRoutePlan([]RouteEntry{{Origin: secret, Route: "direct"}})
	plan, _ := NewRoutePlan([]RouteEntry{{Origin: "https://a.example", Route: "direct"}})
	_, redirect := plan.Redirect(secret)
	for _, value := range []string{reason, redirect} {
		if value != RoutePlanInvalid && value != RoutePlanUnplannedHost {
			t.Errorf("reason %q is outside the closed set", value)
		}
	}
}

// The closed refusal enum is declared once, in route_origins.json "refusals".
func TestRoutePlanReasonsAreTheSharedClosedSet(t *testing.T) {
	bytes, err := os.ReadFile(filepath.Join("..", "..", "modules", "network", "route_origins.json"))
	if err != nil {
		t.Fatalf("route origins: %v", err)
	}
	var inventory struct {
		Refusals []string `json:"refusals"`
	}
	if err := json.Unmarshal(bytes, &inventory); err != nil {
		t.Fatalf("route origins: %v", err)
	}
	got := []string{RoutePlanEmpty, RoutePlanInvalid, RoutePlanConflict, RoutePlanUnplannedHost}
	want := append([]string(nil), inventory.Refusals...)
	sort.Strings(got)
	sort.Strings(want)
	if len(got) != len(want) {
		t.Fatalf("refusals: got %v, want %v", got, want)
	}
	for index := range got {
		if got[index] != want[index] {
			t.Fatalf("refusals: got %v, want %v", got, want)
		}
	}
}
