//go:build darwin || linux

package nativehttp

import (
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"
)

const listenerTestNonce = "0123456789abcdef0123456789abcdef"
const listenerTestFrame = "V1 LISTENER_BOUND 0123456789abcdef0123456789abcdef\n"

func listenerSocketFixture(t *testing.T, acknowledgement string) (*listenerEvent, net.Listener, <-chan string) {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "ergopti-event-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.Remove(directory); err != nil {
			t.Error(err)
		}
	})
	// Real ordinary Unix sockets. Darwin peer admission is still a distinct native
	// original-owned-child test; this Go fixture's server is the current process.
	path := filepath.Join(directory, "notice")
	server, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := server.Close(); err != nil {
			t.Error(err)
		}
	})
	tcp, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := tcp.Close(); err != nil {
			t.Error(err)
		}
	})
	received := make(chan string, 1)
	go func() {
		connection, err := server.AcceptUnix()
		if err != nil {
			received <- "accept-refused"
			return
		}
		wire, err := io.ReadAll(connection)
		if err != nil {
			received <- "read-refused"
			connection.Close()
			return
		}
		if acknowledgement != "" {
			if n, err := connection.Write([]byte(acknowledgement)); err != nil || n != len(acknowledgement) {
				received <- "write-refused"
				connection.Close()
				return
			}
		}
		if err := connection.Close(); err != nil {
			received <- "close-refused"
			return
		}
		received <- string(wire)
	}()
	return &listenerEvent{path: path, nonce: listenerTestNonce}, tcp, received
}
func listenerSocketSession(ln net.Listener) *Session {
	return &Session{Port: portForTest(ln)}
}
func portForTest(ln net.Listener) string {
	_, port, err := net.SplitHostPort(ln.Addr().String())
	if err != nil {
		return ""
	}
	return port
}
func TestListenerEventRealUnixFrameHalfCloseAndGuardianEOF(t *testing.T) {
	event, listener, received := listenerSocketFixture(t, "")
	if err := event.publish(listener, listenerSocketSession(listener), os.Getpid()); err != nil {
		t.Fatal(err)
	}
	if wire := <-received; wire != listenerTestFrame {
		t.Fatalf("fixed independent frame: %q", wire)
	}
	if !event.attempted || !event.closeAttempted || event.closeErr != nil || event.connection == nil {
		t.Fatal("original connection acquisition/close not retained")
	}
	if _, err := event.connection.Write([]byte("forbidden")); err == nil {
		t.Fatal("closed writer still usable")
	}
}
func TestListenerEventForeignPortCannotAcquireUnixConnection(t *testing.T) {
	event, listener, _ := listenerSocketFixture(t, "")
	if event.publish(listener, &Session{Port: "0"}, os.Getpid()) == nil {
		t.Fatal("foreign listener port accepted")
	}
	if event.connection != nil {
		t.Fatal("refused port acquired a child connection")
	}
}
func TestListenerEventMissingSessionCannotAcquireUnixConnection(t *testing.T) {
	event, listener, _ := listenerSocketFixture(t, "")
	if event.publish(listener, nil, os.Getpid()) == nil {
		t.Fatal("missing original session accepted")
	}
	if event.connection != nil {
		t.Fatal("missing session acquired a child connection")
	}
}
func TestListenerEventForeignGuardianCannotReceiveAnyFrame(t *testing.T) {
	event, listener, received := listenerSocketFixture(t, "")
	if event.publish(listener, listenerSocketSession(listener), os.Getpid()+1) == nil {
		t.Fatal("foreign guardian accepted")
	}
	// Refusal must occur before any private frame, using a real accepted socket.
	if wire := <-received; wire != "" {
		t.Fatalf("foreign guardian received frame: %q", wire)
	}
	if !event.closeAttempted || event.closeErr != nil {
		t.Fatal("refused connection not closed")
	}
}
func TestListenerEventUnexpectedGuardianByteCannotPermitServe(t *testing.T) {
	event, listener, received := listenerSocketFixture(t, "x")
	if event.publish(listener, listenerSocketSession(listener), os.Getpid()) == nil {
		t.Fatal("non-EOF guardian acknowledgement accepted")
	}
	if wire := <-received; wire != listenerTestFrame {
		t.Fatalf("independent frame changed: %q", wire)
	}
	if !event.closeAttempted || event.closeErr != nil {
		t.Fatal("failed receipt connection not closed")
	}
}
func TestListenerEventRepeatedPublicationCannotCreateSuccessor(t *testing.T) {
	event, listener, received := listenerSocketFixture(t, "")
	if event.publish(listener, listenerSocketSession(listener), os.Getpid()) != nil {
		t.Fatal("first owned publication refused")
	}
	if <-received != listenerTestFrame {
		t.Fatal("first fixed frame differs")
	}
	original := event.connection
	if event.publish(listener, listenerSocketSession(listener), os.Getpid()) == nil {
		t.Fatal("repeated publication accepted")
	}
	if event.connection != original {
		t.Fatal("repeated publication allocated a successor")
	}
}
