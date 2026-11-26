package proxyrelay

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
)

// ListenLine is the one JSON line listen prints for its owner: the loopback
// port and the run token the owner hands to the one client it serves.
type ListenLine struct {
	Schema int    `json:"schema"`
	Port   int    `json:"port"`
	Token  string `json:"token"`
}

// Listen serves the relay beside a client its owner starts, for the macOS
// managed daemon whose owner must start the daemon image itself
// (docs/design/proxy-auth-relay.md, "macOS managed daemon"). It prints one
// ListenLine on stdout, the owner's private pipe, then serves until stdin
// reaches EOF: the owner holds the other end, so the relay ends with it, even
// when the owner is killed outright. The token goes to stdout only; it is
// never logged.
func Listen(server *Server, stdin io.Reader, stdout io.Writer) error {
	if stdin == nil || stdout == nil {
		return refuse(RefusalInvalidArguments, nil)
	}
	if err := server.Listen(); err != nil {
		return err
	}
	defer server.Close()
	line, err := json.Marshal(ListenLine{Schema: 1, Port: server.listener.Addr().(*net.TCPAddr).Port, Token: server.Token})
	if err != nil {
		return refuse(RefusalRelayListenFailed, err)
	}
	if _, err := fmt.Fprintln(stdout, string(line)); err != nil {
		// An owner that cannot read the line cannot hand the route over.
		return refuse(RefusalRelayListenFailed, err)
	}
	served := make(chan error, 1)
	go func() { served <- server.Serve() }()
	ended := make(chan struct{})
	go func() {
		// Any byte the owner writes is ignored: only EOF ends the relay.
		io.Copy(io.Discard, stdin)
		close(ended)
	}()
	server.Log("relay_started", "")
	select {
	case err := <-served:
		if err != nil {
			server.Log("relay_stopped", ReasonOf(err))
			return err
		}
	case <-ended:
	}
	server.Log("relay_stopped", "")
	return nil
}
