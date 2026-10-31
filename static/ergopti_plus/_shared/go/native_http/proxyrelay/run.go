package proxyrelay

import (
	"errors"
	"os"
	"os/exec"
	"os/signal"
	"regexp"
	"runtime"
	"strings"
	"syscall"
)

var variableName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,63}$`)

// childEnvironment replaces every named variable with the relay URL and keeps
// the rest of the parent environment, NO_PROXY included.
func childEnvironment(parent []string, variables []string, proxyURL string) []string {
	named := map[string]bool{}
	for _, name := range variables {
		named[name] = true
	}
	environment := make([]string, 0, len(parent)+len(variables))
	for _, row := range parent {
		name, _, _ := strings.Cut(row, "=")
		if !named[name] {
			environment = append(environment, row)
		}
	}
	for _, name := range variables {
		environment = append(environment, name+"="+proxyURL)
	}
	return environment
}

// Run serves the relay for the lifetime of one child: it starts the child with
// each named variable set to the relay URL, forwards a terminating signal to
// it, and returns the child's exit code once it ends. The listener never
// outlives the child.
func Run(server *Server, variables []string, command []string) (int, error) {
	if len(command) == 0 || len(variables) == 0 {
		return 0, refuse(RefusalInvalidArguments, nil)
	}
	for _, name := range variables {
		if !variableName.MatchString(name) {
			return 0, refuse(RefusalInvalidArguments, nil)
		}
	}
	if err := server.Listen(); err != nil {
		return 0, err
	}
	defer server.Close()
	served := make(chan error, 1)
	go func() { served <- server.Serve() }()
	// Linux delivers Pdeathsig when the forking thread exits, so the thread
	// that starts the child stays locked until the child is reaped.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	child := exec.Command(command[0], command[1:]...)
	child.Env = childEnvironment(os.Environ(), variables, server.ProxyURL())
	child.Stdin, child.Stdout, child.Stderr = os.Stdin, os.Stdout, os.Stderr
	child.SysProcAttr = childAttributes()
	signals := make(chan os.Signal, 2)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(signals)
	if err := child.Start(); err != nil {
		return 0, refuse(RefusalChildStartFailed, err)
	}
	server.Log("relay_started", "")
	waited := make(chan error, 1)
	go func() { waited <- child.Wait() }()
	for {
		select {
		case received := <-signals:
			forward(child.Process, received)
		case err := <-served:
			// The listener failed: the child would lose its proxy, so it is
			// stopped and the run is refused by name.
			if err != nil {
				forward(child.Process, syscall.SIGTERM)
				<-waited
				server.Log("relay_stopped", ReasonOf(err))
				return 0, err
			}
		case err := <-waited:
			server.Log("relay_stopped", "")
			var exit *exec.ExitError
			if errors.As(err, &exit) {
				return exit.ExitCode(), nil
			}
			if err != nil {
				return 0, refuse(RefusalChildStartFailed, err)
			}
			return 0, nil
		}
	}
}
