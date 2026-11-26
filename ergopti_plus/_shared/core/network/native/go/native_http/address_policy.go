package nativehttp

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Ollama's transfer client refuses registry-named downloads that resolve to a
// non-public address: its checkedDialer validates each resolved address and
// dials the pinned result. The native worker resolves names itself and an
// explicit proxy resolves the destination on its own side, so neither ever
// reaches that dialer. The wrapper therefore repeats the same destination
// decision before either receives the request. It cannot pin the address the
// worker or the proxy dials afterwards; only the Go dialer can.

var errDestinationNotPublic = errors.New("destination is not a public address")

// net.IP.IsGlobalUnicast accepts special-use ranges that are not globally
// reachable. These are upstream's lists (Ollama 0.40.6 transfer/redirect.go,
// from the IANA special-purpose registries): CGNAT carries real internal
// services such as cloud metadata, the others are never routed publicly.
var blockedIPv4Networks = []*net.IPNet{
	mustParseNetwork("0.0.0.0/8"),
	mustParseNetwork("100.64.0.0/10"),
	mustParseNetwork("192.0.0.0/24"),
	mustParseNetwork("192.0.2.0/24"),
	mustParseNetwork("192.88.99.0/24"),
	mustParseNetwork("198.18.0.0/15"),
	mustParseNetwork("198.51.100.0/24"),
	mustParseNetwork("203.0.113.0/24"),
	mustParseNetwork("240.0.0.0/4"),
}

// Global IPv6 unicast is 2000::/3; its special-purpose and transition blocks
// stay refused.
var (
	publicIPv6Network   = mustParseNetwork("2000::/3")
	blockedIPv6Networks = []*net.IPNet{
		mustParseNetwork("2001::/23"),
		mustParseNetwork("2001:db8::/32"),
		mustParseNetwork("2002::/16"),
		mustParseNetwork("3ffe::/16"),
		mustParseNetwork("3fff::/20"),
	}
)

func mustParseNetwork(value string) *net.IPNet {
	_, network, err := net.ParseCIDR(value)
	if err != nil {
		panic(err)
	}
	return network
}

// lookupAddresses is replaced only by tests that must not depend on DNS.
var lookupAddresses = func(ctx context.Context, host string) ([]net.IP, error) {
	return net.DefaultResolver.LookupIP(ctx, "ip", host)
}

// publicAddress mirrors upstream isPublicIP, including 4-in-6 mapped forms.
func publicAddress(address net.IP) bool {
	if !address.IsGlobalUnicast() || address.IsLoopback() || address.IsPrivate() || address.IsLinkLocalUnicast() || address.IsLinkLocalMulticast() || address.IsUnspecified() {
		return false
	}
	if v4 := address.To4(); v4 != nil {
		for _, network := range blockedIPv4Networks {
			if network.Contains(v4) {
				return false
			}
		}
		return true
	}
	if !publicIPv6Network.Contains(address) {
		return false
	}
	for _, network := range blockedIPv6Networks {
		if network.Contains(address) {
			return false
		}
	}
	return true
}

type destinationPolicy struct {
	exemptHost   string
	allowPrivate bool
	policy       *Policy
}

// newDestinationPolicy exempts only the registry host the caller named, as
// upstream checkedClient does; redirect clients pass an empty base URL. The
// network policy, when known, names the loopback hosts that never need DNS.
func newDestinationPolicy(baseURL string, allowPrivate bool, policy *Policy) destinationPolicy {
	result := destinationPolicy{allowPrivate: allowPrivate, policy: policy}
	if base, err := url.Parse(baseURL); baseURL != "" && err == nil {
		result.exemptHost = base.Hostname()
	}
	return result
}

func refuseDestination(cause error) error {
	return &Error{Reason: "connect", cause: errors.Join(errDestinationNotPublic, cause)}
}

// check decides a destination that a proxy or the native worker will carry.
// Both resolve the name on their own side, which a PAC-only network keeps out
// of reach of local DNS, so a name this machine cannot resolve is left to the
// carrier. A literal address, a loopback name and a name that resolves locally
// to any non-public address stay refused.
func (p destinationPolicy) check(ctx context.Context, target *url.URL) error {
	if p.allowPrivate {
		return nil
	}
	host := target.Hostname()
	if p.exemptHost != "" && strings.EqualFold(host, p.exemptHost) {
		return nil
	}
	if address := net.ParseIP(host); address != nil {
		if !publicAddress(address) {
			return refuseDestination(nil)
		}
		return nil
	}
	if p.policy != nil && p.policy.loopbackName(strings.TrimSuffix(strings.ToLower(host), ".")) {
		return refuseDestination(nil)
	}
	addresses, err := lookupAddresses(ctx, host)
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if err != nil {
		return nil
	}
	for _, address := range addresses {
		if !publicAddress(address) {
			return refuseDestination(nil)
		}
	}
	return nil
}

var errRedirectNotAllowed = errors.New("redirect target not allowed")

// ValidateRedirectTarget replaces upstream transfer.ValidateRedirectTarget on
// the blob download path. Upstream refuses a redirect whose host fails a local
// lookup, which rejected every pull on a network where only the proxy resolves
// the download host. The scheme rules and the refusal of non-public addresses
// are upstream's; the request itself is checked again by WrapChecked.
func ValidateRedirectTarget(ctx context.Context, location *url.URL, baseURL string, allowPrivate bool) error {
	if location == nil {
		return errors.Join(errRedirectNotAllowed, errors.New("missing Location"))
	}
	if allowPrivate {
		return nil
	}
	if location.Scheme != "https" && location.Scheme != "http" {
		return errors.Join(errRedirectNotAllowed, errors.New("unsupported scheme"))
	}
	// http is acceptable only when the registry itself was reached over http.
	if base, err := url.Parse(baseURL); location.Scheme == "http" && err == nil && base.Scheme == "https" {
		return errors.Join(errRedirectNotAllowed, errors.New("https registry redirecting to http"))
	}
	if err := newDestinationPolicy("", false, nil).check(ctx, location); err != nil {
		return errors.Join(errRedirectNotAllowed, err)
	}
	return nil
}

// maxRedirects is upstream NewRedirectClient's hop limit.
const maxRedirects = 10

// RedirectPolicy is the CheckRedirect of upstream NewRedirectClient with the
// target validation above.
func RedirectPolicy(baseURL string, allowPrivate bool) func(*http.Request, []*http.Request) error {
	return func(request *http.Request, via []*http.Request) error {
		if len(via) >= maxRedirects {
			return errors.New("stopped after 10 redirects")
		}
		return ValidateRedirectTarget(request.Context(), request.URL, baseURL, allowPrivate)
	}
}

// WrapChecked wraps a transport whose upstream dialer refuses non-public
// destinations. Without the packaged capability the original transport, and
// therefore its checked dialer, stays in place unchanged.
func WrapChecked(original http.RoundTripper, baseURL string, allowPrivate bool) http.RoundTripper {
	wrapped := Wrap(original)
	transport, ok := wrapped.(*Transport)
	if !ok {
		return wrapped
	}
	checkTransport(transport, baseURL, allowPrivate)
	return transport
}

// checkTransport gives a wrapped transport the checked dialer's destination
// decision and a relay hop that keeps the bootstrap's relay and TLS anchors.
func checkTransport(transport *Transport, baseURL string, allowPrivate bool) {
	transport.Destination = newDestinationPolicy(baseURL, allowPrivate, transport.Policy).check
	if _, plain := transport.Fallback.(*http.Transport); !plain {
		// Since 0.40.6 upstream's checked client is its own RoundTripper,
		// which picks a relay from the process environment and drops the
		// bootstrap's relay and TLS anchors. The destination is decided
		// above, so the explicit relay hop uses upstream's transfer transport
		// settings on a plain dialer instead.
		transport.Fallback = transferTransport()
	}
}

// transferTransport repeats upstream newTransferTransport's settings.
func transferTransport() *http.Transport {
	return &http.Transport{
		DialContext:         (&net.Dialer{Timeout: 30 * time.Second, KeepAlive: 3 * time.Minute}).DialContext,
		MaxIdleConns:        100,
		MaxIdleConnsPerHost: 100,
		IdleConnTimeout:     90 * time.Second,
		ForceAttemptHTTP2:   true,
	}
}
