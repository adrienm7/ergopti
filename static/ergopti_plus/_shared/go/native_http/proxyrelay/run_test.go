package proxyrelay

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"
)

// TestHelperChild is the child Run starts: it connects through the relay URL
// it received, the way the Ollama daemon does.
func TestHelperChild(t *testing.T) {
	if os.Getenv("ERGOPTI_RELAY_HELPER") != "1" {
		t.Skip("helper process")
	}
	proxy, err := url.Parse(os.Getenv("HTTPS_PROXY"))
	if err != nil || proxy.Hostname() != "127.0.0.1" || proxy.User.Username() != RelayUser || os.Getenv("https_proxy") != os.Getenv("HTTPS_PROXY") {
		os.Exit(41)
	}
	if os.Getenv("NO_PROXY") != "kept.example" {
		os.Exit(42)
	}
	password, _ := proxy.User.Password()
	conn, err := net.Dial("tcp", proxy.Host)
	if err != nil {
		os.Exit(43)
	}
	fmt.Fprintf(conn, "CONNECT registry.ollama.ai:443 HTTP/1.1\r\nHost: registry.ollama.ai:443\r\nProxy-Authorization: %s\r\n\r\n", basic(password))
	reader := bufio.NewReader(conn)
	response, err := http.ReadResponse(reader, &http.Request{Method: http.MethodConnect})
	if err != nil || response.StatusCode != http.StatusOK {
		os.Exit(44)
	}
	io.WriteString(conn, "ping")
	echo := make([]byte, 4)
	if _, err := io.ReadFull(reader, echo); err != nil || string(echo) != "ping" {
		os.Exit(45)
	}
	os.Exit(7)
}

func TestRunServesTheChildAndReturnsItsExitCode(t *testing.T) {
	proxy := startFakeProxy(t, "negotiate")
	token, _ := NewToken()
	events := &recorder{}
	server := &Server{Upstream: proxy.upstream(t), Auth: fakeAuth{}, Token: token, Timings: testTimings, Log: events.log}
	t.Setenv("ERGOPTI_RELAY_HELPER", "1")
	t.Setenv("HTTPS_PROXY", proxy.url())
	t.Setenv("NO_PROXY", "kept.example")
	code, err := Run(server, []string{"HTTPS_PROXY", "https_proxy"}, []string{os.Args[0], "-test.run=^TestHelperChild$"})
	if err != nil || code != 7 {
		t.Fatalf("Run = %d %v; events %q", code, err, events.all())
	}
	if got := events.all(); got != "relay_started\nrelay_stopped" {
		t.Fatalf("lifecycle %q", got)
	}
	if strings.Contains(events.all(), token) {
		t.Fatal("token logged")
	}
	if conn, err := net.Dial("tcp", server.listener.Addr().String()); err == nil {
		conn.Close()
		t.Fatal("the listener outlived its child")
	}
}

func TestRunRefusesInvalidRequests(t *testing.T) {
	proxy := startFakeProxy(t, "open")
	token, _ := NewToken()
	for _, c := range []struct {
		variables []string
		command   []string
		reason    string
	}{
		{nil, []string{"true"}, RefusalInvalidArguments},
		{[]string{"HTTPS_PROXY"}, nil, RefusalInvalidArguments},
		{[]string{"BAD=NAME"}, []string{"true"}, RefusalInvalidArguments},
		{[]string{"HTTPS_PROXY"}, []string{"/nonexistent/ergopti-child"}, RefusalChildStartFailed},
	} {
		server := &Server{Upstream: proxy.upstream(t), Auth: fakeAuth{}, Token: token, Timings: testTimings, Log: (&recorder{}).log}
		if _, err := Run(server, c.variables, c.command); ReasonOf(err) != c.reason {
			t.Fatalf("Run(%v, %v) = %v", c.variables, c.command, err)
		}
	}
}

func TestChildEnvironmentReplacesOnlyTheNamedVariables(t *testing.T) {
	got := childEnvironment([]string{"HTTPS_PROXY=http://corp:8080", "NO_PROXY=a", "PATH=/bin"}, []string{"HTTPS_PROXY"}, "http://relay")
	if strings.Join(got, ";") != "NO_PROXY=a;PATH=/bin;HTTPS_PROXY=http://relay" {
		t.Fatalf("environment %v", got)
	}
}
