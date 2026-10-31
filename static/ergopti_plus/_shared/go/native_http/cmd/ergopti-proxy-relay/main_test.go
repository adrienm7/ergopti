package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
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
