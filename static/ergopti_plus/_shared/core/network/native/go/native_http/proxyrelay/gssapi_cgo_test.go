//go:build cgo && linux

package proxyrelay

import (
	"path/filepath"
	"testing"
)

// The real GSS-API path without a ticket must refuse by name, never prompt or
// crash; CI hosts have no Kerberos ticket.
func TestGSSWithoutATicketIsSignInUnavailable(t *testing.T) {
	t.Setenv("KRB5CCNAME", "FILE:"+filepath.Join(t.TempDir(), "no-ticket"))
	t.Setenv("KRB5_CONFIG", filepath.Join(t.TempDir(), "no-krb5.conf"))
	security, err := newGSSContext("proxy.invalid")
	if err != nil {
		if ReasonOf(err) != RefusalSignInUnavailable {
			t.Fatalf("library refusal %v", err)
		}
		t.Skip("no GSS-API library on this host; the named refusal was checked")
	}
	defer security.Close()
	if _, err := security.Step(nil); ReasonOf(err) != RefusalSignInUnavailable {
		t.Fatalf("step without a ticket = %v", err)
	}
	if !DefaultAuthenticator().Supports(SchemeNegotiate) || DefaultAuthenticator().Supports(SchemeNTLM) {
		t.Fatal("POSIX answers Negotiate only")
	}
	if _, err := DefaultAuthenticator().NewContext(SchemeNTLM, "proxy.invalid"); ReasonOf(err) != RefusalNTLMRequiresWindows {
		t.Fatalf("POSIX NTLM = %v", err)
	}
}
