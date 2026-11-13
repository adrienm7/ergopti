package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adrienm7/ergopti/static/ergopti_plus/_shared/go/native_http/proxyrelay"
)

func openProxy(t *testing.T) string {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				if _, err := http.ReadRequest(bufio.NewReader(conn)); err == nil {
					io.WriteString(conn, "HTTP/1.1 200 Connection established\r\n\r\n")
				}
			}()
		}
	}()
	return "http://" + listener.Addr().String()
}

func TestProbePrintsOneJSONLine(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := run([]string{"probe", "--upstream", openProxy(t), "--authority", "registry.ollama.ai:443",
		"--dial-timeout-ms", "1000", "--handshake-timeout-ms", "1000"}, &stdout, &stderr)
	var line map[string]any
	if code != exitOK || json.Unmarshal(stdout.Bytes(), &line) != nil || line["status"] != "not_needed" || line["schema"] != 1.0 {
		t.Fatalf("code %d stdout %q stderr %q", code, stdout.String(), stderr.String())
	}
	if strings.Count(stdout.String(), "\n") != 1 || strings.Contains(stderr.String(), "127.0.0.1") {
		t.Fatalf("stdout %q stderr %q", stdout.String(), stderr.String())
	}
}

func TestInvalidArgumentsExitTwoByName(t *testing.T) {
	proxy := openProxy(t)
	for _, arguments := range [][]string{
		nil,
		{"serve"},
		{"probe", "--upstream", proxy, "--authority", "a:443", "--dial-timeout-ms", "1000"},
		{"probe", "--upstream", proxy, "--dial-timeout-ms", "1000", "--handshake-timeout-ms", "1000"},
		{"probe", "--upstream", "http://user:secret@proxy:8080", "--authority", "a:443", "--dial-timeout-ms", "1", "--handshake-timeout-ms", "1"},
		{"run", "--upstream", proxy, "--dial-timeout-ms", "1", "--handshake-timeout-ms", "1", "--idle-timeout-ms", "1", "--", "true"},
		{"run", "--upstream", proxy, "--variable", "HTTPS_PROXY", "--dial-timeout-ms", "1", "--handshake-timeout-ms", "1", "--", "true"},
		{"probe", "--unknown"},
	} {
		var stdout, stderr bytes.Buffer
		if code := run(arguments, &stdout, &stderr); code != exitInvalidArguments {
			t.Fatalf("%v exited %d", arguments, code)
		}
		if strings.Contains(stderr.String(), "secret") || !strings.Contains(stderr.String(), "relay_refused") {
			t.Fatalf("%v stderr %q", arguments, stderr.String())
		}
	}
}

func TestRefusedProbeExitsThree(t *testing.T) {
	listener, _ := net.Listen("tcp", "127.0.0.1:0")
	address := listener.Addr().String()
	listener.Close()
	var stdout, stderr bytes.Buffer
	code := run([]string{"probe", "--upstream", "http://" + address, "--authority", "a.example:443",
		"--dial-timeout-ms", "500", "--handshake-timeout-ms", "500"}, &stdout, &stderr)
	if code != exitRefused || !strings.Contains(stdout.String(), `"reason":"upstream_unreachable"`) {
		t.Fatalf("code %d stdout %q", code, stdout.String())
	}
}

// The probe line is read by the Lua policy (core/network/engine/proxy_auth_relay_core.lua)
// against the same shared vectors, so both sides of the pipe agree byte for byte.
func TestProbeLineMatchesTheSharedVectors(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "..", "tests", "corpus", "network", "proxy_auth_relay_probe_vectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	var corpus struct {
		Vectors []struct {
			ID       string `json:"id"`
			ExitCode int    `json:"exit_code"`
			Stdout   string `json:"stdout"`
			Result   *struct {
				Status string `json:"status"`
				Scheme string `json:"scheme"`
			} `json:"result"`
			Reason  string `json:"reason"`
			Emitted bool   `json:"emitted"`
		} `json:"vectors"`
	}
	if err := json.Unmarshal(raw, &corpus); err != nil {
		t.Fatal(err)
	}
	emitted := 0
	for _, vector := range corpus.Vectors {
		if !vector.Emitted {
			continue
		}
		emitted++
		result := proxyrelay.ProbeResult{Status: proxyrelay.ProbeRefused, Reason: vector.Reason}
		if vector.Result != nil {
			result = proxyrelay.ProbeResult{Status: vector.Result.Status, Scheme: vector.Result.Scheme}
		}
		var stdout bytes.Buffer
		code := emit(&stdout, result)
		if stdout.String() != vector.Stdout || code != vector.ExitCode {
			t.Fatalf("%s: emitted %q exit %d, vector %q exit %d", vector.ID, stdout.String(), code, vector.Stdout, vector.ExitCode)
		}
	}
	if emitted < 6 {
		t.Fatalf("only %d emitted vectors", emitted)
	}
}
