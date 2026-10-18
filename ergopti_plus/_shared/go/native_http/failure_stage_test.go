//go:build darwin || linux

package nativehttp

import (
	"errors"
	"net/http"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

func TestAllowedFailureStagesPreserveReasonAndPhysicalRetirement(t *testing.T) {
	cases := []struct {
		stage, reason string
		status        int
	}{
		{"native_policy_load", "unavailable", 78},
		{"native_selection_bound", "unavailable", 78},
		{"native_proxy_lookup", "unavailable", 78},
		{"native_proxy_dictionary", "proxy", 78},
		{"native_route_empty", "unavailable", 78},
		{"native_certificate_load", "certificate", 74},
		{"native_lookup_deadline", "deadline", 75},
		{"native_dispatch_deadline", "deadline", 75},
		{"native_session_terminal", "connect", 74},
	}
	for _, c := range cases {
		t.Run(c.stage, func(t *testing.T) {
			transport, record := peerTransport(t, "stage-terminal")
			t.Setenv("ERGOPTI_TEST_FAILURE_STAGE_TERMINAL", `{"version":1,"success":false,"reason":`+strconv.Quote(c.reason)+`,"native_refusal_stage":`+strconv.Quote(c.stage)+`}`)
			t.Setenv("ERGOPTI_TEST_FAILURE_STAGE_STATUS", strconv.Itoa(c.status))
			request, _ := http.NewRequest("GET", "https://private-company.invalid/model?private=payload", nil)
			request.Header.Set("Authorization", "Bearer private-secret-token")
			response, err := transport.RoundTrip(request)
			var native *Error
			if response != nil || !errors.As(err, &native) || native.Reason != c.reason {
				t.Fatalf("Failed wire changed the original reason: response=%v error=%v", response, err)
			}
			// Reflection keeps this causal corpus compilable against the genuine
			// predecessor, whose Error did not expose passive failure provenance.
			field := reflect.ValueOf(native).Elem().FieldByName("NativeFailureStage")
			if !field.IsValid() || field.Kind() != reflect.String || field.String() != c.stage {
				t.Fatal("The observed failed wire lost its allowlisted native stage")
			}
			for _, secret := range []string{"private-company", "private-secret", "payload"} {
				if strings.Contains(err.Error(), secret) {
					t.Fatal("Public error leaked private request data")
				}
			}
			if len(records(t, record)) != 1 {
				t.Fatal("Exactly one original child must be physically reaped")
			}
		})
	}
}

func TestFailureStageMetadataRefusesAmbiguousAndSuccessfulWire(t *testing.T) {
	cases := []string{
		`{"version":1,"success":false,"reason":"unavailable","native_refusal_stage":null}`,
		`{"version":1,"success":false,"reason":"unavailable","native_refusal_stage":false}`,
		`{"version":1,"success":false,"reason":"unavailable","native_refusal_stage":"raw/private-secret-token"}`,
		`{"version":1,"success":false,"reason":"certificate","native_refusal_stage":"native_policy_load"}`,
		`{"version":1,"success":true,"reason":"complete","native_refusal_stage":"native_session_terminal"}`,
		`{"version":1,"success":false,"reason":"unavailable","native_refusal_stage":"native_policy_load","native_refusal_stage":"native_proxy_lookup"}`,
		`{"version":1,"success":false,"reason":"unavailable","native_refusal_stage":"native_policy_load","extra":"private-company.invalid"}`,
		`{"version":1,"success":false,"reason":"complete","native_refusal_stage":"native_session_terminal"}`,
	}
	for i, terminal := range cases {
		t.Run(strconv.Itoa(i), func(t *testing.T) {
			transport, record := peerTransport(t, "stage-terminal")
			t.Setenv("ERGOPTI_TEST_FAILURE_STAGE_TERMINAL", terminal)
			t.Setenv("ERGOPTI_TEST_FAILURE_STAGE_STATUS", "78")
			request, _ := http.NewRequest("GET", "https://example.test/model", nil)
			response, err := transport.RoundTrip(request)
			var native *Error
			if response != nil || !errors.As(err, &native) || native.Reason != "protocol" {
				t.Fatal("Invalid passive metadata bypassed the original refusal")
			}
			if len(records(t, record)) != 1 {
				t.Fatal("Rejected wire left child custody outstanding")
			}
		})
	}
}

func TestPublicNativeDoPreservesClosedFailureProvenanceAndPrivacy(t *testing.T) {
	transport, record := peerTransport(t, "stage-terminal")
	t.Setenv("ERGOPTI_OLLAMA_NATIVE_HTTP", "1")
	t.Setenv("ERGOPTI_TEST_FAILURE_STAGE_TERMINAL", `{"version":1,"success":false,"reason":"unavailable","native_refusal_stage":"native_policy_load"}`)
	t.Setenv("ERGOPTI_TEST_FAILURE_STAGE_STATUS", "78")
	request, _ := http.NewRequest("GET", "https://private-company.invalid/model?private=payload", nil)
	request.Header.Set("Authorization", "Bearer private-secret-token")
	response, err := Do(&http.Client{Transport: transport}, request)
	var native *Error
	if response != nil || !errors.As(err, &native) || native.Reason != "unavailable" {
		t.Fatal("Public native dispatch changed the observed failed reason")
	}
	field := reflect.ValueOf(native).Elem().FieldByName("NativeFailureStage")
	if !field.IsValid() || field.Kind() != reflect.String || field.String() != "native_policy_load" {
		t.Fatal("Public native Do silently dropped the original failed-frame stage")
	}
	if !errors.As(errors.Unwrap(native), &native) {
		t.Fatal("Public native Do lost the original error chain")
	}
	for _, secret := range []string{"private-company", "private-secret", "payload"} {
		if strings.Contains(err.Error(), secret) {
			t.Fatal("Public native Do exposed private origin data")
		}
	}
	if len(records(t, record)) != 1 {
		t.Fatal("Public native Do must retain exactly one physically retired child")
	}
}
