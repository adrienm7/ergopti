//go:build !windows && !(cgo && (linux || darwin))

package proxyrelay

import "errors"

// newGSSContext has no GSS-API in a build without cgo: the sign-in is named
// unavailable instead of failing later on the proxy.
func newGSSContext(string) (SecurityContext, error) {
	return nil, refuse(RefusalSignInUnavailable, errors.New("gss-api needs a cgo build"))
}
