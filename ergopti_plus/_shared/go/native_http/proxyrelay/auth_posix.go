//go:build !windows

package proxyrelay

// posixAuthenticator signs in with an existing Kerberos ticket through GSS-API.
// NTLM without a password exists only in a Windows logon session.
type posixAuthenticator struct{}

// DefaultAuthenticator is the logged-in user's OS sign-in.
func DefaultAuthenticator() Authenticator { return posixAuthenticator{} }

func (posixAuthenticator) Supports(scheme Scheme) bool { return scheme == SchemeNegotiate }

func (posixAuthenticator) NewContext(scheme Scheme, proxyHost string) (SecurityContext, error) {
	if scheme != SchemeNegotiate {
		return nil, refuse(RefusalNTLMRequiresWindows, nil)
	}
	return newGSSContext(proxyHost)
}
