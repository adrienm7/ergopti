package proxyrelay

import (
	"context"
)

// ProbeResult is the probe's one-line answer.
type ProbeResult struct {
	Status string `json:"status"`
	Scheme string `json:"scheme,omitempty"`
	Reason string `json:"reason,omitempty"`
}

// Probe opens one CONNECT through the upstream. It answers not_needed when the
// proxy demands no NTLM/Negotiate sign-in (any status but 407 is the client's
// to classify), required when it did and the OS sign-in succeeded, so the
// credentials are proven before a client depends on them.
func Probe(ctx context.Context, upstream Upstream, authority string, auth Authenticator, timings Timings) ProbeResult {
	tunnel, err := OpenTunnel(ctx, upstream, authority, auth, timings)
	if err != nil {
		return ProbeResult{Status: ProbeRefused, Reason: ReasonOf(err)}
	}
	if tunnel.Conn != nil {
		tunnel.Conn.Close()
	}
	if tunnel.Scheme == "" {
		return ProbeResult{Status: ProbeNotNeeded}
	}
	return ProbeResult{Status: ProbeRequired, Scheme: string(tunnel.Scheme)}
}
