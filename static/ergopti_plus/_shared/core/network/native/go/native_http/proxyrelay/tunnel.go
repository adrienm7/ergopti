package proxyrelay

import (
	"bufio"
	"context"
	"encoding/base64"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// Upstream is the validated proxy the relay signs in to.
type Upstream struct {
	address string
	host    string
}

// ParseUpstream accepts http://host:port only. A proxy URL with userinfo uses
// Basic, which the client sends itself, so it never needs this relay.
func ParseUpstream(raw string) (Upstream, error) {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme != "http" || parsed.User != nil || parsed.Opaque != "" ||
		(parsed.Path != "" && parsed.Path != "/") || parsed.RawQuery != "" || parsed.Fragment != "" {
		return Upstream{}, refuse(RefusalUpstreamInvalid, err)
	}
	host, port := parsed.Hostname(), parsed.Port()
	number, portErr := strconv.Atoi(port)
	if host == "" || portErr != nil || number < 1 || number > 65535 {
		return Upstream{}, refuse(RefusalUpstreamInvalid, portErr)
	}
	return Upstream{address: net.JoinHostPort(host, port), host: host}, nil
}

// validAuthority accepts host:port with a DNS name or an IP and a valid port.
func validAuthority(authority string) bool {
	host, port, err := net.SplitHostPort(authority)
	if err != nil || host == "" || len(authority) > 300 {
		return false
	}
	number, err := strconv.Atoi(port)
	if err != nil || number < 1 || number > 65535 {
		return false
	}
	if net.ParseIP(host) != nil {
		return true
	}
	for _, r := range host {
		if !(r == '-' || r == '.' || r == '_' || (r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')) {
			return false
		}
	}
	return true
}

// Tunnel is the outcome of one CONNECT through the upstream proxy.
type Tunnel struct {
	// Conn is the open tunnel, nil when the proxy answered Status instead.
	Conn net.Conn
	// Reader holds bytes the proxy sent after its 200 head, if any.
	Reader *bufio.Reader
	// Status is the proxy's final status.
	Status int
	// Scheme is the sign-in the proxy demanded, empty when none was needed.
	Scheme Scheme
}

// boundedReader refuses a response head larger than its budget, so a hostile
// or broken proxy cannot grow the relay's memory.
type boundedReader struct {
	source    io.Reader
	remaining int
}

func (b *boundedReader) Read(p []byte) (int, error) {
	if b.remaining <= 0 {
		return 0, refuse(RefusalUpstreamProtocol, nil)
	}
	if len(p) > b.remaining {
		p = p[:b.remaining]
	}
	n, err := b.source.Read(p)
	b.remaining -= n
	return n, err
}

// connection is one upstream TCP connection and its bounded response reader.
type connection struct {
	conn    net.Conn
	limiter *boundedReader
	reader  *bufio.Reader
}

func dial(ctx context.Context, upstream Upstream, timings Timings) (*connection, error) {
	dialer := net.Dialer{Timeout: timings.Dial}
	conn, err := dialer.DialContext(ctx, "tcp", upstream.address)
	if err != nil {
		if isTimeout(err) {
			return nil, refuse(RefusalUpstreamTimeout, err)
		}
		return nil, refuse(RefusalUpstreamUnreachable, err)
	}
	limiter := &boundedReader{source: conn}
	return &connection{conn: conn, limiter: limiter, reader: bufio.NewReaderSize(limiter, 4096)}, nil
}

func isTimeout(err error) bool {
	var netErr net.Error
	return errors.Is(err, os.ErrDeadlineExceeded) || errors.Is(err, context.DeadlineExceeded) ||
		(errors.As(err, &netErr) && netErr.Timeout())
}

// exchange sends one CONNECT (with an optional sign-in token) and reads the
// response head, draining a 407 body within the body bound.
func (c *connection) exchange(authority string, scheme Scheme, token []byte) (*http.Response, error) {
	var request strings.Builder
	request.WriteString("CONNECT " + authority + " HTTP/1.1\r\nHost: " + authority + "\r\n")
	if token != nil {
		request.WriteString("Proxy-Authorization: " + scheme.Header() + " " + base64.StdEncoding.EncodeToString(token) + "\r\n")
	}
	request.WriteString("Proxy-Connection: Keep-Alive\r\n\r\n")
	if _, err := io.WriteString(c.conn, request.String()); err != nil {
		return nil, classifyIO(err)
	}
	c.limiter.remaining = MaxHeaderBytes
	response, err := http.ReadResponse(c.reader, &http.Request{Method: http.MethodConnect})
	if err != nil {
		return nil, classifyIO(err)
	}
	if response.StatusCode == http.StatusProxyAuthRequired {
		// The body bound replaces the head bound: the 407 page is discarded.
		c.limiter.remaining = MaxBodyBytes + 1
		read, drainErr := io.Copy(io.Discard, io.LimitReader(response.Body, MaxBodyBytes+1))
		response.Body.Close()
		if drainErr != nil {
			return nil, classifyIO(drainErr)
		}
		if read > MaxBodyBytes {
			return nil, refuse(RefusalUpstreamProtocol, nil)
		}
	}
	// A tunnel's bytes are not bounded; only the head was.
	c.limiter.remaining = int(^uint(0) >> 1)
	return response, nil
}

func classifyIO(err error) error {
	var refusal *Refusal
	if errors.As(err, &refusal) {
		return refusal
	}
	if isTimeout(err) {
		return refuse(RefusalUpstreamTimeout, err)
	}
	return refuse(RefusalUpstreamProtocol, err)
}

// settle turns a final non-407 response into the tunnel outcome.
func settle(current *connection, response *http.Response, scheme Scheme) *Tunnel {
	if response.StatusCode/100 != 2 {
		return &Tunnel{Status: response.StatusCode, Scheme: scheme}
	}
	current.conn.SetDeadline(time.Time{})
	return &Tunnel{Conn: current.conn, Reader: current.reader, Status: response.StatusCode, Scheme: scheme}
}

// OpenTunnel opens CONNECT authority through the upstream, answering a 407
// NTLM/Negotiate challenge with the OS credentials. A final status other than
// 2xx and 407 is returned without a connection so the caller passes it on.
func OpenTunnel(ctx context.Context, upstream Upstream, authority string, auth Authenticator, timings Timings) (*Tunnel, error) {
	// A probe never tunnels, so only the dial and handshake deadlines apply.
	if !validAuthority(authority) || timings.Dial <= 0 || timings.Handshake <= 0 {
		return nil, refuse(RefusalInvalidArguments, nil)
	}
	deadline := time.Now().Add(timings.Handshake)
	ctx, cancel := context.WithDeadline(ctx, deadline)
	defer cancel()
	current, err := dial(ctx, upstream, timings)
	if err != nil {
		return nil, err
	}
	keep := false
	defer func() {
		if !keep {
			current.conn.Close()
		}
	}()
	current.conn.SetDeadline(deadline)
	response, err := current.exchange(authority, "", nil)
	if err != nil {
		return nil, err
	}
	if response.StatusCode != http.StatusProxyAuthRequired {
		tunnel := settle(current, response, "")
		keep = tunnel.Conn != nil
		return tunnel, nil
	}
	found, _, err := parseChallenges(response.Header)
	if err != nil {
		return nil, err
	}
	scheme, err := pick(found, auth)
	if err != nil {
		return nil, err
	}
	// No token was sent yet, so a proxy that closes after its first 407 is
	// answered on a new connection; once the exchange started it must stay on
	// this one, because NTLM binds the sign-in to the TCP connection.
	if response.Close {
		current.conn.Close()
		if current, err = dial(ctx, upstream, timings); err != nil {
			return nil, err
		}
		current.conn.SetDeadline(deadline)
	}
	security, err := auth.NewContext(scheme, upstream.host)
	if err != nil {
		return nil, err
	}
	defer security.Close()
	var incoming []byte
	for round := 0; round < MaxAuthRounds; round++ {
		token, stepErr := security.Step(incoming)
		if stepErr != nil {
			return nil, stepErr
		}
		if len(token) == 0 {
			return nil, refuse(RefusalSignInUnavailable, nil)
		}
		response, err = current.exchange(authority, scheme, token)
		if err != nil {
			return nil, err
		}
		if response.StatusCode != http.StatusProxyAuthRequired {
			tunnel := settle(current, response, scheme)
			keep = tunnel.Conn != nil
			return tunnel, nil
		}
		next, _, parseErr := parseChallenges(response.Header)
		if parseErr != nil {
			return nil, parseErr
		}
		incoming = tokenFor(next, scheme)
		// A bare challenge after a token, or a closed connection, means the
		// proxy rejected the sign-in rather than continuing it.
		if incoming == nil || response.Close {
			return nil, refuse(RefusalSignInRejected, nil)
		}
	}
	return nil, refuse(RefusalSignInRejected, nil)
}
