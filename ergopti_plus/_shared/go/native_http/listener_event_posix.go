//go:build darwin || linux

package nativehttp

import (
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

type listenerEvent struct {
	path, nonce               string
	connection                *net.UnixConn
	attempted, closeAttempted bool
	closeErr                  error
}

var listenerStartup struct {
	sync.Mutex
	attempted bool
	event     *listenerEvent
}

func listenerRefusal() error { return errors.New("Native listener event unavailable") }

// Capture public option scalars only. No FD exists during RunServer/init/GPU
// work: the one new connection is created by publish after that work completes.
func PrepareListenerEvent() error {
	nonce, present := os.LookupEnv("ERGOPTI_OLLAMA_LISTENER_EVENT")
	path, pathPresent := os.LookupEnv("ERGOPTI_OLLAMA_LISTENER_SOCKET")
	if !present && !pathPresent {
		return nil
	}
	if !present || !pathPresent || !lowerHex(nonce, 32) ||
		os.Getenv("ERGOPTI_OLLAMA_NATIVE_HTTP") != "1" ||
		filepath.Base(os.Getenv("ERGOPTI_OLLAMA_NATIVE_SESSION")) != "daemon-"+nonce+".json" ||
		path != filepath.Join("/private/tmp", filepath.Base(filepath.Dir(path)), "notice") ||
		!strings.HasPrefix(filepath.Base(filepath.Dir(path)), "ergopti-listener-") ||
		filepath.Base(path) != "notice" || len(path) >= 104 {
		return listenerRefusal()
	}
	listenerStartup.Lock()
	defer listenerStartup.Unlock()
	if listenerStartup.attempted {
		return listenerRefusal()
	}
	listenerStartup.attempted = true
	listenerStartup.event = &listenerEvent{path: path, nonce: nonce}
	return nil
}
func (event *listenerEvent) close() error {
	if event.closeAttempted {
		return event.closeErr
	}
	event.closeAttempted = true
	if event.connection != nil {
		event.closeErr = event.connection.Close()
	}
	return event.closeErr
}
func CloseListenerEvent() error {
	listenerStartup.Lock()
	defer listenerStartup.Unlock()
	if listenerStartup.event == nil {
		return nil
	}
	return listenerStartup.event.close()
}
func (event *listenerEvent) publish(ln net.Listener, session *Session, guardian int) (result error) {
	if event.attempted || event.closeAttempted || event.connection != nil {
		return listenerRefusal()
	}
	event.attempted = true
	address, ok := ln.Addr().(*net.TCPAddr)
	if !ok || session == nil || address.IP == nil || !address.IP.IsLoopback() ||
		address.Port < 1 || session.Port != strconv.Itoa(address.Port) {
		return listenerRefusal()
	}
	// Darwin Go's sysSocket holds syscall.ForkLock across socket+CloseOnExec.
	// This qualified source path opens no connection before router/cache/GPU init.
	connection, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: event.path, Net: "unix"})
	event.connection = connection
	if err != nil {
		return listenerRefusal()
	}
	defer func() {
		if err := event.close(); result == nil && err != nil {
			result = listenerRefusal()
		}
	}()
	if guardian <= 1 || listenerGuardian(connection, guardian) != nil {
		return listenerRefusal()
	}
	frame := []byte("V1 LISTENER_BOUND " + event.nonce + "\n")
	if count, err := connection.Write(frame); err != nil || count != len(frame) {
		return listenerRefusal()
	}
	// Half-close preserves the peer credential query at guardian's frame EOF.
	if connection.CloseWrite() != nil {
		return listenerRefusal()
	}
	var extra [1]byte
	if count, err := connection.Read(extra[:]); count != 0 || err != io.EOF {
		return listenerRefusal()
	}
	return nil
}
func PublishListenerBound(ln net.Listener) error {
	listenerStartup.Lock()
	defer listenerStartup.Unlock()
	event := listenerStartup.event
	if event == nil {
		return nil
	}
	daemonAdmission.RLock()
	state := daemonAdmission.state
	daemonAdmission.RUnlock()
	if state == nil || state.session == nil {
		return listenerRefusal()
	}
	return event.publish(ln, state.session, os.Getppid())
}
