//go:build windows

package proxyrelay

import (
	"os"
	"syscall"
)

// childAttributes keeps the child in the relay's console; the Windows owner
// ends both through its job object.
func childAttributes() *syscall.SysProcAttr { return &syscall.SysProcAttr{} }

// forward ends the child: Windows has no SIGTERM delivery to another process.
func forward(process *os.Process, _ os.Signal) { process.Kill() }
