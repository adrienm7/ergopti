package proxyrelay

import (
	"bufio"
	"context"
	"encoding/base64"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeProxy is an upstream proxy that demands a sign-in, then echoes the
// tunnel's bytes. Each mode is one corporate behaviour.
type fakeProxy struct {
	t        *testing.T
	listener net.Listener
	mode     string
	mu       sync.Mutex
	// connections counts accepted TCP connections; authority is the last CONNECT target.
	connections int
	authority   string
	secrets     []string
}

func startFakeProxy(t *testing.T, mode string) *fakeProxy {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	proxy := &fakeProxy{t: t, listener: listener, mode: mode}
	go proxy.serve()
	t.Cleanup(func() { listener.Close() })
	return proxy
}

func (p *fakeProxy) url() string { return "http://" + p.listener.Addr().String() }

func (p *fakeProxy) upstream(t *testing.T) Upstream {
	upstream, err := ParseUpstream(p.url())
	if err != nil {
		t.Fatal(err)
	}
	return upstream
}

func (p *fakeProxy) serve() {
	for {
		conn, err := p.listener.Accept()
		if err != nil {
			return
		}
		p.mu.Lock()
		p.connections++
		first := p.connections == 1
		p.mu.Unlock()
		go p.handle(conn, first)
	}
}

func reply(conn net.Conn, status int, headers ...string) {
	text := "HTTP/1.1 " + strconv.Itoa(status) + " " + http.StatusText(status) + "\r\n"
	for _, header := range headers {
		text += header + "\r\n"
	}
	body := "<html>sign in</html>"
	if status == http.StatusOK {
		body = ""
		text += "\r\n"
	} else {
		text += "Content-Length: " + strconv.Itoa(len(body)) + "\r\n\r\n" + body
	}
	io.WriteString(conn, text)
}

func encode(text string) string { return base64.StdEncoding.EncodeToString([]byte(text)) }

func (p *fakeProxy) handle(conn net.Conn, first bool) {
	defer conn.Close()
	reader := bufio.NewReader(conn)
	if p.mode == "silent" {
		io.Copy(io.Discard, reader)
		return
	}
	for {
		request, err := http.ReadRequest(reader)
		if err != nil {
			return
		}
		p.mu.Lock()
		p.authority = request.Host
		p.secrets = append(p.secrets, request.Header.Get("Proxy-Authorization"))
		p.mu.Unlock()
		authorization := request.Header.Get("Proxy-Authorization")
		switch p.mode {
		case "open":
			reply(conn, http.StatusOK)
		case "forbidden":
			reply(conn, http.StatusForbidden)
			return
		case "basic":
			reply(conn, http.StatusProxyAuthRequired, `Proxy-Authenticate: Basic realm="corp"`)
			return
		case "ntlm-only", "ntlm", "close-first":
			switch {
			case authorization == "":
				if p.mode == "close-first" && first {
					reply(conn, http.StatusProxyAuthRequired, "Proxy-Authenticate: NTLM", "Connection: close")
					return
				}
				reply(conn, http.StatusProxyAuthRequired, "Proxy-Authenticate: NTLM", "Proxy-Authenticate: Basic realm=\"corp\"")
				continue
			case authorization == "NTLM "+encode("T1"):
				reply(conn, http.StatusProxyAuthRequired, "Proxy-Authenticate: NTLM "+encode("CH"))
				continue
			case authorization == "NTLM "+encode("T3:CH"):
				reply(conn, http.StatusOK)
			default:
				reply(conn, http.StatusProxyAuthRequired, "Proxy-Authenticate: NTLM")
				return
			}
		case "negotiate":
			if authorization == "" {
				reply(conn, http.StatusProxyAuthRequired, "Proxy-Authenticate: Negotiate, NTLM")
				continue
			}
			if authorization != "Negotiate "+encode("KERBEROS") {
				reply(conn, http.StatusProxyAuthRequired, "Proxy-Authenticate: Negotiate")
				return
			}
			reply(conn, http.StatusOK)
		case "reject":
			// Every token is refused with a bare challenge.
			reply(conn, http.StatusProxyAuthRequired, "Proxy-Authenticate: Negotiate")
			continue
		case "huge-header":
			reply(conn, http.StatusProxyAuthRequired, "Proxy-Authenticate: Negotiate", "X-Padding: "+strings.Repeat("a", MaxHeaderBytes))
			return
		case "huge-body":
			io.WriteString(conn, "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Negotiate\r\nContent-Length: "+
				strconv.Itoa(MaxBodyBytes+10)+"\r\n\r\n"+strings.Repeat("b", MaxBodyBytes+10))
			return
		}
		// The tunnel is open: echo bytes until the relay closes.
		io.Copy(conn, reader)
		return
	}
}

// fakeAuth answers Negotiate with one leg and NTLM with two, like Kerberos and
// NTLM do, so the relay's connection discipline is exercised.
type fakeAuth struct {
	ntlm bool
	fail string
}

type fakeContext struct {
	scheme Scheme
	fail   string
	steps  int
}

func (f fakeAuth) Supports(scheme Scheme) bool {
	return scheme == SchemeNegotiate || (f.ntlm && scheme == SchemeNTLM)
}

func (f fakeAuth) NewContext(scheme Scheme, host string) (SecurityContext, error) {
	if host != "127.0.0.1" {
		return nil, refuse(RefusalInvalidArguments, nil)
	}
	return &fakeContext{scheme: scheme, fail: f.fail}, nil
}

func (c *fakeContext) Step(challenge []byte) ([]byte, error) {
	c.steps++
	if c.fail != "" {
		return nil, refuse(c.fail, nil)
	}
	if c.scheme == SchemeNegotiate {
		return []byte("KERBEROS"), nil
	}
	if challenge == nil {
		return []byte("T1"), nil
	}
	return []byte("T3:" + string(challenge)), nil
}

func (c *fakeContext) Close() {}

var testTimings = Timings{Dial: 2 * time.Second, Handshake: 2 * time.Second, Idle: 2 * time.Second}

func TestProbeOutcomes(t *testing.T) {
	cases := []struct {
		mode   string
		auth   fakeAuth
		status string
		scheme string
		reason string
	}{
		{"open", fakeAuth{}, ProbeNotNeeded, "", ""},
		{"forbidden", fakeAuth{}, ProbeNotNeeded, "", ""},
		{"negotiate", fakeAuth{}, ProbeRequired, "negotiate", ""},
		{"ntlm", fakeAuth{ntlm: true}, ProbeRequired, "ntlm", ""},
		{"close-first", fakeAuth{ntlm: true}, ProbeRequired, "ntlm", ""},
		{"ntlm-only", fakeAuth{}, ProbeRefused, "", RefusalNTLMRequiresWindows},
		{"basic", fakeAuth{ntlm: true}, ProbeRefused, "", RefusalUpstreamSchemeUnsupported},
		{"reject", fakeAuth{}, ProbeRefused, "", RefusalSignInRejected},
		{"negotiate", fakeAuth{fail: RefusalSignInUnavailable}, ProbeRefused, "", RefusalSignInUnavailable},
		{"huge-header", fakeAuth{}, ProbeRefused, "", RefusalUpstreamProtocol},
		{"huge-body", fakeAuth{}, ProbeRefused, "", RefusalUpstreamProtocol},
	}
	for _, c := range cases {
		t.Run(c.mode+"/"+c.status, func(t *testing.T) {
			proxy := startFakeProxy(t, c.mode)
			result := Probe(context.Background(), proxy.upstream(t), "registry.ollama.ai:443", c.auth, testTimings)
			if result.Status != c.status || result.Scheme != c.scheme || result.Reason != c.reason {
				t.Fatalf("probe = %+v, want %s %s %s", result, c.status, c.scheme, c.reason)
			}
			if proxy.authority != "registry.ollama.ai:443" {
				t.Fatalf("proxy saw authority %q", proxy.authority)
			}
		})
	}
}

func TestNTLMStaysOnOneConnectionAndReconnectsOnlyBeforeAToken(t *testing.T) {
	ntlm := startFakeProxy(t, "ntlm")
	if result := Probe(context.Background(), ntlm.upstream(t), "example.com:443", fakeAuth{ntlm: true}, testTimings); result.Status != ProbeRequired {
		t.Fatalf("ntlm probe = %+v", result)
	}
	if ntlm.connections != 1 {
		t.Fatalf("NTLM legs used %d connections, want 1", ntlm.connections)
	}
	closing := startFakeProxy(t, "close-first")
	if result := Probe(context.Background(), closing.upstream(t), "example.com:443", fakeAuth{ntlm: true}, testTimings); result.Status != ProbeRequired {
		t.Fatalf("close-first probe = %+v", result)
	}
	if closing.connections != 2 {
		t.Fatalf("a 407 that closes before any token reconnects once: %d connections", closing.connections)
	}
}

func TestProbeDeadlinesAndUnreachable(t *testing.T) {
	silent := startFakeProxy(t, "silent")
	short := Timings{Dial: time.Second, Handshake: 200 * time.Millisecond}
	started := time.Now()
	if result := Probe(context.Background(), silent.upstream(t), "example.com:443", fakeAuth{}, short); result.Reason != RefusalUpstreamTimeout {
		t.Fatalf("silent proxy = %+v", result)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("handshake deadline not enforced: %s", elapsed)
	}
	listener, _ := net.Listen("tcp", "127.0.0.1:0")
	address := listener.Addr().String()
	listener.Close()
	upstream, _ := ParseUpstream("http://" + address)
	if result := Probe(context.Background(), upstream, "example.com:443", fakeAuth{}, short); result.Reason != RefusalUpstreamUnreachable {
		t.Fatalf("closed port = %+v", result)
	}
	if result := Probe(context.Background(), upstream, "bad authority", fakeAuth{}, short); result.Reason != RefusalInvalidArguments {
		t.Fatalf("invalid authority = %+v", result)
	}
}

func TestParseUpstreamRefusesWhatTheRelayCannotOwn(t *testing.T) {
	for _, raw := range []string{"", "https://proxy:8443", "http://user:pass@proxy:8080", "http://proxy",
		"http://proxy:0", "http://proxy:8080/path", "socks5://proxy:1080", "http://proxy:8080?x=1"} {
		if _, err := ParseUpstream(raw); ReasonOf(err) != RefusalUpstreamInvalid {
			t.Fatalf("ParseUpstream(%q) = %v", raw, err)
		}
	}
	if _, err := ParseUpstream("http://proxy.corp.example:8080"); err != nil {
		t.Fatal(err)
	}
}

type recorder struct {
	mu     sync.Mutex
	events []string
}

func (r *recorder) log(event, reason string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, strings.TrimSpace(event+" "+reason))
}

func (r *recorder) all() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return strings.Join(r.events, "\n")
}

func startRelay(t *testing.T, proxy *fakeProxy, auth Authenticator) (*Server, *recorder) {
	t.Helper()
	token, err := NewToken()
	if err != nil {
		t.Fatal(err)
	}
	events := &recorder{}
	server := &Server{Upstream: proxy.upstream(t), Auth: auth, Token: token, Timings: testTimings, Log: events.log}
	if err := server.Listen(); err != nil {
		t.Fatal(err)
	}
	if err := server.Listen(); ReasonOf(err) != RefusalInvalidArguments {
		t.Fatalf("a second Listen must be refused, got %v", err)
	}
	go server.Serve()
	t.Cleanup(server.Close)
	return server, events
}

// connectThrough sends one CONNECT to the relay and returns the status line
// and the open connection.
func connectThrough(t *testing.T, server *Server, authorization string, method string) (string, net.Conn, *bufio.Reader) {
	t.Helper()
	address := server.listener.Addr().String()
	conn, err := net.Dial("tcp", address)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	target := "registry.ollama.ai:443"
	if method != http.MethodConnect {
		target = "http://registry.ollama.ai/"
	}
	request := method + " " + target + " HTTP/1.1\r\nHost: registry.ollama.ai:443\r\n"
	if authorization != "" {
		request += "Proxy-Authorization: " + authorization + "\r\n"
	}
	io.WriteString(conn, request+"\r\n")
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	reader := bufio.NewReader(conn)
	response, err := http.ReadResponse(reader, &http.Request{Method: method})
	if err != nil {
		t.Fatal(err)
	}
	return response.Status, conn, reader
}

func basic(token string) string { return "Basic " + encode(RelayUser+":"+token) }

func TestRelayTunnelsAfterSigningIn(t *testing.T) {
	for _, mode := range []string{"negotiate", "ntlm", "open"} {
		t.Run(mode, func(t *testing.T) {
			proxy := startFakeProxy(t, mode)
			server, events := startRelay(t, proxy, fakeAuth{ntlm: true})
			status, conn, reader := connectThrough(t, server, basic(server.Token), http.MethodConnect)
			if !strings.HasPrefix(status, "200") {
				t.Fatalf("status %q", status)
			}
			io.WriteString(conn, "client-hello")
			echo := make([]byte, len("client-hello"))
			if _, err := io.ReadFull(reader, echo); err != nil || string(echo) != "client-hello" {
				t.Fatalf("tunnel echo %q %v", echo, err)
			}
			for _, secret := range append([]string{server.Token, server.ProxyURL()}, proxy.secrets...) {
				if secret != "" && strings.Contains(events.all(), secret) {
					t.Fatal("a relay log line carries a token or header")
				}
			}
		})
	}
}

func TestRelayRefusesClientsWithoutTheRunToken(t *testing.T) {
	proxy := startFakeProxy(t, "open")
	server, events := startRelay(t, proxy, fakeAuth{})
	other, _ := NewToken()
	for _, authorization := range []string{"", basic(other), "Basic !!!", "Negotiate " + encode("x"), basic(server.Token[:10])} {
		status, _, _ := connectThrough(t, server, authorization, http.MethodConnect)
		if !strings.HasPrefix(status, "407") {
			t.Fatalf("authorization %q got %q", authorization, status)
		}
	}
	if proxy.connections != 0 {
		t.Fatalf("an unauthorized client reached the upstream %d times", proxy.connections)
	}
	if !strings.Contains(events.all(), "relay_client_refused") {
		t.Fatal("client refusal not logged by name")
	}
}

func TestRelayRefusesPlainHTTPAndNamesUpstreamRefusals(t *testing.T) {
	proxy := startFakeProxy(t, "ntlm-only")
	server, events := startRelay(t, proxy, fakeAuth{})
	if status, _, _ := connectThrough(t, server, basic(server.Token), http.MethodGet); !strings.HasPrefix(status, "405") {
		t.Fatalf("plain GET got %q", status)
	}
	address := server.listener.Addr().String()
	conn, _ := net.Dial("tcp", address)
	defer conn.Close()
	io.WriteString(conn, "CONNECT registry.ollama.ai:443 HTTP/1.1\r\nHost: registry.ollama.ai:443\r\nProxy-Authorization: "+basic(server.Token)+"\r\n\r\n")
	response, err := http.ReadResponse(bufio.NewReader(conn), &http.Request{Method: http.MethodConnect})
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusBadGateway || response.Header.Get("X-Ergopti-Relay-Refusal") != RefusalNTLMRequiresWindows {
		t.Fatalf("refusal %d %q", response.StatusCode, response.Header.Get("X-Ergopti-Relay-Refusal"))
	}
	if !strings.Contains(events.all(), "relay_tunnel_refused "+RefusalNTLMRequiresWindows) {
		t.Fatalf("events %q", events.all())
	}
}

func TestRelayClosesAnOversizedClientHead(t *testing.T) {
	proxy := startFakeProxy(t, "open")
	server, _ := startRelay(t, proxy, fakeAuth{})
	conn, _ := net.Dial("tcp", server.listener.Addr().String())
	defer conn.Close()
	io.WriteString(conn, "CONNECT a:443 HTTP/1.1\r\nX: "+strings.Repeat("a", MaxHeaderBytes+10)+"\r\n\r\n")
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	response, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil || response.StatusCode != http.StatusBadRequest {
		t.Fatalf("oversized head: %v %v", response, err)
	}
}

func TestLoopbackPeerOnly(t *testing.T) {
	for _, address := range []net.Addr{
		&net.TCPAddr{IP: net.ParseIP("10.0.0.5"), Port: 1},
		&net.TCPAddr{IP: net.ParseIP("192.168.1.2"), Port: 1},
		&net.TCPAddr{IP: net.ParseIP("::ffff:10.0.0.5"), Port: 1},
		&net.UnixAddr{Name: "x", Net: "unix"},
	} {
		if loopbackPeer(address) {
			t.Fatalf("%v admitted", address)
		}
	}
	for _, address := range []net.Addr{&net.TCPAddr{IP: net.ParseIP("127.0.0.1")}, &net.TCPAddr{IP: net.ParseIP("::1")}} {
		if !loopbackPeer(address) {
			t.Fatalf("%v refused", address)
		}
	}
}

func TestServerRefusesIncompleteConfiguration(t *testing.T) {
	proxy := startFakeProxy(t, "open")
	token, _ := NewToken()
	for _, server := range []*Server{
		{Upstream: proxy.upstream(t), Auth: fakeAuth{}, Token: "short", Timings: testTimings, Log: (&recorder{}).log},
		{Upstream: proxy.upstream(t), Auth: fakeAuth{}, Token: token, Timings: Timings{Dial: 1, Handshake: 1}, Log: (&recorder{}).log},
		{Upstream: proxy.upstream(t), Token: token, Timings: testTimings, Log: (&recorder{}).log},
		{Auth: fakeAuth{}, Token: token, Timings: testTimings, Log: (&recorder{}).log},
	} {
		if err := server.Listen(); ReasonOf(err) != RefusalInvalidArguments {
			t.Fatalf("incomplete server listened: %v", err)
		}
	}
}

func TestParseChallengesBounds(t *testing.T) {
	header := http.Header{}
	header.Add("Proxy-Authenticate", "Negotiate "+base64.StdEncoding.EncodeToString(make([]byte, MaxChallengeBytes+1)))
	if _, _, err := parseChallenges(header); ReasonOf(err) != RefusalUpstreamProtocol {
		t.Fatalf("oversized challenge: %v", err)
	}
	header = http.Header{}
	header.Add("Proxy-Authenticate", "NTLM not-base64!")
	if _, _, err := parseChallenges(header); ReasonOf(err) != RefusalUpstreamProtocol {
		t.Fatalf("invalid challenge: %v", err)
	}
	header = http.Header{}
	header.Add("Proxy-Authenticate", `Digest realm="corp", nonce="x", Negotiate`)
	found, other, err := parseChallenges(header)
	if err != nil || !other || len(found) != 1 || found[0].scheme != SchemeNegotiate {
		t.Fatalf("mixed header: %+v %v %v", found, other, err)
	}
}
