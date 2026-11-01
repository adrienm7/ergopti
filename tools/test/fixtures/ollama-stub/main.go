// tools/test/fixtures/ollama-stub/main.go

// Command ollama is the stub daemon of the proxy relay end-to-end test: the real
// launcher publishes and starts it under the file name ollama.exe. It answers what
// the launcher and the pull worker read (serve, /api/version, pull, /api/pull) and
// pulls through Go net/http with http.ProxyFromEnvironment, the client the real
// daemon uses, so the relay URL it receives is read the way Ollama would read it.
//
// It can reach no real network and no real Ollama: a direct route is refused, a
// dial to anything but 127.0.0.1 is refused, port 11434 is refused, and TLS is
// accepted only from the certificate digest the test pinned. Its event file carries
// the shape of the proxy variable, never its token.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const (
	forbiddenPort = "11434"
	registryBase  = "https://registry.ollama.ai/v2/library/"
)

func recordEvent(name string, fields map[string]any) {
	path := os.Getenv("ERGOPTI_STUB_EVENTS")
	if path == "" {
		return
	}
	row := map[string]any{"event": name, "pid": os.Getpid(), "ppid": os.Getppid()}
	for key, value := range fields {
		row[key] = value
	}
	line, err := json.Marshal(row)
	if err != nil {
		panic(err)
	}
	file, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		panic(err)
	}
	defer file.Close()
	if _, err := file.Write(append(line, '\n')); err != nil {
		panic(err)
	}
}

// proxyShape names what HTTPS_PROXY is without printing its secret.
func proxyShape() string {
	value := os.Getenv("HTTPS_PROXY")
	if value == "" {
		return "none"
	}
	parsed, err := url.Parse(value)
	if err != nil {
		return "invalid"
	}
	if parsed.User != nil {
		password, _ := parsed.User.Password()
		if parsed.User.Username() == "ergopti" && len(password) == 64 && parsed.Hostname() == "127.0.0.1" {
			return "sign_in_relay"
		}
		return "other_userinfo"
	}
	return "named_proxy"
}

// loopbackPort checks OLLAMA_HOST and returns its address.
func loopbackHost() string {
	host := os.Getenv("OLLAMA_HOST")
	name, port, err := net.SplitHostPort(host)
	if err != nil || name != "127.0.0.1" || port == forbiddenPort {
		fmt.Fprintln(os.Stderr, "Error: the stub refuses this OLLAMA_HOST")
		os.Exit(9)
	}
	return host
}

func registryClient() *http.Client {
	pin := os.Getenv("ERGOPTI_STUB_REGISTRY_SHA256")
	return &http.Client{Transport: &http.Transport{
		Proxy: func(request *http.Request) (*url.URL, error) {
			proxy, err := http.ProxyFromEnvironment(request)
			if err != nil {
				return nil, err
			}
			if proxy == nil {
				return nil, errors.New("the stub refuses a direct registry connection")
			}
			return proxy, nil
		},
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(address)
			if err != nil || host != "127.0.0.1" || port == forbiddenPort {
				return nil, errors.New("the stub refuses a dial outside the loopback proxy")
			}
			return (&net.Dialer{}).DialContext(ctx, network, address)
		},
		TLSClientConfig: &tls.Config{
			// Verified below against the pin: the test CA is not in any store.
			InsecureSkipVerify: true,
			VerifyConnection: func(state tls.ConnectionState) error {
				digest := sha256.Sum256(state.PeerCertificates[0].Raw)
				if hex.EncodeToString(digest[:]) != pin {
					return errors.New("the registry certificate is not the pinned one")
				}
				return nil
			},
		},
	}}
}

// fetch reads one registry resource fully.
func fetch(client *http.Client, address string) ([]byte, error) {
	response, err := client.Get(address)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("registry answered %d", response.StatusCode)
	}
	return io.ReadAll(response.Body)
}

// pull is the daemon's pull: manifest, then every layer, then its digest, whose
// mismatch is worded as Ollama words it, because the callers classify that text.
func pull(model string, emit func(map[string]string)) error {
	name, tag, found := strings.Cut(model, ":")
	if !found {
		tag = "latest"
	}
	client := registryClient()
	emit(map[string]string{"status": "pulling manifest"})
	raw, err := fetch(client, registryBase+name+"/manifests/"+tag)
	if err != nil {
		return fmt.Errorf("pull model manifest: %w", err)
	}
	var manifest struct {
		Layers []struct {
			Digest string `json:"digest"`
		} `json:"layers"`
	}
	if err := json.Unmarshal(raw, &manifest); err != nil {
		return err
	}
	store := filepath.Join(os.Getenv("OLLAMA_MODELS"), "blobs")
	if err := os.MkdirAll(store, 0o700); err != nil {
		return err
	}
	for _, layer := range manifest.Layers {
		blob, err := fetch(client, registryBase+name+"/blobs/"+layer.Digest)
		if err != nil {
			return err
		}
		digest := sha256.Sum256(blob)
		if "sha256:"+hex.EncodeToString(digest[:]) != layer.Digest {
			return errors.New("digest mismatch, file must be downloaded again: want " + layer.Digest)
		}
		target := filepath.Join(store, strings.ReplaceAll(layer.Digest, ":", "-"))
		if err := os.WriteFile(target, blob, 0o600); err != nil {
			return err
		}
	}
	emit(map[string]string{"status": "success"})
	return nil
}

func serve() {
	if os.Getenv("ERGOPTI_STUB_MODE") == "delegate" {
		// The listener would belong to a grandchild: the launcher must refuse it.
		self, err := os.Executable()
		if err != nil {
			panic(err)
		}
		child := exec.Command(self, "serve")
		child.Env = append(os.Environ(), "ERGOPTI_STUB_MODE=plain")
		child.Stdout, child.Stderr = os.Stdout, os.Stderr
		if err := child.Run(); err != nil {
			os.Exit(1)
		}
		return
	}
	host := loopbackHost()
	mux := http.NewServeMux()
	mux.HandleFunc("/api/version", func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		io.WriteString(writer, `{"version":"0.0.0-stub"}`)
	})
	mux.HandleFunc("/api/pull", func(writer http.ResponseWriter, request *http.Request) {
		var body struct {
			Model string `json:"model"`
		}
		if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
			http.Error(writer, err.Error(), http.StatusBadRequest)
			return
		}
		encoder := json.NewEncoder(writer)
		emit := func(row map[string]string) {
			encoder.Encode(row)
			if flusher, ok := writer.(http.Flusher); ok {
				flusher.Flush()
			}
		}
		if err := pull(body.Model, emit); err != nil {
			recordEvent("pull_refused", map[string]any{"error": err.Error()})
			emit(map[string]string{"error": err.Error()})
			return
		}
		recordEvent("pull_succeeded", nil)
	})
	recordEvent("serve", map[string]any{"proxy": proxyShape(), "ollama_host": host,
		"no_cloud": os.Getenv("OLLAMA_NO_CLOUD"), "no_proxy": os.Getenv("NO_PROXY")})
	listener, err := net.Listen("tcp", host)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
	if err := http.Serve(listener, mux); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
}

// pullCommand is the CLI: it asks the daemon on OLLAMA_HOST and prints as Ollama
// prints, an error on stderr as "Error: <text>".
func pullCommand(model string) {
	payload, err := json.Marshal(map[string]string{"model": model})
	if err != nil {
		panic(err)
	}
	response, err := http.Post("http://"+loopbackHost()+"/api/pull", "application/json", bytes.NewReader(payload))
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
	defer response.Body.Close()
	scanner := bufio.NewScanner(response.Body)
	for scanner.Scan() {
		var row map[string]string
		if err := json.Unmarshal(scanner.Bytes(), &row); err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(1)
		}
		if text, failed := row["error"]; failed {
			fmt.Fprintln(os.Stderr, "Error:", text)
			os.Exit(1)
		}
		fmt.Println(row["status"])
	}
}

func main() {
	if len(os.Args) >= 2 && os.Args[1] == "serve" {
		serve()
		return
	}
	if len(os.Args) == 3 && os.Args[1] == "pull" {
		pullCommand(os.Args[2])
		return
	}
	fmt.Fprintln(os.Stderr, "Error: the stub answers serve and pull only")
	os.Exit(2)
}
