//go:build linux

package proxyrelay

import "syscall"

// childAttributes ends the child with the relay: a relay killed outright must
// not leave a daemon whose proxy is gone.
func childAttributes() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{Pdeathsig: syscall.SIGTERM}
}
