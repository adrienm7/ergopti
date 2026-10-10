//go:build linux

package nativehttp

import (
	"golang.org/x/sys/unix"
	"net"
)

// Linux is used for ordinary real-socket receiving; it is not Darwin credit.
func listenerGuardian(connection *net.UnixConn, expected int) error {
	raw, err := connection.SyscallConn()
	if err != nil {
		return listenerRefusal()
	}
	var refused bool
	if raw.Control(func(fd uintptr) {
		peer, err := unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
		flags, flagErr := unix.FcntlInt(fd, unix.F_GETFD, 0)
		refused = err != nil || peer == nil || int(peer.Pid) != expected || flagErr != nil || flags&unix.FD_CLOEXEC == 0
	}) != nil || refused {
		return listenerRefusal()
	}
	return nil
}
