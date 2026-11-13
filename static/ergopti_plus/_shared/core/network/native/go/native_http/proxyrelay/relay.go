package proxyrelay

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"
)

// Logger receives fixed event names and closed reasons only.
type Logger func(event string, reason string)

// Server is the loopback relay. Every field is required.
type Server struct {
	Upstream Upstream
	Auth     Authenticator
	Token    string
	Timings  Timings
	Log      Logger

	listener net.Listener
	mu       sync.Mutex
	closed   bool
}

// NewToken draws the per-run client token.
func NewToken() (string, error) {
	raw := make([]byte, TokenBytes)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw), nil
}

// Listen binds 127.0.0.1 on a random port; the relay never binds another
// address.
func (s *Server) Listen() error {
	if s.Auth == nil || s.Log == nil || len(s.Token) != TokenBytes*2 || !s.Timings.Valid() || s.Upstream.address == "" {
		return refuse(RefusalInvalidArguments, nil)
	}
	if s.listener != nil {
		return refuse(RefusalInvalidArguments, errors.New("relay already listening"))
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return refuse(RefusalRelayListenFailed, err)
	}
	s.listener = listener
	return nil
}

// ProxyURL is the value the child reads as its proxy. It carries the token;
// callers export it to the child environment only and never log it.
func (s *Server) ProxyURL() string {
	port := s.listener.Addr().(*net.TCPAddr).Port
	return "http://" + RelayUser + ":" + s.Token + "@127.0.0.1:" + strconv.Itoa(port)
}

// Serve accepts clients until Close.
func (s *Server) Serve() error {
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			s.mu.Lock()
			closed := s.closed
			s.mu.Unlock()
			if closed {
				return nil
			}
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Timeout() {
				continue
			}
			return refuse(RefusalRelayListenFailed, err)
		}
		go s.handle(conn)
	}
}

// Close stops accepting; open tunnels end on their own close or idle deadline.
func (s *Server) Close() {
	s.mu.Lock()
	s.closed = true
	s.mu.Unlock()
	if s.listener != nil {
		s.listener.Close()
	}
}

// loopbackPeer admits only a loopback client address.
func loopbackPeer(address net.Addr) bool {
	tcp, ok := address.(*net.TCPAddr)
	return ok && tcp.IP.IsLoopback()
}

func writeStatus(conn net.Conn, status int, extra string) {
	io.WriteString(conn, "HTTP/1.1 "+strconv.Itoa(status)+" "+http.StatusText(status)+"\r\n"+extra+
		"Content-Length: 0\r\nConnection: close\r\n\r\n")
}

// authorized checks the client's Basic credentials against the run token in
// constant time.
func (s *Server) authorized(request *http.Request) bool {
	const prefix = "Basic "
	value := request.Header.Get("Proxy-Authorization")
	if len(value) <= len(prefix) || value[:len(prefix)] != prefix {
		return false
	}
	decoded, err := base64.StdEncoding.DecodeString(value[len(prefix):])
	if err != nil {
		return false
	}
	expected := []byte(RelayUser + ":" + s.Token)
	return subtle.ConstantTimeCompare(decoded, expected) == 1
}

func (s *Server) handle(conn net.Conn) {
	defer conn.Close()
	if !loopbackPeer(conn.RemoteAddr()) {
		s.Log("relay_peer_refused", "")
		return
	}
	conn.SetDeadline(time.Now().Add(s.Timings.Handshake))
	limiter := &boundedReader{source: conn, remaining: MaxHeaderBytes}
	reader := bufio.NewReaderSize(limiter, 4096)
	request, err := http.ReadRequest(reader)
	if err != nil {
		writeStatus(conn, http.StatusBadRequest, "")
		return
	}
	if !s.authorized(request) {
		writeStatus(conn, http.StatusProxyAuthRequired, "Proxy-Authenticate: Basic realm=\"ergopti-relay\"\r\n")
		s.Log("relay_client_refused", "")
		return
	}
	if request.Method != http.MethodConnect {
		writeStatus(conn, http.StatusMethodNotAllowed, "")
		s.Log("relay_method_refused", "")
		return
	}
	tunnel, err := OpenTunnel(context.Background(), s.Upstream, request.Host, s.Auth, s.Timings)
	if err != nil {
		reason := ReasonOf(err)
		status := http.StatusBadGateway
		if reason == RefusalUpstreamTimeout {
			status = http.StatusGatewayTimeout
		}
		// The reason is a closed enum value: it names the refusal to the
		// client and carries no secret.
		writeStatus(conn, status, "X-Ergopti-Relay-Refusal: "+reason+"\r\n")
		s.Log("relay_tunnel_refused", reason)
		return
	}
	if tunnel.Conn == nil {
		writeStatus(conn, tunnel.Status, "")
		s.Log("relay_tunnel_status", strconv.Itoa(tunnel.Status))
		return
	}
	defer tunnel.Conn.Close()
	if _, err := io.WriteString(conn, "HTTP/1.1 200 Connection established\r\n\r\n"); err != nil {
		return
	}
	conn.SetDeadline(time.Time{})
	limiter.remaining = int(^uint(0) >> 1)
	splice(conn, reader, tunnel.Conn, tunnel.Reader, s.Timings.Idle)
}

// copyIdle renews its deadlines on each read and write, so a tunnel leg closes
// only after Idle without a byte.
func copyIdle(destination net.Conn, source io.Reader, sourceConn net.Conn, idle time.Duration) {
	buffer := make([]byte, 32*1024)
	for {
		sourceConn.SetReadDeadline(time.Now().Add(idle))
		n, err := source.Read(buffer)
		if n > 0 {
			destination.SetWriteDeadline(time.Now().Add(idle))
			if _, writeErr := destination.Write(buffer[:n]); writeErr != nil {
				return
			}
		}
		if err != nil {
			return
		}
	}
}

func splice(client net.Conn, clientReader io.Reader, upstream net.Conn, upstreamReader io.Reader, idle time.Duration) {
	done := make(chan struct{}, 2)
	go func() {
		copyIdle(upstream, clientReader, client, idle)
		closeWrite(upstream)
		done <- struct{}{}
	}()
	go func() {
		copyIdle(client, upstreamReader, upstream, idle)
		closeWrite(client)
		done <- struct{}{}
	}()
	<-done
	<-done
}

func closeWrite(conn net.Conn) {
	if tcp, ok := conn.(*net.TCPConn); ok {
		tcp.CloseWrite()
		return
	}
	conn.Close()
}
