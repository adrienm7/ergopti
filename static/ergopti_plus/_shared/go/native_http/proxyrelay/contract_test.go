package proxyrelay

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"testing"
)

// The canonical contract lives in _shared/modules/network; the Go constants
// are a pinned mirror, so a drift fails here instead of in the field.
func TestContractMirrorsTheCanonicalJSON(t *testing.T) {
	bytes, err := os.ReadFile(filepath.Join("..", "..", "..", "modules", "network", "proxy_auth_relay.json"))
	if err != nil {
		t.Fatal(err)
	}
	var contract struct {
		SchemaVersion int               `json:"schema_version"`
		RelayUser     string            `json:"relay_user"`
		TokenBytes    int               `json:"token_bytes"`
		Schemes       []string          `json:"schemes"`
		PosixSchemes  []string          `json:"posix_schemes"`
		Limits        map[string]int    `json:"limits"`
		ExitCodes     map[string]int    `json:"exit_codes"`
		Probe         []string          `json:"probe_statuses"`
		Refusals      map[string]string `json:"refusals"`
	}
	if err := json.Unmarshal(bytes, &contract); err != nil {
		t.Fatal(err)
	}
	if contract.SchemaVersion != 1 || contract.RelayUser != RelayUser || contract.TokenBytes != TokenBytes {
		t.Fatalf("identity drift: %+v", contract)
	}
	want := map[string]int{"max_header_bytes": MaxHeaderBytes, "max_body_bytes": MaxBodyBytes,
		"max_challenge_bytes": MaxChallengeBytes, "max_auth_rounds": MaxAuthRounds}
	if len(contract.Limits) != len(want) {
		t.Fatalf("limits drift: %v", contract.Limits)
	}
	for key, value := range want {
		if contract.Limits[key] != value {
			t.Fatalf("limit %s = %d, Go %d", key, contract.Limits[key], value)
		}
	}
	if contract.ExitCodes["ok"] != 0 || contract.ExitCodes["invalid_arguments"] != 2 || contract.ExitCodes["refused"] != 3 {
		t.Fatalf("exit codes drift: %v", contract.ExitCodes)
	}
	if len(contract.Probe) != 3 || contract.Probe[0] != ProbeNotNeeded || contract.Probe[1] != ProbeRequired || contract.Probe[2] != ProbeRefused {
		t.Fatalf("probe statuses drift: %v", contract.Probe)
	}
	if len(contract.Schemes) != 2 || contract.Schemes[0] != string(SchemeNegotiate) || contract.Schemes[1] != string(SchemeNTLM) ||
		len(contract.PosixSchemes) != 1 || contract.PosixSchemes[0] != string(SchemeNegotiate) {
		t.Fatalf("schemes drift: %v %v", contract.Schemes, contract.PosixSchemes)
	}
	// Every Go reason is in the contract; the contract adds only the caller's
	// relay_unavailable, which no relay process can report about itself.
	var json []string
	for reason := range contract.Refusals {
		if reason != "relay_unavailable" {
			json = append(json, reason)
		}
	}
	golang := append([]string(nil), Refusals...)
	sort.Strings(json)
	sort.Strings(golang)
	if len(json) != len(golang) {
		t.Fatalf("refusals drift: json %v go %v", json, golang)
	}
	for i := range json {
		if json[i] != golang[i] {
			t.Fatalf("refusals drift: json %v go %v", json, golang)
		}
	}
}
