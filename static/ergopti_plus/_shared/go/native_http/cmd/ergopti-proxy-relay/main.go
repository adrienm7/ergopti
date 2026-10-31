// Command ergopti-proxy-relay is Ergopti's local authenticating relay for
// corporate proxies that demand NTLM or Negotiate
// (docs/design/proxy-auth-relay.md).
//
//	ergopti-proxy-relay probe --upstream URL --authority HOST:PORT --dial-timeout-ms N --handshake-timeout-ms N
//	ergopti-proxy-relay run --upstream URL --variable NAME [--variable NAME...] \
//	    --dial-timeout-ms N --handshake-timeout-ms N --idle-timeout-ms N -- COMMAND [ARGS...]
//
// probe prints one JSON line on stdout. Both log fixed event names and closed
// reasons on stderr, never a URL, host, header or token. Exit codes follow
// proxy_auth_relay.json "exit_codes".
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/adrienm7/ergopti/static/ergopti_plus/_shared/go/native_http/proxyrelay"
)

const (
	exitOK               = 0
	exitInvalidArguments = 2
	exitRefused          = 3
)

type variables []string

func (v *variables) String() string     { return fmt.Sprint(*v) }
func (v *variables) Set(s string) error { *v = append(*v, s); return nil }

func logTo(stream io.Writer) proxyrelay.Logger {
	return func(event, reason string) {
		if reason == "" {
			fmt.Fprintf(stream, "ergopti-proxy-relay: %s\n", event)
			return
		}
		fmt.Fprintf(stream, "ergopti-proxy-relay: %s %s\n", event, reason)
	}
}

func milliseconds(value int) time.Duration { return time.Duration(value) * time.Millisecond }

func main() { os.Exit(run(os.Args[1:], os.Stdout, os.Stderr)) }

func run(arguments []string, stdout, stderr io.Writer) int {
	log := logTo(stderr)
	if len(arguments) == 0 {
		log("relay_refused", proxyrelay.RefusalInvalidArguments)
		return exitInvalidArguments
	}
	mode := arguments[0]
	flags := flag.NewFlagSet(mode, flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	upstreamText := flags.String("upstream", "", "")
	authority := flags.String("authority", "", "")
	dial := flags.Int("dial-timeout-ms", 0, "")
	handshake := flags.Int("handshake-timeout-ms", 0, "")
	idle := flags.Int("idle-timeout-ms", 0, "")
	var names variables
	flags.Var(&names, "variable", "")
	if err := flags.Parse(arguments[1:]); err != nil {
		log("relay_refused", proxyrelay.RefusalInvalidArguments)
		return exitInvalidArguments
	}
	upstream, err := proxyrelay.ParseUpstream(*upstreamText)
	if err != nil {
		log("relay_refused", proxyrelay.ReasonOf(err))
		return exitInvalidArguments
	}
	switch mode {
	case "probe":
		// The probe never tunnels, so it takes no idle deadline.
		timings := proxyrelay.Timings{Dial: milliseconds(*dial), Handshake: milliseconds(*handshake)}
		if *authority == "" || *idle != 0 || len(names) != 0 || flags.NArg() != 0 || *dial <= 0 || *handshake <= 0 {
			log("relay_refused", proxyrelay.RefusalInvalidArguments)
			return exitInvalidArguments
		}
		result := proxyrelay.Probe(context.Background(), upstream, *authority, proxyrelay.DefaultAuthenticator(), timings)
		line, _ := json.Marshal(struct {
			Schema int `json:"schema"`
			proxyrelay.ProbeResult
		}{1, result})
		fmt.Fprintln(stdout, string(line))
		if result.Status == proxyrelay.ProbeRefused {
			log("relay_probe_refused", result.Reason)
			if result.Reason == proxyrelay.RefusalInvalidArguments {
				return exitInvalidArguments
			}
			return exitRefused
		}
		log("relay_probe_"+result.Status, result.Scheme)
		return exitOK
	case "run":
		timings := proxyrelay.Timings{Dial: milliseconds(*dial), Handshake: milliseconds(*handshake), Idle: milliseconds(*idle)}
		if *authority != "" || len(names) == 0 || flags.NArg() == 0 || !timings.Valid() {
			log("relay_refused", proxyrelay.RefusalInvalidArguments)
			return exitInvalidArguments
		}
		token, err := proxyrelay.NewToken()
		if err != nil {
			log("relay_refused", proxyrelay.RefusalRelayListenFailed)
			return exitRefused
		}
		server := &proxyrelay.Server{Upstream: upstream, Auth: proxyrelay.DefaultAuthenticator(),
			Token: token, Timings: timings, Log: log}
		code, err := proxyrelay.Run(server, names, flags.Args())
		if err != nil {
			reason := proxyrelay.ReasonOf(err)
			log("relay_refused", reason)
			if reason == proxyrelay.RefusalInvalidArguments {
				return exitInvalidArguments
			}
			return exitRefused
		}
		return code
	}
	log("relay_refused", proxyrelay.RefusalInvalidArguments)
	return exitInvalidArguments
}
