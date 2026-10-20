package nativehttp

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/url"
	"strings"
)

// Ollama's transfer client refuses registry-named downloads that resolve to a
// non-public address: its checkedDialer validates each resolved address and
// dials the pinned result. The native worker resolves names itself and an
// explicit proxy resolves the destination on its own side, so neither ever
// reaches that dialer. The wrapper therefore repeats the same destination
// decision before either receives the request. It cannot pin the address the
// worker or the proxy dials afterwards; only the Go dialer can.

var errDestinationNotPublic = errors.New("destination is not a public address")

// CGNAT (RFC 6598) carries real internal services such as cloud metadata, and
// the benchmarking block (RFC 2544) is never routed; net.IP classifies neither.
var blockedIPv4Networks = []*net.IPNet{mustParseNetwork("100.64.0.0/10"), mustParseNetwork("198.18.0.0/15")}

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
	}
	return true
}

type destinationPolicy struct {
	exemptHost   string
	allowPrivate bool
}

// newDestinationPolicy exempts only the registry host the caller named, as
// upstream checkedClient does; redirect clients pass an empty base URL.
func newDestinationPolicy(baseURL string, allowPrivate bool) destinationPolicy {
	policy := destinationPolicy{allowPrivate: allowPrivate}
	if base, err := url.Parse(baseURL); baseURL != "" && err == nil {
		policy.exemptHost = base.Hostname()
	}
	return policy
}

func refuseDestination(cause error) error {
	return &Error{Reason: "connect", cause: errors.Join(errDestinationNotPublic, cause)}
}

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
	addresses, err := lookupAddresses(ctx, host)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return refuseDestination(err)
	}
	if len(addresses) == 0 {
		return refuseDestination(nil)
	}
	for _, address := range addresses {
		if !publicAddress(address) {
			return refuseDestination(nil)
		}
	}
	return nil
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
	transport.Destination = newDestinationPolicy(baseURL, allowPrivate).check
	return transport
}
