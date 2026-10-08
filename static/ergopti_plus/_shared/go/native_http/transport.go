// Package nativehttp connects an owned Go request to the signed native HTTP
// worker. Go retains origin authentication, redirects and request cancellation.
package nativehttp

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const maximumFrame = 65536

// Error reports fixed transport evidence without a URL or authentication data.
type Error struct {
	Reason string
	cause  error
}

func (e *Error) Error() string { return "Native HTTP request failed: " + e.Reason }
func (e *Error) Unwrap() error { return e.cause }
func fail(reason string) error { return &Error{Reason: reason} }

type authorityFence struct {
	upstream http.RoundTripper
	foreign  *bool
}

func (f *authorityFence) RoundTrip(request *http.Request) (*http.Response, error) {
	if !*f.foreign {
		return f.upstream.RoundTrip(request)
	}
	copyRequest := request.Clone(request.Context())
	for _, name := range []string{"Authorization", "Proxy-Authorization", "Cookie", "Cookie2"} {
		copyRequest.Header.Del(name)
	}
	return f.upstream.RoundTrip(copyRequest)
}

// Do preserves the original HTTP client's redirect/authentication behavior.
// Its native admission path removes net/http's URL-bearing error wrapper before
// upstream logs can disclose a registry token in a presigned query string.
func Do(client *http.Client, request *http.Request) (*http.Response, error) {
	selected := client
	if os.Getenv("ERGOPTI_OLLAMA_NATIVE_HTTP") == "1" {
		copyClient := *client
		originalRedirect := client.CheckRedirect
		foreign := false
		copyClient.CheckRedirect = func(next *http.Request, via []*http.Request) error {
			if originalRedirect != nil {
				if err := originalRedirect(next, via); err != nil {
					return err
				}
			} else if len(via) >= 10 {
				return fail("protocol")
			}
			for _, previous := range via {
				if previous.URL.Scheme == "https" && next.URL.Scheme != "https" {
					return fail("certificate")
				}
				oldHost, oldPort := hostPort(previous.URL)
				nextHost, nextPort := hostPort(next.URL)
				if previous.URL.Scheme != next.URL.Scheme || oldHost != nextHost || oldPort != nextPort {
					foreign = true
				}
			}
			return nil
		}
		upstream := copyClient.Transport
		if upstream == nil {
			upstream = http.DefaultTransport
		}
		// Filter at the final send boundary: net/http can append cookie-jar
		// values after CheckRedirect. A return to the origin must not restore
		// credentials once this chain crossed a foreign authority.
		copyClient.Transport = &authorityFence{upstream: upstream, foreign: &foreign}
		selected = &copyClient
	}
	response, err := selected.Do(request)
	if err == nil || os.Getenv("ERGOPTI_OLLAMA_NATIVE_HTTP") != "1" {
		return response, err
	}
	var native *Error
	if errors.As(err, &native) {
		return response, &Error{Reason: native.Reason, cause: err}
	}
	if errors.Is(err, context.Canceled) {
		return response, &Error{Reason: "cancelled", cause: err}
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return response, &Error{Reason: "deadline", cause: err}
	}
	return response, &Error{Reason: "connect", cause: err}
}

// Policy contains the shared route fields needed at the native request seam.
// Unknown business fields remain owned by the canonical shared contract.
type Policy struct {
	Version     int                 `json:"schema_version"`
	Orders      map[string][]string `json:"environment_precedence"`
	BypassOrder []string            `json:"environment_bypass_precedence"`
	Loopback    struct {
		Hosts    []string `json:"dns_hosts"`
		Suffixes []string `json:"dns_suffixes"`
		Networks []string `json:"ipv4_cidrs"`
		IPv6     []string `json:"ipv6_addresses"`
	} `json:"loopback"`
}

func readPolicy(path string) (*Policy, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fail("unavailable")
	}
	defer file.Close()
	bytes, err := io.ReadAll(io.LimitReader(file, maximumFrame+1))
	if err != nil || len(bytes) > maximumFrame {
		return nil, fail("protocol")
	}
	var policy Policy
	if json.Unmarshal(bytes, &policy) != nil || policy.Version != 1 || len(policy.Orders["https"]) == 0 || len(policy.Orders["http"]) == 0 || len(policy.BypassOrder) == 0 || len(policy.Loopback.Hosts) == 0 || len(policy.Loopback.Networks) == 0 || len(policy.Loopback.IPv6) == 0 {
		return nil, fail("protocol")
	}
	for _, order := range append([][]string{policy.BypassOrder}, policy.Orders["http"], policy.Orders["https"]) {
		seen := make(map[string]bool)
		for _, name := range order {
			if name == "" || seen[name] || strings.ContainsAny(name, "= \r\n\t\x00") {
				return nil, fail("protocol")
			}
			seen[name] = true
		}
	}
	for _, value := range policy.Loopback.Networks {
		address, _, err := net.ParseCIDR(value)
		if err != nil || address.To4() == nil {
			return nil, fail("protocol")
		}
	}
	for _, value := range policy.Loopback.IPv6 {
		address := net.ParseIP(value)
		if address == nil || address.To4() != nil {
			return nil, fail("protocol")
		}
	}
	return &policy, nil
}

func hostPort(request *url.URL) (string, string) {
	host := strings.TrimSuffix(strings.ToLower(request.Hostname()), ".")
	port := request.Port()
	if port == "" {
		if request.Scheme == "https" {
			port = "443"
		} else {
			port = "80"
		}
	}
	return host, port
}

func (p *Policy) direct(request *url.URL, environment map[string]string) bool {
	host, port := hostPort(request)
	for _, value := range p.Loopback.Hosts {
		if host == value {
			return true
		}
	}
	for _, value := range p.Loopback.Suffixes {
		if strings.HasSuffix(host, value) && len(host) > len(value) {
			return true
		}
	}
	address := net.ParseIP(host)
	if address != nil {
		for _, value := range p.Loopback.IPv6 {
			if address.Equal(net.ParseIP(value)) {
				return true
			}
		}
		for _, value := range p.Loopback.Networks {
			_, network, err := net.ParseCIDR(value)
			if err == nil && network.Contains(address) {
				return true
			}
		}
	}
	bypass := ""
	for _, name := range p.BypassOrder {
		if environment[name] != "" {
			bypass = environment[name]
			break
		}
	}
	for _, value := range strings.Split(bypass, ",") {
		value = strings.TrimSpace(strings.ToLower(value))
		if value == "*" {
			return true
		}
		if _, network, err := net.ParseCIDR(value); err == nil {
			if address != nil && network.Contains(address) {
				return true
			}
			continue
		}
		// Raw IPv6 is an address rather than an ambiguous host:port token.
		if selected := net.ParseIP(value); selected != nil {
			if address != nil && address.Equal(selected) {
				return true
			}
			continue
		}
		selection := value
		if !strings.Contains(selection, "://") {
			selection = "//" + selection
		}
		selected, err := url.Parse(selection)
		if err != nil || selected.User != nil || selected.Hostname() == "" {
			continue
		}
		if selected.Port() != "" && selected.Port() != port {
			continue
		}
		value = strings.TrimLeft(strings.TrimSuffix(selected.Hostname(), "."), "*.")
		if value == "" {
			continue
		}
		if strings.HasPrefix(value, ".") {
			if host == value[1:] || strings.HasSuffix(host, value) && len(host) > len(value) {
				return true
			}
			continue
		}
		if host == value || strings.HasSuffix(host, "."+value) {
			return true
		}
	}
	return false
}

func environmentSnapshot() map[string]string {
	values := make(map[string]string)
	for _, pair := range os.Environ() {
		name, value, found := strings.Cut(pair, "=")
		if found {
			values[name] = value
		}
	}
	return values
}

// Transport is a single native request adapter; it never follows redirects.
// The original Go client sees each response and owns its CheckRedirect policy.
type Transport struct {
	Fallback      http.RoundTripper
	Policy        *Policy
	IdleTimeout   time.Duration
	ResolveWorker func() (string, error)
	Environment   func() map[string]string
}

// Wrap preserves the original client when the caller did not select this
// packaged capability. Enabling it without an actual native worker fails closed.
func Wrap(original http.RoundTripper) http.RoundTripper {
	if original == nil {
		original = http.DefaultTransport
	}
	if os.Getenv("ERGOPTI_OLLAMA_NATIVE_HTTP") != "1" {
		return original
	}
	policy, err := readPolicy(os.Getenv("ERGOPTI_OLLAMA_NETWORK_POLICY"))
	idle, parseErr := strconv.ParseFloat(os.Getenv("ERGOPTI_OLLAMA_NATIVE_HTTP_IDLE_TIMEOUT"), 64)
	if err != nil || parseErr != nil || math.IsNaN(idle) || math.IsInf(idle, 0) || idle <= 0 || idle > float64((1<<63-1)/int64(time.Second)) {
		return unavailableTransport{}
	}
	return &Transport{Fallback: original, Policy: policy, IdleTimeout: time.Duration(idle * float64(time.Second)), ResolveWorker: resolveWorker, Environment: environmentSnapshot}
}

type unavailableTransport struct{}

func (unavailableTransport) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, fail("unavailable")
}

func (t *Transport) RoundTrip(request *http.Request) (*http.Response, error) {
	if request == nil || request.URL == nil || t.Policy == nil || t.Environment == nil || t.ResolveWorker == nil || t.IdleTimeout <= 0 {
		return nil, fail("protocol")
	}
	if request.URL.Scheme != "https" && request.URL.Scheme != "http" || request.URL.User != nil || request.URL.Fragment != "" || request.URL.Hostname() == "" {
		return nil, fail("protocol")
	}
	environment := t.Environment()
	direct := t.Policy.direct(request.URL, environment)
	if !direct {
		for _, name := range t.Policy.Orders[request.URL.Scheme] {
			if selected := environment[name]; selected != "" {
				// Preserve the exact explicit environment choice, including its
				// native Go origin-authentication and original transport settings.
				transport, ok := t.Fallback.(*http.Transport)
				if !ok {
					return t.Fallback.RoundTrip(request)
				}
				relay, err := url.Parse(selected)
				if err != nil || relay.Hostname() == "" {
					return nil, fail("proxy")
				}
				clone := transport.Clone()
				clone.Proxy = http.ProxyURL(relay)
				response, err := clone.RoundTrip(request)
				if err != nil {
					clone.CloseIdleConnections()
					return nil, err
				}
				response.Body = &fallbackBody{ReadCloser: response.Body, transport: clone}
				return response, nil
			}
		}
	}
	if request.Method != http.MethodGet && request.Method != http.MethodHead || request.Body != nil && request.Body != http.NoBody {
		return nil, fail("unavailable")
	}
	worker, err := t.ResolveWorker()
	if err != nil {
		return nil, err
	}
	var timeout *float64
	absolute := "none"
	if deadline, ok := request.Context().Deadline(); ok {
		remaining := time.Until(deadline).Seconds()
		if remaining <= 0 {
			return nil, context.DeadlineExceeded
		}
		timeout = &remaining
		absolute = strconv.FormatFloat(remaining, 'g', -1, 64)
	}
	headers := make([][2]string, 0, len(request.Header)+1)
	for name, values := range request.Header {
		if !strings.EqualFold(name, "accept-encoding") {
			separator := ", "
			if strings.EqualFold(name, "cookie") {
				separator = "; "
			}
			headers = append(headers, [2]string{name, strings.Join(values, separator)})
		}
	}
	headers = append(headers, [2]string{"Accept-Encoding", "identity"})
	input, err := json.Marshal(struct {
		Version int         `json:"version"`
		URL     string      `json:"url"`
		Method  string      `json:"method"`
		Headers [][2]string `json:"headers"`
		Timeout *float64    `json:"timeout"`
		Idle    float64     `json:"idle_timeout"`
		Direct  bool        `json:"direct"`
	}{1, request.URL.String(), request.Method, headers, timeout, t.IdleTimeout.Seconds(), direct})
	if err != nil || len(input) > maximumFrame {
		return nil, fail("protocol")
	}
	command := exec.CommandContext(request.Context(), worker, "--managed-http-worker", strconv.FormatFloat(t.IdleTimeout.Seconds(), 'g', -1, 64), absolute)
	command.Stderr = io.Discard
	stdout, err := command.StdoutPipe()
	if err != nil {
		return nil, fail("unavailable")
	}
	stdin, err := command.StdinPipe()
	if err != nil {
		stdout.Close()
		return nil, fail("unavailable")
	}
	body := &nativeBody{command: command, stream: stdout, reader: bufio.NewReader(stdout), idle: t.IdleTimeout, context: request.Context(), expected: -1}
	if err := command.Start(); err != nil {
		stdin.Close()
		stdout.Close()
		return nil, fail("unavailable")
	}
	body.physicalRetire = track(&nativeHelpers)
	body.timer = time.AfterFunc(t.IdleTimeout, func() {
		if !body.closed.Load() {
			body.timedOut.Store(true)
			command.Process.Kill()
		}
	})
	_, err = stdin.Write(input)
	closeErr := stdin.Close()
	if err != nil || closeErr != nil {
		body.Close()
		return nil, body.failure("protocol")
	}
	tag, payload, err := body.frame()
	if err != nil {
		body.Close()
		return nil, err
	}
	if tag == 'C' {
		err = body.terminal(payload)
		body.Close()
		if err == nil {
			err = fail("protocol")
		}
		return nil, err
	}
	if tag != 'H' {
		body.Close()
		return nil, fail("protocol")
	}
	var metadata struct {
		Version int        `json:"version"`
		Status  int        `json:"status"`
		Headers [][]string `json:"headers"`
	}
	if decodeObject(payload, &metadata, "version", "status", "headers") != nil || metadata.Headers == nil || metadata.Version != 1 || metadata.Status < 100 || metadata.Status > 599 {
		body.Close()
		return nil, fail("protocol")
	}
	response := &http.Response{StatusCode: metadata.Status, Status: strconv.Itoa(metadata.Status) + " " + http.StatusText(metadata.Status), Proto: "HTTP/1.1", ProtoMajor: 1, ProtoMinor: 1, Header: make(http.Header), Body: body, ContentLength: -1, Request: request}
	for _, pair := range metadata.Headers {
		if len(pair) != 2 || !validHeaderName(pair[0]) || strings.ContainsAny(pair[1], "\r\n\x00") {
			body.Close()
			return nil, fail("protocol")
		}
		response.Header.Add(pair[0], pair[1])
	}
	if value := response.Header.Get("Content-Length"); value != "" {
		count, err := strconv.ParseInt(value, 10, 64)
		if err != nil || count < 0 || len(response.Header.Values("Content-Length")) != 1 {
			body.Close()
			return nil, fail("protocol")
		}
		response.ContentLength = count
	}
	if encoding := response.Header.Get("Content-Encoding"); encoding != "" && !strings.EqualFold(encoding, "identity") {
		body.Close()
		return nil, fail("content_encoding")
	}
	body.expected = response.ContentLength
	if request.Method == http.MethodHead {
		body.expected = 0
	}
	if request.Method == http.MethodHead || response.ContentLength == 0 {
		tag, payload, err := body.frame()
		if err == nil && tag == 'C' {
			err = body.terminal(payload)
		} else if err == nil {
			err = fail("protocol")
		}
		if err != nil {
			body.Close()
			return nil, err
		}
	}
	return response, nil
}

type fallbackBody struct {
	io.ReadCloser
	transport *http.Transport
}

func (b *fallbackBody) Close() error {
	err := b.ReadCloser.Close()
	b.transport.CloseIdleConnections()
	return err
}

func validHeaderName(name string) bool {
	if name == "" {
		return false
	}
	for _, character := range name {
		if character >= '0' && character <= '9' || character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || strings.ContainsRune("!#$%&'*+-.^_`|~", character) {
			continue
		}
		return false
	}
	return true
}

type nativeBody struct {
	command        *exec.Cmd
	stream         io.ReadCloser
	reader         *bufio.Reader
	pending        []byte
	idle           time.Duration
	timer          *time.Timer
	timedOut       atomic.Bool
	context        context.Context
	expected       int64
	received       int64
	complete       atomic.Bool
	closed         atomic.Bool
	read           sync.Mutex
	close          sync.Once
	closeError     error
	wait           sync.Once
	waitError      error
	physicalRetire func()
}

func decodeObject(payload []byte, target any, fields ...string) error {
	decoder := json.NewDecoder(strings.NewReader(string(payload)))
	opening, err := decoder.Token()
	if err != nil || opening != json.Delim('{') {
		return fail("protocol")
	}
	seen := make(map[string]bool)
	for decoder.More() {
		key, err := decoder.Token()
		name, ok := key.(string)
		if err != nil || !ok || seen[name] {
			return fail("protocol")
		}
		seen[name] = true
		var value json.RawMessage
		if decoder.Decode(&value) != nil || string(value) == "null" {
			return fail("protocol")
		}
	}
	closing, err := decoder.Token()
	if err != nil || closing != json.Delim('}') || len(seen) != len(fields) {
		return fail("protocol")
	}
	for _, field := range fields {
		if !seen[field] {
			return fail("protocol")
		}
	}
	var extra any
	if !errors.Is(decoder.Decode(&extra), io.EOF) || json.Unmarshal(payload, target) != nil {
		return fail("protocol")
	}
	return nil
}

func (b *nativeBody) failure(reason string) error {
	if b.context.Err() != nil {
		return b.context.Err()
	}
	if deadline, ok := b.context.Deadline(); ok && !time.Now().Before(deadline) {
		return context.DeadlineExceeded
	}
	if b.timedOut.Load() {
		return fail("deadline")
	}
	return fail(reason)
}

func (b *nativeBody) frame() (byte, []byte, error) {
	var size [4]byte
	if _, err := io.ReadFull(b.reader, size[:]); err != nil {
		return 0, nil, b.failure("protocol")
	}
	count := binary.BigEndian.Uint32(size[:])
	if count < 1 || count > maximumFrame {
		return 0, nil, fail("protocol")
	}
	payload := make([]byte, int(count))
	if _, err := io.ReadFull(b.reader, payload); err != nil {
		return 0, nil, b.failure("protocol")
	}
	if b.timer != nil {
		b.timer.Reset(b.idle)
	}
	return payload[0], payload[1:], nil
}

func (b *nativeBody) reap() error {
	b.wait.Do(func() {
		b.waitError = b.command.Wait()
		if b.physicalRetire != nil {
			b.physicalRetire()
		}
	})
	return b.waitError
}

func (b *nativeBody) terminal(payload []byte) error {
	var terminal struct {
		Version int    `json:"version"`
		Success bool   `json:"success"`
		Reason  string `json:"reason"`
	}
	if decodeObject(payload, &terminal, "version", "success", "reason") != nil || terminal.Version != 1 {
		return fail("protocol")
	}
	valid := map[string]bool{"complete": true, "deadline": true, "cancelled": true, "offline": true, "certificate": true, "proxy": true, "connect": true, "unavailable": true, "protocol": true, "content_encoding": true}
	if !valid[terminal.Reason] || terminal.Success != (terminal.Reason == "complete") {
		return fail("protocol")
	}
	if _, err := b.reader.ReadByte(); !errors.Is(err, io.EOF) {
		return b.failure("protocol")
	}
	if err := b.reap(); err != nil && terminal.Success {
		return b.failure("protocol")
	}
	if !terminal.Success {
		return fail(terminal.Reason)
	}
	if b.context.Err() != nil || b.timedOut.Load() {
		return b.failure("deadline")
	}
	if deadline, ok := b.context.Deadline(); ok && !time.Now().Before(deadline) {
		return context.DeadlineExceeded
	}
	b.complete.Store(true)
	b.timer.Stop()
	return nil
}

func (b *nativeBody) Read(output []byte) (int, error) {
	b.read.Lock()
	defer b.read.Unlock()
	if b.closed.Load() {
		return 0, fail("protocol")
	}
	if b.context.Err() != nil {
		b.Close()
		return 0, b.context.Err()
	}
	if len(output) == 0 {
		return 0, nil
	}
	if len(b.pending) == 0 && !b.complete.Load() {
		tag, payload, err := b.frame()
		if err != nil {
			b.Close()
			return 0, err
		}
		if tag == 'C' {
			if err := b.terminal(payload); err != nil {
				b.Close()
				return 0, err
			}
		} else if tag == 'D' && len(payload) > 0 {
			b.received += int64(len(payload))
			if b.expected >= 0 && b.received > b.expected {
				b.Close()
				return 0, fail("protocol")
			}
			// A caller such as io.CopyN can stop at Content-Length. Verify the
			// native terminal and physical exit before publishing the final bytes.
			if b.expected >= 0 && b.received == b.expected {
				tag, terminal, err := b.frame()
				if err == nil && tag == 'C' {
					err = b.terminal(terminal)
				} else if err == nil {
					err = fail("protocol")
				}
				if err != nil {
					b.Close()
					return 0, err
				}
			}
			b.pending = payload
		} else {
			b.Close()
			return 0, fail("protocol")
		}
	}
	if len(b.pending) == 0 && b.complete.Load() {
		if b.expected >= 0 && b.received != b.expected {
			b.Close()
			return 0, fail("protocol")
		}
		return 0, io.EOF
	}
	count := copy(output, b.pending)
	b.pending = b.pending[count:]
	return count, nil
}

func (b *nativeBody) Close() error {
	b.close.Do(func() {
		b.closed.Store(true)
		if b.timer != nil {
			b.timer.Stop()
		}
		if !b.complete.Load() && b.command.Process != nil {
			b.command.Process.Kill()
		}
		b.stream.Close()
		// Concurrent Close calls also wait for this physical successor boundary.
		if err := b.reap(); err != nil && b.complete.Load() {
			b.closeError = b.failure("protocol")
		}
	})
	return b.closeError
}

// Capability identifies a source-qualified native transport build without
// launching a daemon, changing a model store, or contacting a registry.
func Capability() string { return fmt.Sprint("ERGOPTI_OLLAMA_NATIVE_HTTP_V1") }
