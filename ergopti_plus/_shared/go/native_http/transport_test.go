//go:build darwin || linux

package nativehttp

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// The peer is a real owned child, independent of the native implementation.
// It receives private stdin and records its own PID for physical-exit assertions.
func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[1] == "--managed-http-worker" {
		input, _ := io.ReadAll(os.Stdin)
		var request map[string]any
		json.Unmarshal(input, &request)
		request["pid"] = os.Getpid()
		request["argv"] = os.Args[1:]
		record, _ := os.OpenFile(os.Getenv("ERGOPTI_TEST_RECORD"), os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0600)
		json.NewEncoder(record).Encode(request)
		record.Close()
		mode := os.Getenv("ERGOPTI_TEST_PEER")
		frame := func(tag byte, payload string) {
			var length [4]byte
			binary.BigEndian.PutUint32(length[:], uint32(len(payload)+1))
			os.Stdout.Write(length[:])
			os.Stdout.Write(append([]byte{tag}, []byte(payload)...))
		}
		if mode == "stall-header" {
			time.Sleep(10 * time.Second)
			os.Exit(9)
		}
		metadata := `{"version":1,"status":200,"headers":[["Content-Length","5"]]}`
		if mode == "redirect-controlled" && request["url"] == os.Getenv("ERGOPTI_TEST_REDIRECT_FROM") {
			metadata = `{"version":1,"status":302,"headers":[["Location",` + strconv.Quote(os.Getenv("ERGOPTI_TEST_REDIRECT_TO")) + `],["Content-Length","0"]]}`
		} else if mode == "redirect-controlled" && request["url"] == os.Getenv("ERGOPTI_TEST_REDIRECT_SECOND_FROM") {
			metadata = `{"version":1,"status":302,"headers":[["Location",` + strconv.Quote(os.Getenv("ERGOPTI_TEST_REDIRECT_SECOND_TO")) + `],["Content-Length","0"]]}`
		} else if mode == "redirect" && strings.Contains(request["url"].(string), "origin.example") {
			metadata = `{"version":1,"status":302,"headers":[["Location","https://cdn.other.example/blob?q=two"],["Content-Length","0"]]}`
		} else if mode == "unknown-length" || mode == "stall-body" || mode == "cancel-body" {
			metadata = `{"version":1,"status":200,"headers":[]}`
		} else if mode == "duplicate" {
			metadata = `{"version":1,"version":1,"status":200,"headers":[]}`
		} else if mode == "invalid-header" {
			metadata = `{"version":1,"status":200,"headers":[["bad name","x"]]}`
		}
		frame('H', metadata)
		if mode == "stall-body" || mode == "cancel-body" {
			time.Sleep(10 * time.Second)
			os.Exit(9)
		}
		if request["method"] != "HEAD" && !strings.Contains(metadata, `"status":302`) {
			frame('D', "hello")
		}
		if mode == "truncated" {
			os.Exit(0)
		}
		terminal := `{"version":1,"success":true,"reason":"complete"}`
		if mode == "false-terminal" {
			terminal = `{"version":1,"success":false,"reason":"certificate"}`
		} else if mode == "null-terminal" {
			terminal = `{"version":1,"success":null,"reason":"unavailable"}`
		}
		frame('C', terminal)
		if mode == "late-bytes" {
			os.Stdout.Write([]byte("extra"))
		}
		if mode == "wrong-exit" {
			os.Exit(7)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func peerTransport(t *testing.T, mode string) (*Transport, string) {
	t.Helper()
	record := t.TempDir() + "/record.jsonl"
	t.Setenv("ERGOPTI_TEST_PEER", mode)
	t.Setenv("ERGOPTI_TEST_RECORD", record)
	// Race-instrumented Go children otherwise add an artificial one-second
	// exit delay. The receiver tests retain their own native idle/deadline clocks.
	t.Setenv("GORACE", os.Getenv("GORACE")+" atexit_sleep_ms=0")
	policy := &Policy{Orders: map[string][]string{"https": {"https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"}, "http": {"http_proxy", "all_proxy", "ALL_PROXY"}}, BypassOrder: []string{"no_proxy", "NO_PROXY"}}
	policy.Loopback.Hosts = []string{"localhost"}
	policy.Loopback.Suffixes = []string{".localhost"}
	policy.Loopback.Networks = []string{"127.0.0.0/8"}
	policy.Loopback.IPv6 = []string{"::1"}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	return &Transport{Policy: policy, Fallback: http.DefaultTransport, IdleTimeout: time.Second, ResolveWorker: func() (string, error) { return executable, nil }, Environment: func() map[string]string { return map[string]string{} }}, record
}

func records(t *testing.T, path string) []map[string]any {
	t.Helper()
	bytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var records []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(string(bytes)), "\n") {
		var record map[string]any
		if json.Unmarshal([]byte(line), &record) != nil {
			t.Fatal("Invalid peer receipt")
		}
		pid := int(record["pid"].(float64))
		if err := syscall.Kill(pid, 0); !errors.Is(err, syscall.ESRCH) {
			t.Fatalf("Owned native peer %d was not physically reaped: %v", pid, err)
		}
		records = append(records, record)
	}
	return records
}

func TestFullURLPrivateHeadersAndPhysicalCompletion(t *testing.T) {
	transport, record := peerTransport(t, "complete")
	request, _ := http.NewRequest("GET", "https://origin.example/full/path?q=private", nil)
	request.Header.Set("Authorization", "Bearer receiving-test-value")
	response, err := transport.RoundTrip(request)
	if err != nil {
		t.Fatal(err)
	}
	var output strings.Builder
	if _, err := io.CopyN(&output, response.Body, 5); err != nil || output.String() != "hello" {
		t.Fatalf("Final bytes escaped without verified completion: %q %v", output.String(), err)
	}
	response.Body.Close()
	receipt := records(t, record)[0]
	if receipt["url"] != request.URL.String() || strings.Contains(fmtJSON(receipt["argv"]), "origin.example") || strings.Contains(fmtJSON(receipt["argv"]), "receiving-test-value") {
		t.Fatal("Full URL must be on stdin, never argv")
	}
	if !strings.Contains(fmtJSON(receipt["headers"]), "Bearer receiving-test-value") {
		t.Fatal("Original origin authentication was lost")
	}
}

func fmtJSON(value any) string { bytes, _ := json.Marshal(value); return string(bytes) }

func TestWireFailuresCannotPublishFinalBytes(t *testing.T) {
	for _, mode := range []string{"truncated", "false-terminal", "wrong-exit", "late-bytes", "null-terminal", "duplicate", "invalid-header"} {
		t.Run(mode, func(t *testing.T) {
			transport, record := peerTransport(t, mode)
			request, _ := http.NewRequest("GET", "https://example.test/blob", nil)
			response, err := transport.RoundTrip(request)
			if err == nil {
				output, readErr := io.ReadAll(response.Body)
				response.Body.Close()
				if readErr == nil || len(output) != 0 {
					t.Fatalf("Accepted invalid native terminal: %q %v", output, readErr)
				}
			}
			records(t, record)
		})
	}
}

func TestHeadVerifiesTerminalBeforeHeaders(t *testing.T) {
	for _, mode := range []string{"complete", "wrong-exit"} {
		t.Run(mode, func(t *testing.T) {
			transport, record := peerTransport(t, mode)
			request, _ := http.NewRequest("HEAD", "https://example.test/manifest", nil)
			response, err := transport.RoundTrip(request)
			if (err == nil) != (mode == "complete") {
				t.Fatalf("HEAD terminal result %v", err)
			}
			if response != nil {
				response.Body.Close()
			}
			records(t, record)
		})
	}
}

func TestGoRedirectPolicyRetainsFullURLAndStripsForeignAuth(t *testing.T) {
	transport, record := peerTransport(t, "redirect")
	client := &http.Client{Transport: transport}
	request, _ := http.NewRequest("GET", "https://origin.example/manifest?q=one", nil)
	request.Header.Set("Authorization", "Bearer receiving-test-value")
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.ReadAll(response.Body); err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	receipts := records(t, record)
	if len(receipts) != 2 || receipts[1]["url"] != "https://cdn.other.example/blob?q=two" || strings.Contains(fmtJSON(receipts[1]["headers"]), "receiving-test-value") {
		t.Fatal("Go redirect ownership or foreign-authority auth stripping failed")
	}
}

func TestCancellationAndConcurrentClosePhysicallyRetirePeer(t *testing.T) {
	for _, mode := range []string{"stall-header", "cancel-body", "stall-body"} {
		t.Run(mode, func(t *testing.T) {
			transport, record := peerTransport(t, mode)
			transport.IdleTimeout = 200 * time.Millisecond
			context, cancel := context.WithTimeout(context.Background(), 120*time.Millisecond)
			defer cancel()
			request, _ := http.NewRequestWithContext(context, "GET", "https://example.test/blob", nil)
			response, err := transport.RoundTrip(request)
			if response != nil {
				if mode == "cancel-body" {
					cancel()
				}
				_, err = io.ReadAll(response.Body)
				var peers sync.WaitGroup
				for range 4 {
					peers.Add(1)
					go func() { defer peers.Done(); response.Body.Close() }()
				}
				peers.Wait()
			}
			if err == nil {
				t.Fatal("Cancellation accepted")
			}
			records(t, record)
		})
	}
}

func TestBypassIndependentVectors(t *testing.T) {
	transport, _ := peerTransport(t, "complete")
	for _, vector := range []struct {
		host, bypass string
		direct       bool
	}{
		{"127.88.9.2", "", true}, {"[0:0:0:0:0:0:0:1]", "", true}, {"child.localhost", "", true},
		{"corp.example", ".corp.example", true}, {"child.corp.example", "corp.example", true},
		{"outside.example", "corp.example", false}, {"10.1.2.3", "10.0.0.0/8", true},
		{"corp.example:8443", "corp.example:8443", true}, {"corp.example", "corp.example:8443", false},
		{"[2001:db8::1]", "[2001:db8::1]", true}, {"[2001:db8::1]:8443", "[2001:db8::1]:8443", true},
		{"[2001:db8::1]", "[2001:db8::1]:8443", false}, {"[2001:db8::2]", "[2001:db8::1]", false},
		{"[2001:db8::1]", "2001:db8::1", true}, {"[2001:db8::2]", "2001:db8::/32", true},
		{"corp.example", "https://corp.example:443/path", true}, {"corp.example", "http://corp.example:80", false},
		{"corp.example", "https://user:secret@corp.example", false}, {"corp.example", "corp.example:invalid", false},
		{"host.corp.example", "*.corp.example.", true}, {"othercorp.example", ".corp.example", false},
	} {
		request, _ := http.NewRequest("GET", "https://"+vector.host+"/a", nil)
		if actual := transport.Policy.direct(request.URL, map[string]string{"no_proxy": vector.bypass}); actual != vector.direct {
			t.Fatal("Bypass mismatch", vector.host, strconv.FormatBool(actual))
		}
	}
}

func TestIdleDeadlinePhysicallyRetiresPeer(t *testing.T) {
	transport, record := peerTransport(t, "stall-body")
	transport.IdleTimeout = 100 * time.Millisecond
	request, _ := http.NewRequest("GET", "https://example.test/blob", nil)
	response, err := transport.RoundTrip(request)
	if err != nil {
		t.Fatal(err)
	}
	_, err = io.ReadAll(response.Body)
	response.Body.Close()
	var evidence *Error
	if !errors.As(err, &evidence) || evidence.Reason != "deadline" {
		t.Fatalf("Missing native idle deadline evidence: %v", err)
	}
	records(t, record)
}

func TestUnknownLengthRequiresTerminalAndExactEOF(t *testing.T) {
	transport, record := peerTransport(t, "unknown-length")
	request, _ := http.NewRequest("GET", "https://example.test/blob", nil)
	response, err := transport.RoundTrip(request)
	if err != nil {
		t.Fatal(err)
	}
	output, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || string(output) != "hello" {
		t.Fatalf("Unknown-length response failed: %q %v", output, err)
	}
	records(t, record)
}

func TestClientErrorPrivacyRetainsContextCause(t *testing.T) {
	t.Setenv("ERGOPTI_OLLAMA_NATIVE_HTTP", "1")
	transport, record := peerTransport(t, "stall-header")
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	request, _ := http.NewRequestWithContext(ctx, "GET", "https://example.test/private?token=receiving-test-secret", nil)
	_, err := Do(&http.Client{Transport: transport}, request)
	if err == nil || strings.Contains(err.Error(), "example.test") || strings.Contains(err.Error(), "receiving-test-secret") || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Privacy or original context semantics were lost: %v", err)
	}
	records(t, record)
}

func TestManagedRedirectStrictAuthorityAndDowngrade(t *testing.T) {
	for _, vector := range []struct {
		target            string
		stripped, refused bool
	}{
		{"https://origin.example/blob?q=two", false, false},
		{"https://origin.example:443/blob?q=two", false, false},
		{"https://origin.example:444/blob?q=two", true, false},
		{"https://asset.origin.example/blob?q=two", true, false},
		{"https://foreign.example/blob?q=two", true, false},
		{"http://origin.example/blob?q=two", true, true},
	} {
		t.Run(vector.target, func(t *testing.T) {
			transport, record := peerTransport(t, "redirect-controlled")
			t.Setenv("ERGOPTI_OLLAMA_NATIVE_HTTP", "1")
			t.Setenv("ERGOPTI_TEST_REDIRECT_FROM", "https://origin.example/manifest?q=one")
			t.Setenv("ERGOPTI_TEST_REDIRECT_TO", vector.target)
			request, _ := http.NewRequest("GET", "https://origin.example/manifest?q=one", nil)
			request.Header.Set("Authorization", "Bearer independent-receiving-secret")
			request.Header.Set("Cookie", "owned=independent-receiving-cookie")
			callbackCalls := 0
			client := &http.Client{Transport: transport, CheckRedirect: func(next *http.Request, _ []*http.Request) error {
				callbackCalls++
				next.Header.Set("Authorization", request.Header.Get("Authorization"))
				return nil
			}}
			response, err := Do(client, request)
			if vector.refused {
				if err == nil {
					t.Fatal("HTTPS downgrade admitted")
				}
			} else {
				if err != nil {
					t.Fatal(err)
				}
				if _, err := io.ReadAll(response.Body); err != nil {
					t.Fatal(err)
				}
				response.Body.Close()
			}
			if response != nil {
				response.Body.Close()
			}
			if callbackCalls != 1 {
				t.Fatal("Original redirect hook not preserved")
			}
			observed := records(t, record)
			if vector.refused {
				if len(observed) != 1 {
					t.Fatal("Downgraded request reached native peer")
				}
			} else {
				if len(observed) != 2 || observed[1]["url"] != vector.target {
					t.Fatal("Full redirect URL changed")
				}
				forwarded := strings.Contains(fmtJSON(observed[1]["headers"]), "independent-receiving-secret")
				cookie := strings.Contains(fmtJSON(observed[1]["headers"]), "independent-receiving-cookie")
				if forwarded == vector.stripped || cookie == vector.stripped {
					t.Fatal("Strict authority authentication/cookie policy changed")
				}
			}
		})
	}
}

func TestManagedRedirectKeepsOriginalVeto(t *testing.T) {
	transport, record := peerTransport(t, "redirect-controlled")
	t.Setenv("ERGOPTI_OLLAMA_NATIVE_HTTP", "1")
	t.Setenv("ERGOPTI_TEST_REDIRECT_FROM", "https://origin.example/manifest")
	t.Setenv("ERGOPTI_TEST_REDIRECT_TO", "https://origin.example/blob")
	request, _ := http.NewRequest("GET", "https://origin.example/manifest", nil)
	veto := errors.New("independent caller veto")
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return veto }}
	response, err := Do(client, request)
	if response != nil {
		response.Body.Close()
	}
	if !errors.Is(err, veto) || len(records(t, record)) != 1 {
		t.Fatal("Original redirect veto changed")
	}
}

type independentReceivingCookieJar struct{}

func (independentReceivingCookieJar) Cookies(*url.URL) []*http.Cookie {
	return []*http.Cookie{{Name: "owned", Value: "independent-jar-secret"}}
}
func (independentReceivingCookieJar) SetCookies(*url.URL, []*http.Cookie) {}

func TestManagedRedirectReturnToOriginDoesNotRestoreHeaderOrJarSecrets(t *testing.T) {
	transport, record := peerTransport(t, "redirect-controlled")
	t.Setenv("ERGOPTI_OLLAMA_NATIVE_HTTP", "1")
	t.Setenv("ERGOPTI_TEST_REDIRECT_FROM", "https://origin.example/manifest")
	t.Setenv("ERGOPTI_TEST_REDIRECT_TO", "https://foreign.example/redirect")
	t.Setenv("ERGOPTI_TEST_REDIRECT_SECOND_FROM", "https://foreign.example/redirect")
	t.Setenv("ERGOPTI_TEST_REDIRECT_SECOND_TO", "https://origin.example/blob")
	request, _ := http.NewRequest("GET", "https://origin.example/manifest", nil)
	request.Header.Set("Authorization", "Bearer independent-header-secret")
	request.Header.Set("Proxy-Authorization", "Basic independent-proxy-secret")
	client := &http.Client{Transport: transport, Jar: independentReceivingCookieJar{}}
	response, err := Do(client, request)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.ReadAll(response.Body); err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	observed := records(t, record)
	if len(observed) != 3 {
		t.Fatal("Actual owned redirect chain changed")
	}
	if !strings.Contains(fmtJSON(observed[0]["headers"]), "independent-jar-secret") {
		t.Fatal("Origin cookie jar behavior changed")
	}
	for _, next := range observed[1:] {
		for _, secret := range []string{"independent-header-secret", "independent-proxy-secret", "independent-jar-secret"} {
			if strings.Contains(fmtJSON(next["headers"]), secret) {
				t.Fatal("Foreign/return chain restored a credential")
			}
		}
	}
}
