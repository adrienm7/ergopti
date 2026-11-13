//go:build !linux && !windows

package proxyrelay

import "syscall"

// childAttributes has no parent-death signal outside Linux; the owner stops
// the relay with a signal it forwards, or kills its process group.
func childAttributes() *syscall.SysProcAttr { return &syscall.SysProcAttr{} }
