//go:build darwin || linux

package nativehttp

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"
)

// These vectors were transcribed from Ollama v0.40.4 transfer/redirect.go
// (isPublicIP and its blocked CGNAT/benchmark networks), not from this port.
func TestDestinationPolicyIndependentUpstreamVectors(t *testing.T) {
	for value, expected := range map[string]bool{
		"8.8.8.8":           true,
		"203.0.113.10":      true,
		"2606:4700::1111":   true,
		"10.1.2.3":          false,
		"172.16.0.1":        false,
		"192.168.1.1":       false,
		"127.0.0.1":         false,
		"169.254.169.254":   false,
		"100.64.0.1":        false,
		"100.100.2.148":     false,
		"198.18.0.1":        false,
		"198.19.255.255":    false,
		"0.0.0.0":           false,
		"224.0.0.1":         false,
		"::1":               false,
		"fe80::1":           false,
		"fc00::1":           false,
		"::ffff:100.64.0.1": false,
		"::ffff:10.0.0.1":   false,
	} {
		if publicAddress(net.ParseIP(value)) != expected {
			t.Fatalf("%s public=%v diverges from the upstream checked dialer", value, !expected)
		}
	}
}

func checkedPeerlessTransport(t *testing.T, baseURL string, allowPrivate bool) (*Transport, *bool) {
	t.Helper()
	transport, _ := peerTransport(t, "complete")
	reached := false
	transport.ResolveWorker = func() (string, error) { reached = true; return "", fail("unavailable") }
	transport.Destination = newDestinationPolicy(baseURL, allowPrivate, transport.Policy).check
	return transport, &reached
}

func TestDestinationPolicyRefusesNonPublicBeforeNativeWorker(t *testing.T) {
	original := lookupAddresses
	t.Cleanup(func() { lookupAddresses = original })
	lookupAddresses = func(_ context.Context, host string) ([]net.IP, error) {
		switch host {
		case "mixed.example":
			return []net.IP{net.ParseIP("8.8.8.8"), net.ParseIP("10.0.0.7")}, nil
		case "empty.example":
			return nil, nil
		case "registry.example", "public.example":
			return []net.IP{net.ParseIP("10.0.0.5")}, nil
		}
		return nil, errors.New("independent resolver refusal")
	}
	transport, reached := checkedPeerlessTransport(t, "https://Registry.Example", false)
	for _, target := range []string{"https://10.0.0.1/blob", "https://169.254.169.254/latest", "https://[::ffff:100.64.0.1]/blob", "https://127.0.0.1:443/blob", "https://mixed.example/blob", "https://public.example/blob", "https://localhost/blob", "https://Localhost./blob", "https://metadata.localhost/blob"} {
		request, _ := http.NewRequest(http.MethodGet, target, nil)
		_, err := transport.RoundTrip(request)
		var native *Error
		if !errors.As(err, &native) || native.Reason != "connect" || !errors.Is(err, errDestinationNotPublic) || *reached {
			t.Fatalf("%s was not refused before the native worker: %v", target, err)
		}
	}
	// A name this machine cannot resolve is left to the proxy or the native
	// worker, which resolve it on their own side (a PAC-only network).
	for _, target := range []string{"https://unresolved.example/blob", "https://empty.example/blob"} {
		unresolvedTransport, unresolvedReached := checkedPeerlessTransport(t, "https://Registry.Example", false)
		request, _ := http.NewRequest(http.MethodGet, target, nil)
		if _, err := unresolvedTransport.RoundTrip(request); !*unresolvedReached || errors.Is(err, errDestinationNotPublic) {
			t.Fatalf("%s was refused instead of left to the native worker: %v", target, err)
		}
	}
	// The registry host the caller named keeps upstream's exemption.
	request, _ := http.NewRequest(http.MethodGet, "https://registry.example/v2/library/blobs", nil)
	if _, err := transport.RoundTrip(request); !*reached || errors.Is(err, errDestinationNotPublic) {
		t.Fatalf("Exempt registry host did not reach the native worker: %v", err)
	}
	insecure, insecureReached := checkedPeerlessTransport(t, "", true)
	request, _ = http.NewRequest(http.MethodGet, "http://10.0.0.1/blob", nil)
	if _, err := insecure.RoundTrip(request); !*insecureReached || errors.Is(err, errDestinationNotPublic) {
		t.Fatalf("--insecure no longer relaxes address checks: %v", err)
	}
	redirect, redirectReached := checkedPeerlessTransport(t, "", false)
	request, _ = http.NewRequest(http.MethodGet, "https://registry.example/blob", nil)
	if _, err := redirect.RoundTrip(request); *redirectReached || !errors.Is(err, errDestinationNotPublic) {
		t.Fatalf("Redirect destinations gained the registry exemption: %v", err)
	}
}

func TestDestinationPolicyExplicitProxyHopBypassesCheckedDialer(t *testing.T) {
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Host != "203.0.113.10" {
			http.Error(w, "refused", http.StatusBadGateway)
			return
		}
		io.WriteString(w, "relayed")
	}))
	defer proxy.Close()
	refusedDial := errors.New("checked dialer received the relay address")
	original := &http.Transport{DialContext: func(context.Context, string, string) (net.Conn, error) { return nil, refusedDial }}
	transport, reached := checkedPeerlessTransport(t, "", false)
	transport.Fallback = original
	transport.Environment = func() map[string]string { return map[string]string{"http_proxy": proxy.URL} }
	response, err := (&http.Client{Transport: transport, Timeout: 3 * time.Second}).Get("http://203.0.113.10/blob")
	if err != nil {
		t.Fatalf("A private enterprise relay was refused by the checked dialer: %v", err)
	}
	body, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || string(body) != "relayed" || *reached {
		t.Fatal("The explicit relay did not carry the validated destination")
	}
	request, _ := http.NewRequest(http.MethodGet, "http://10.0.0.1/blob", nil)
	if _, err := transport.RoundTrip(request); !errors.Is(err, errDestinationNotPublic) {
		t.Fatalf("An explicit relay forwarded a non-public destination: %v", err)
	}
}

func TestWrapCheckedKeepsOriginalCheckedDialerWithoutCapability(t *testing.T) {
	t.Setenv("ERGOPTI_OLLAMA_NATIVE_HTTP", "")
	original := &http.Transport{}
	if WrapChecked(original, "https://registry.ollama.ai", false) != http.RoundTripper(original) {
		t.Fatal("An unselected capability replaced the upstream checked transport")
	}
}

func TestValidateRedirectTargetLeavesUnresolvedHostToTheCarrier(t *testing.T) {
	original := lookupAddresses
	t.Cleanup(func() { lookupAddresses = original })
	lookupAddresses = func(_ context.Context, host string) ([]net.IP, error) {
		switch host {
		case "cdn.example":
			return []net.IP{net.ParseIP("8.8.8.8")}, nil
		case "internal.example":
			return []net.IP{net.ParseIP("10.0.0.7")}, nil
		}
		return nil, errors.New("no local DNS")
	}
	const registry = "https://registry.example/v2/blob"
	for target, accepted := range map[string]bool{
		"https://cdn.example/blob":       true,
		"https://pac-only.example/blob":  true,
		"https://203.0.113.10/blob":      true,
		"https://internal.example/blob":  false,
		"https://10.0.0.1/blob":          false,
		"https://127.0.0.1/blob":         false,
		"https://[::1]/blob":             false,
		"https://169.254.169.254/latest": false,
		"https://100.100.2.148/latest":   false,
		"http://cdn.example/blob":        false,
		"ftp://cdn.example/blob":         false,
	} {
		location, _ := url.Parse(target)
		err := ValidateRedirectTarget(context.Background(), location, registry, false)
		if (err == nil) != accepted || err != nil && !errors.Is(err, errRedirectNotAllowed) {
			t.Fatalf("%s accepted=%v diverges from the redirect policy: %v", target, err == nil, err)
		}
	}
	private, _ := url.Parse("https://10.0.0.1/blob")
	if err := ValidateRedirectTarget(context.Background(), private, registry, true); err != nil {
		t.Fatalf("--insecure no longer relaxes the address check: %v", err)
	}
	insecure, _ := url.Parse("http://cdn.example/blob")
	if err := ValidateRedirectTarget(context.Background(), insecure, "http://registry.example", false); err != nil {
		t.Fatalf("An http registry lost its http redirect: %v", err)
	}
	if err := ValidateRedirectTarget(context.Background(), nil, registry, false); !errors.Is(err, errRedirectNotAllowed) {
		t.Fatalf("A missing Location was accepted: %v", err)
	}
}

func TestRedirectPolicyStopsAfterTenHops(t *testing.T) {
	policy := RedirectPolicy("https://registry.example", false)
	request, _ := http.NewRequest(http.MethodGet, "https://8.8.8.8/blob", nil)
	if err := policy(request, make([]*http.Request, maxRedirects-1)); err != nil {
		t.Fatalf("Hop %d was refused: %v", maxRedirects, err)
	}
	if err := policy(request, make([]*http.Request, maxRedirects)); err == nil {
		t.Fatal("The redirect chain was not bounded")
	}
}
