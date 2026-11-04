//go:build !windows

package proxyrelay

import (
	"os"
)

func forward(process *os.Process, received os.Signal) { process.Signal(received) }
