package proxyrelay

import (
	"encoding/base64"
	"net/http"
	"strings"
)

// SecurityContext is one sign-in exchange with one upstream connection.
type SecurityContext interface {
	// Step consumes the proxy's challenge (nil on the first leg) and returns the
	// next token. It returns a *Refusal when the OS cannot sign in.
	Step(challenge []byte) ([]byte, error)
	// Close releases the OS context.
	Close()
}

// Authenticator opens security contexts with the logged-in user's credentials.
type Authenticator interface {
	// Supports reports whether this OS can answer the scheme without a password.
	Supports(scheme Scheme) bool
	// NewContext opens a context for the proxy host (service HTTP@host).
	NewContext(scheme Scheme, proxyHost string) (SecurityContext, error)
}

// challenge is one parsed Proxy-Authenticate entry the relay can answer.
type challenge struct {
	scheme Scheme
	token  []byte
}

// parseChallenges reads the Proxy-Authenticate values of a 407. A scheme the
// relay does not know (Basic, Digest) is reported through other.
func parseChallenges(header http.Header) (found []challenge, other bool, err error) {
	for _, value := range header.Values("Proxy-Authenticate") {
		// One header line may carry several challenges separated by commas;
		// NTLM and Negotiate never carry parameters, only an optional token.
		for _, part := range strings.Split(value, ",") {
			fields := strings.Fields(strings.TrimSpace(part))
			if len(fields) == 0 {
				continue
			}
			var scheme Scheme
			switch strings.ToLower(fields[0]) {
			case "negotiate":
				scheme = SchemeNegotiate
			case "ntlm":
				scheme = SchemeNTLM
			default:
				if !strings.Contains(fields[0], "=") {
					other = true
				}
				continue
			}
			entry := challenge{scheme: scheme}
			if len(fields) > 1 {
				if len(fields[1]) > MaxChallengeBytes*4/3+4 {
					return nil, other, refuse(RefusalUpstreamProtocol, nil)
				}
				decoded, decodeErr := base64.StdEncoding.DecodeString(fields[1])
				if decodeErr != nil || len(decoded) > MaxChallengeBytes {
					return nil, other, refuse(RefusalUpstreamProtocol, decodeErr)
				}
				entry.token = decoded
			}
			found = append(found, entry)
		}
	}
	return found, other, nil
}

// pick chooses the preferred scheme: Negotiate first, then NTLM. On an OS that
// cannot answer NTLM, an NTLM-only proxy is refused by name.
func pick(found []challenge, auth Authenticator) (Scheme, error) {
	offered := map[Scheme]bool{}
	for _, entry := range found {
		offered[entry.scheme] = true
	}
	for _, scheme := range []Scheme{SchemeNegotiate, SchemeNTLM} {
		if offered[scheme] && auth.Supports(scheme) {
			return scheme, nil
		}
	}
	if offered[SchemeNTLM] {
		return "", refuse(RefusalNTLMRequiresWindows, nil)
	}
	return "", refuse(RefusalUpstreamSchemeUnsupported, nil)
}

// tokenFor returns the challenge token of one scheme, nil when absent.
func tokenFor(found []challenge, scheme Scheme) []byte {
	for _, entry := range found {
		if entry.scheme == scheme {
			return entry.token
		}
	}
	return nil
}
