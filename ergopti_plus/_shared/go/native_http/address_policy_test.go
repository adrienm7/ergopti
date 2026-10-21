//go:build darwin || linux

package nativehttp

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
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
	transport.Destination = newDestinationPolicy(baseURL, allowPrivate).check
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
	for _, target := range []string{"https://10.0.0.1/blob", "https://169.254.169.254/latest", "https://[::ffff:100.64.0.1]/blob", "https://127.0.0.1:443/blob", "https://mixed.example/blob", "https://empty.example/blob", "https://unresolved.example/blob", "https://public.example/blob"} {
		request, _ := http.NewRequest(http.MethodGet, target, nil)
		_, err := transport.RoundTrip(request)
		var native *Error
		if !errors.As(err, &native) || native.Reason != "connect" || !errors.Is(err, errDestinationNotPublic) || *reached {
			t.Fatalf("%s was not refused before the native worker: %v", target, err)
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
