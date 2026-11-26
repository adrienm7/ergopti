package proxyrelay

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

// TestListenServesUntilItsOwnerClosesStdin plays the macOS owner: it reads the
// one line, tunnels through the relay with the token it carries, then closes
// stdin and expects the relay to end and its port to close.
func TestListenServesUntilItsOwnerClosesStdin(t *testing.T) {
	proxy := startFakeProxy(t, "negotiate")
	token, _ := NewToken()
	events := &recorder{}
	server := &Server{Upstream: proxy.upstream(t), Auth: fakeAuth{}, Token: token, Timings: testTimings, Log: events.log}
	stdinReader, ownerWriter := io.Pipe()
	lineReader, lineWriter := io.Pipe()
	done := make(chan error, 1)
	go func() { done <- Listen(server, stdinReader, lineWriter) }()
	raw, err := bufio.NewReader(lineReader).ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	var line ListenLine
	if err := json.Unmarshal([]byte(raw), &line); err != nil || line.Schema != 1 || line.Port <= 0 || line.Token != token {
		t.Fatalf("line %q", raw)
	}
	if raw != fmt.Sprintf("{\"schema\":1,\"port\":%d,\"token\":\"%s\"}\n", line.Port, token) {
		t.Fatalf("the line is not canonical: %q", raw)
	}
	conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", line.Port))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	fmt.Fprintf(conn, "CONNECT registry.ollama.ai:443 HTTP/1.1\r\nHost: registry.ollama.ai:443\r\nProxy-Authorization: %s\r\n\r\n", basic(line.Token))
	reader := bufio.NewReader(conn)
	response, err := http.ReadResponse(reader, &http.Request{Method: http.MethodConnect})
	if err != nil || response.StatusCode != http.StatusOK {
		t.Fatalf("CONNECT through listen: %v %v", response, err)
	}
	io.WriteString(conn, "ping")
	echo := make([]byte, 4)
	if _, err := io.ReadFull(reader, echo); err != nil || string(echo) != "ping" {
		t.Fatalf("tunnel echo %q %v", echo, err)
	}
	// Bytes before EOF do not end the relay.
	io.WriteString(ownerWriter, "ignored\n")
	select {
	case err := <-done:
		t.Fatalf("listen ended before EOF: %v", err)
	case <-time.After(100 * time.Millisecond):
	}
	ownerWriter.Close()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("listen = %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("listen outlived its owner's stdin")
	}
	if got := events.all(); got != "relay_started\nrelay_stopped" {
		t.Fatalf("lifecycle %q", got)
	}
	if strings.Contains(events.all(), token) {
		t.Fatal("token logged")
	}
	if again, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", line.Port)); err == nil {
		again.Close()
		t.Fatal("the listener outlived its owner")
	}
}

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) { return 0, errors.New("closed") }

func TestListenRefusesWhatItCannotServe(t *testing.T) {
	proxy := startFakeProxy(t, "open")
	token, _ := NewToken()
	valid := func() *Server {
		return &Server{Upstream: proxy.upstream(t), Auth: fakeAuth{}, Token: token, Timings: testTimings, Log: (&recorder{}).log}
	}
	if err := Listen(valid(), nil, io.Discard); ReasonOf(err) != RefusalInvalidArguments {
		t.Fatalf("nil stdin = %v", err)
	}
	short := valid()
	short.Token = "short"
	if err := Listen(short, strings.NewReader(""), io.Discard); ReasonOf(err) != RefusalInvalidArguments {
		t.Fatalf("short token = %v", err)
	}
	unread := valid()
	if err := Listen(unread, strings.NewReader(""), failingWriter{}); ReasonOf(err) != RefusalRelayListenFailed {
		t.Fatalf("unwritable line = %v", err)
	}
	if conn, err := net.Dial("tcp", unread.listener.Addr().String()); err == nil {
		conn.Close()
		t.Fatal("a refused listen kept its port")
	}
}
