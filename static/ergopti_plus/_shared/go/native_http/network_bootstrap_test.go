//go:build darwin || linux

package nativehttp

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func bootstrapLiteral() ([]byte, *Session, []byte, bootstrapStore) {
	session := &Session{Version: 1, Token: strings.Repeat("01", 32), SourceCommit: strings.Repeat("a", 40), BinarySHA256: strings.Repeat("b", 64), AssetSHA256: strings.Repeat("c", 64), Device: "1", Inode: "2", Port: "11434"}
	bytes, _ := json.Marshal(session)
	payload := []byte(`{"environment":[["https_proxy","http://user:private-value@relay.example:8080"]],"store":{"mode":"environment","value":"../outside models","cwd":"/original/work"},"idle_timeout_ms":60000}`)
	return bytes, session, payload, bootstrapStore{Mode: "environment", Value: "../outside models", CWD: "/original/work"}
}

// This independent transcript uses a literal domain and key, not the policy
// or production encoder. The first test also pins a Python hashlib/HMAC vector.
func signBootstrap(sessionBytes, payload []byte) []byte {
	digest := sha256.Sum256(sessionBytes)
	sha := hex.EncodeToString(digest[:])
	proof := hmac.New(sha256.New, []byte(strings.Repeat("\x01", 32)))
	proof.Write([]byte("ERGOPTI_NATIVE_NETWORK_BOOTSTRAP_V1\n" + sha + "\n"))
	proof.Write(payload)
	data, _ := json.Marshal(bootstrapEnvelope{Version: 1, SessionSHA256: sha, Payload: base64.StdEncoding.EncodeToString(payload), MAC: hex.EncodeToString(proof.Sum(nil))})
	return data
}

func TestBootstrapIndependentHMACVectorAndImmutableSnapshot(t *testing.T) {
	bytes, session, payload, store := bootstrapLiteral()
	data := signBootstrap(bytes, payload)
	var literal bootstrapEnvelope
	json.Unmarshal(data, &literal)
	if literal.SessionSHA256 != "9a28cd6269a469fe95f2dce295626d993840b6d01d7a636e155443691dd4944d" || literal.MAC != "3c206daf45379622b9526d6d9fdc8a75d5efff08dfc164c2319d16a4d760b3a2" {
		t.Fatal("independent literal transcript changed")
	}
	snapshot, err := decodeNetworkBootstrap(data, bytes, session, store)
	if err != nil || snapshot.idle != time.Minute || snapshot.environment["https_proxy"] != "http://user:private-value@relay.example:8080" {
		t.Fatal("authenticated exact snapshot refused")
	}
	copy := snapshot.copyEnvironment()
	copy["https_proxy"] = "foreign"
	if snapshot.copyEnvironment()["https_proxy"] != "http://user:private-value@relay.example:8080" {
		t.Fatal("caller mutated immutable authority")
	}
	for _, altered := range [][]byte{append(append([]byte{}, bytes...), ' '), []byte(strings.Replace(string(bytes), `"inode":"2"`, `"inode":"3"`, 1))} {
		if _, err := decodeNetworkBootstrap(data, altered, session, store); err == nil {
			t.Fatal("unrelated session bytes accepted")
		}
	}
}

func TestBootstrapSignedProtocolRefusals(t *testing.T) {
	bytes, session, payload, store := bootstrapLiteral()
	mutants := []string{
		strings.Replace(string(payload), `"environment":`, `"environment":[],"environment":`, 1),
		strings.Replace(string(payload), `"idle_timeout_ms":60000`, `"idle_timeout_ms":60000,"foreign":1`, 1),
		strings.Replace(string(payload), `"idle_timeout_ms":60000`, `"idle_timeout_ms":true`, 1),
		strings.Replace(string(payload), `"idle_timeout_ms":60000`, `"idle_timeout_ms":1.5`, 1),
		strings.Replace(string(payload), `"idle_timeout_ms":60000`, `"idle_timeout_ms":0`, 1),
		strings.Replace(string(payload), `"environment":[`, `"environment":null,"other":[`, 1),
		strings.Replace(string(payload), `"https_proxy"`, `"PRIVATE_KEY"`, 1),
		strings.Replace(string(payload), `"https_proxy"`, `"SSL_CERT_FILE","third"`, 1),
		strings.Replace(string(payload), `"http://user:private-value@relay.example:8080"`, `"value\u0000tail"`, 1),
		strings.Replace(string(payload), `[["https_proxy","http://user:private-value@relay.example:8080"]]`, `[["https_proxy","one"],["https_proxy","two"]]`, 1),
		strings.Replace(string(payload), `"mode":"environment"`, `"mode":"default"`, 1),
		strings.Replace(string(payload), `"cwd":"/original/work"`, `"cwd":"relative"`, 1),
		strings.Replace(string(payload), `"mode":"environment"`, `"mode":"environment","mode":"environment"`, 1),
		strings.Replace(string(payload), `"http://user:private-value@relay.example:8080"`, `"`+strings.Repeat("x", 65537)+`"`, 1),
	}
	for index, value := range mutants {
		if _, err := decodeNetworkBootstrap(signBootstrap(bytes, []byte(value)), bytes, session, store); err == nil {
			t.Fatalf("signed malformed payload %d accepted", index)
		}
	}
	data := signBootstrap(bytes, payload)
	for _, value := range []string{
		strings.Replace(string(data), `"version":1`, `"version":1,"version":1`, 1),
		strings.Replace(string(data), `"version":1`, `"version":1,"foreign":0`, 1),
		strings.Replace(string(data), `"version":1`, `"version":null`, 1),
		strings.Replace(string(data), `"mac":"3`, `"mac":"4`, 1),
		strings.Replace(string(data), `"payload":"e`, `"payload":"\ne`, 1),
		string(append(append([]byte{}, data...), 0xff)),
		strings.Repeat(" ", 1048577),
	} {
		if _, err := decodeNetworkBootstrap([]byte(value), bytes, session, store); err == nil {
			t.Fatal("malformed outer envelope accepted")
		}
	}
}

func TestBootstrapPreservesCustomStoreWithoutMigration(t *testing.T) {
	bytes, session, payload, store := bootstrapLiteral()
	for _, value := range []string{"../outside models", "/Volumes/User Models/unchanged", "model-relative"} {
		public := store
		public.Value = value
		private := strings.Replace(string(payload), "../outside models", value, 1)
		if _, err := decodeNetworkBootstrap(signBootstrap(bytes, []byte(private)), bytes, session, public); err != nil {
			t.Fatal("original custom store refused")
		}
		public.CWD = "/foreign/work"
		if _, err := decodeNetworkBootstrap(signBootstrap(bytes, []byte(private)), bytes, session, public); err == nil {
			t.Fatal("foreign original cwd accepted")
		}
	}
	private := strings.Replace(strings.Replace(string(payload), `"mode":"environment"`, `"mode":"default"`, 1), `"value":"../outside models"`, `"value":""`, 1)
	if _, err := decodeNetworkBootstrap(signBootstrap(bytes, []byte(private)), bytes, session, bootstrapStore{Mode: "default", CWD: store.CWD}); err != nil {
		t.Fatal("default store must be omitted, not migrated")
	}
}

func TestBootstrapRealPrivateFDAndNamespaceRefusals(t *testing.T) {
	bytes, session, payload, store := bootstrapLiteral()
	home := t.TempDir()
	t.Setenv("HOME", home)
	dir := filepath.Join(home, "Library/Application Support/Ergopti/ollama-native-sessions")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	nonce := strings.Repeat("a", 32)
	sessionPath := filepath.Join(dir, "daemon-"+nonce+".json")
	path := filepath.Join(dir, "network-"+nonce+".json")
	data := signBootstrap(bytes, payload)
	if os.WriteFile(sessionPath, bytes, 0600) != nil || os.WriteFile(path, data, 0600) != nil {
		t.Fatal("fixture write")
	}
	info, _ := os.Stat(path)
	identity := info.Sys().(*syscall.Stat_t)
	device := strconv.FormatUint(uint64(uint32(identity.Dev)), 10)
	inode := strconv.FormatUint(uint64(identity.Ino), 10)
	read := func() error {
		_, err := readBootstrapFiles(path, device, inode, sessionPath, session, store)
		return err
	}
	if err := read(); err != nil {
		t.Fatal("real owned bytes refused")
	}
	if _, err := readBootstrapFiles(path, device, "01", sessionPath, session, store); err == nil {
		t.Fatal("noncanonical vnode accepted")
	}
	if _, err := readBootstrapFiles(path, device, strconv.FormatUint(uint64(identity.Ino)+1, 10), sessionPath, session, store); err == nil {
		t.Fatal("foreign vnode accepted")
	}
	os.Chmod(path, 0644)
	if read() == nil {
		t.Fatal("public bootstrap accepted")
	}
	os.Chmod(path, 0600)
	os.Link(path, path+".alias")
	if read() == nil {
		t.Fatal("extra link accepted")
	}
	os.Remove(path + ".alias")
	os.Chmod(dir, 0755)
	if read() == nil {
		t.Fatal("public namespace accepted")
	}
	os.Chmod(dir, 0700)
	os.WriteFile(path, nil, 0600)
	if read() == nil {
		t.Fatal("empty pre-proof bootstrap used")
	}
	os.WriteFile(path, data, 0600)
	os.Rename(path, path+".old")
	os.Symlink(path+".old", path)
	if read() == nil {
		t.Fatal("final symlink accepted")
	}
	os.Remove(path)
	os.Rename(path+".old", path)
	os.WriteFile(sessionPath, append(bytes, ' '), 0600)
	if read() == nil {
		t.Fatal("session byte replacement accepted")
	}
}

func TestBootstrapNativeWorkerGetsOnlyPrivateCertificates(t *testing.T) {
	t.Setenv("https_proxy", "http://inherited-secret@foreign.invalid")
	t.Setenv("SSL_CERT_FILE", "foreign-certificate")
	result, err := nativeWorkerEnvironment(map[string]string{"SSL_CERT_FILE": "exact-private-certificate", "https_proxy": "http://private-secret@relay.invalid"})
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(result, "\n")
	if strings.Contains(joined, "secret@") || strings.Contains(joined, "foreign-certificate") || !strings.Contains(joined, "SSL_CERT_FILE=exact-private-certificate") || os.Getenv("SSL_CERT_FILE") != "foreign-certificate" {
		t.Fatal("secret forwarding or global trust mutation")
	}
}

func TestBootstrapCertificateTrustIsScopedAndPreservesOriginal(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "literal") }))
	defer server.Close()
	certificate := server.Certificate()
	path := filepath.Join(t.TempDir(), "enterprise.pem")
	os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificate.Raw}), 0600)
	original := &tls.Config{RootCAs: x509.NewCertPool(), MinVersion: tls.VersionTLS12}
	selected, err := bootstrapTLSConfig(original, map[string]string{"SSL_CERT_FILE": path})
	if err != nil || selected == original || selected.RootCAs == original.RootCAs || len(original.RootCAs.Subjects()) != 0 || selected.MinVersion != tls.VersionTLS12 {
		t.Fatal("original TLS configuration mutated")
	}
	transport := &http.Transport{TLSClientConfig: selected}
	defer transport.CloseIdleConnections()
	response, err := (&http.Client{Transport: transport, Timeout: 3 * time.Second}).Get(server.URL)
	if err != nil {
		t.Fatal("actual enterprise anchor TLS refused")
	}
	literal, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || string(literal) != "literal" {
		t.Fatal("actual TLS body mismatch")
	}
	refused := &http.Transport{TLSClientConfig: original}
	defer refused.CloseIdleConnections()
	if response, err := (&http.Client{Transport: refused, Timeout: 3 * time.Second}).Get(server.URL); err == nil {
		response.Body.Close()
		t.Fatal("untrusted certificate accepted")
	}
	dialer := &net.Dialer{Timeout: time.Second}
	wrong := selected.Clone()
	wrong.ServerName = "foreign.invalid"
	if connection, err := tls.DialWithDialer(dialer, "tcp", strings.TrimPrefix(server.URL, "https://"), wrong); err == nil {
		connection.Close()
		t.Fatal("enterprise anchor bypassed hostname verification")
	}
}

func TestBootstrapCertificateDirectoryAndMalformedRefusals(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer server.Close()
	dir := t.TempDir()
	path := filepath.Join(dir, "root.pem")
	valid := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw})
	os.WriteFile(path, valid, 0600)
	os.Symlink(path, filepath.Join(dir, "hash.0"))
	if _, err := bootstrapTLSConfig(nil, map[string]string{"SSL_CERT_DIR": dir}); err != nil {
		t.Fatal("stock hashed certificate directory refused")
	}
	for _, data := range [][]byte{nil, []byte("foreign text"), []byte("-----BEGIN PRIVATE KEY-----\nAA==\n-----END PRIVATE KEY-----\n"), append([]byte("foreign prefix\n"), valid...), []byte("-----BEGIN CERTIFICATE-----\n%%\n-----END CERTIFICATE-----\n")} {
		os.WriteFile(path, data, 0600)
		if _, err := bootstrapTLSConfig(nil, map[string]string{"SSL_CERT_FILE": path}); err == nil {
			t.Fatal("non-certificate input admitted")
		}
	}
	if _, err := bootstrapTLSConfig(nil, map[string]string{"SSL_CERT_DIR": dir + ":"}); err == nil {
		t.Fatal("empty directory segment admitted")
	}
	fifo := filepath.Join(t.TempDir(), "unopened-fifo")
	if err := syscall.Mkfifo(fifo, 0600); err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	if _, err := bootstrapTLSConfig(nil, map[string]string{"SSL_CERT_FILE": fifo}); err == nil || time.Since(started) > time.Second {
		t.Fatal("nonregular trust input blocked or admitted")
	}
}

func TestBootstrapExplicitProxyUsesActualScopedTLSAnchor(t *testing.T) {
	origin := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "actual-proxy-body") }))
	defer origin.Close()
	var owners sync.WaitGroup
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodConnect {
			http.Error(w, "refused", 400)
			return
		}
		upstream, err := net.DialTimeout("tcp", strings.TrimPrefix(origin.URL, "https://"), time.Second)
		if err != nil {
			http.Error(w, "refused", 502)
			return
		}
		client, buffer, err := w.(http.Hijacker).Hijack()
		if err != nil {
			upstream.Close()
			return
		}
		owners.Add(1)
		defer owners.Done()
		defer client.Close()
		defer upstream.Close()
		buffer.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n")
		buffer.Flush()
		joined := make(chan struct{})
		go func() { io.Copy(upstream, buffer); upstream.Close(); close(joined) }()
		io.Copy(client, upstream)
		client.Close()
		<-joined
	}))
	defer func() { proxy.Close(); owners.Wait() }()
	path := filepath.Join(t.TempDir(), "ca.pem")
	os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: origin.Certificate().Raw}), 0600)
	policy, err := parsePolicy(bootstrapProxyBytes)
	if err != nil {
		t.Fatal(err)
	}
	// The independent stock httptest certificate includes example.com. Using a
	// non-loopback URL forces the real selected proxy instead of bypass policy.
	original := &http.Transport{TLSClientConfig: &tls.Config{RootCAs: x509.NewCertPool()}}
	transport := &Transport{Fallback: original, Policy: policy, IdleTimeout: 3 * time.Second, ResolveWorker: func() (string, error) { t.Fatal("explicit proxy entered native helper"); return "", nil }, Environment: func() map[string]string { return map[string]string{"https_proxy": proxy.URL, "SSL_CERT_FILE": path} }}
	response, err := (&http.Client{Transport: transport, Timeout: 3 * time.Second}).Get("https://example.com/independent")
	if err != nil {
		t.Fatal("actual CONNECT/custom TLS refused")
	}
	body, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || string(body) != "actual-proxy-body" || len(original.TLSClientConfig.RootCAs.Subjects()) != 0 {
		t.Fatal("actual proxy body/configuration mismatch")
	}
	t.Setenv("ERGOPTI_OLLAMA_NATIVE_HTTP", "1")
	transport.Environment = func() map[string]string { return map[string]string{"https_proxy": proxy.URL} }
	request, _ := http.NewRequest(http.MethodGet, "https://example.com/independent", nil)
	refusal, err := Do(&http.Client{Transport: transport, Timeout: 3 * time.Second}, request)
	if refusal != nil {
		refusal.Body.Close()
	}
	var native *Error
	if err == nil || !errors.As(err, &native) || native.Reason != "certificate" || strings.Contains(err.Error(), "example.com") {
		t.Fatal("actual explicit proxy TLS refusal lost certificate classification or URL secrecy")
	}
}
