// Package proxyrelay is Ergopti's loopback relay for corporate proxies that
// demand an NTLM or Negotiate sign-in (docs/design/proxy-auth-relay.md). It
// answers the upstream 407 with the logged-in user's OS credentials and tunnels
// CONNECT without TLS interception. It never stores or asks for a password.
package proxyrelay

import (
	"errors"
	"time"
)

// The closed refusal reasons, mirrored from
// _shared/modules/network/proxy_auth_relay.json "refusals" (contract_test.go).
const (
	RefusalInvalidArguments          = "invalid_arguments"
	RefusalUpstreamInvalid           = "upstream_invalid"
	RefusalUpstreamUnreachable       = "upstream_unreachable"
	RefusalUpstreamTimeout           = "upstream_timeout"
	RefusalUpstreamProtocol          = "upstream_protocol"
	RefusalUpstreamSchemeUnsupported = "upstream_scheme_unsupported"
	RefusalNTLMRequiresWindows       = "ntlm_requires_windows"
	RefusalSignInUnavailable         = "sign_in_unavailable"
	RefusalSignInRejected            = "sign_in_rejected"
	RefusalRelayListenFailed         = "relay_listen_failed"
	RefusalChildStartFailed          = "child_start_failed"
)

// Refusals lists every reason this package can produce. The caller-side
// "relay_unavailable" (binary not installed) is not one of them.
var Refusals = []string{
	RefusalInvalidArguments, RefusalUpstreamInvalid, RefusalUpstreamUnreachable,
	RefusalUpstreamTimeout, RefusalUpstreamProtocol, RefusalUpstreamSchemeUnsupported,
	RefusalNTLMRequiresWindows, RefusalSignInUnavailable, RefusalSignInRejected,
	RefusalRelayListenFailed, RefusalChildStartFailed,
}

// Bounds mirrored from proxy_auth_relay.json "limits" and the identity fields.
const (
	MaxHeaderBytes    = 32768
	MaxBodyBytes      = 65536
	MaxChallengeBytes = 16384
	MaxAuthRounds     = 3
	RelayUser         = "ergopti"
	TokenBytes        = 32
)

// Probe statuses, mirrored from proxy_auth_relay.json "probe_statuses".
const (
	ProbeNotNeeded = "not_needed"
	ProbeRequired  = "required"
	ProbeRefused   = "refused"
)

// Scheme is an upstream proxy sign-in scheme the relay can answer.
type Scheme string

// The schemes in preference order: Negotiate (Kerberos first) before NTLM.
const (
	SchemeNegotiate Scheme = "negotiate"
	SchemeNTLM      Scheme = "ntlm"
)

// Header returns the scheme token as it appears in HTTP auth headers.
func (s Scheme) Header() string {
	if s == SchemeNTLM {
		return "NTLM"
	}
	return "Negotiate"
}

// Refusal is a closed, loggable relay failure: its text is the reason only and
// never a URL, header, token or host.
type Refusal struct {
	Reason string
	cause  error
}

func (r *Refusal) Error() string { return "proxy relay refused: " + r.Reason }

// Unwrap exposes the cause to errors.Is without printing it.
func (r *Refusal) Unwrap() error { return r.cause }

func refuse(reason string, cause error) *Refusal { return &Refusal{Reason: reason, cause: cause} }

// ReasonOf maps any error to its closed reason.
func ReasonOf(err error) string {
	var refusal *Refusal
	if errors.As(err, &refusal) {
		return refusal.Reason
	}
	return RefusalUpstreamProtocol
}

// Timings are the caller's deadlines, read from the timings registry
// (constants.toml [adapters] proxy_relay_*); none has a default here.
type Timings struct {
	Dial      time.Duration
	Handshake time.Duration
	Idle      time.Duration
}

// Valid reports whether every deadline is set.
func (t Timings) Valid() bool { return t.Dial > 0 && t.Handshake > 0 && t.Idle > 0 }
