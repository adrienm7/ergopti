//go:build darwin

package nativehttp

import (
	"golang.org/x/sys/unix"
	"net"
)

// Positive peer process evidence, not path or environment authority. The
// signed guardian supplies the endpoint; original source admission retains it.
func listenerGuardian(connection *net.UnixConn, expected int) error {
	raw, err := connection.SyscallConn()
	if err != nil {
		return listenerRefusal()
	}
	var refused bool
	if raw.Control(func(fd uintptr) {
		pid, err := unix.GetsockoptInt(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERPID)
		flags, flagErr := unix.FcntlInt(fd, unix.F_GETFD, 0)
		refused = err != nil || pid != expected || flagErr != nil || flags&unix.FD_CLOEXEC == 0
	}) != nil || refused {
		return listenerRefusal()
	}
	return nil
}
