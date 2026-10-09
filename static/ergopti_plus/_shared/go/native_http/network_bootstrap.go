package nativehttp

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	_ "embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"
)

// The native producer copies these exact canonical source files into this
// package. Policy is part of the qualified image, not a mutable runtime path.
//
//go:embed managed_ollama_bootstrap.json
var bootstrapPolicyBytes []byte

//go:embed proxy_policy.json
var bootstrapProxyBytes []byte

type bootstrapPolicy struct {
	Version          int      `json:"schema_version"`
	MaximumBytes     int      `json:"maximum_metadata_bytes"`
	Domain           string   `json:"hmac_domain"`
	TrustNames       []string `json:"trust_environment"`
	CertificateBytes int64    `json:"maximum_certificate_bytes"`
	CertificateFiles int      `json:"maximum_certificate_files"`
}

func nativeBootstrapPolicy() (*bootstrapPolicy, error) {
	var policy bootstrapPolicy
	if decodeObject(bootstrapPolicyBytes, &policy, "schema_version", "maximum_metadata_bytes", "hmac_domain", "trust_environment", "maximum_certificate_bytes", "maximum_certificate_files") != nil || policy.Version != 1 || policy.MaximumBytes <= 0 || policy.Domain == "" || !strings.HasSuffix(policy.Domain, "\n") || len(policy.TrustNames) != 2 || policy.CertificateBytes <= 0 || policy.CertificateFiles <= 0 {
		return nil, fail("protocol")
	}
	seen := make(map[string]bool)
	for _, name := range policy.TrustNames {
		if name == "" || strings.ContainsAny(name, "=\x00\r\n") || seen[name] {
			return nil, fail("protocol")
		}
		seen[name] = true
	}
	return &policy, nil
}

type bootstrapEnvelope struct {
	Version       int    `json:"version"`
	SessionSHA256 string `json:"session_sha256"`
	Payload       string `json:"payload"`
	MAC           string `json:"mac"`
}

type bootstrapStore struct {
	Mode  string `json:"mode"`
	Value string `json:"value"`
	CWD   string `json:"cwd"`
}

type bootstrapPayload struct {
	Environment      [][]string      `json:"environment"`
	Store            json.RawMessage `json:"store"`
	IdleMilliseconds int64           `json:"idle_timeout_ms"`
}

type networkSnapshot struct {
	environment map[string]string
	policy      *Policy
	idle        time.Duration
	trust       *bootstrapPolicy
}

func (s *networkSnapshot) copyEnvironment() map[string]string {
	result := make(map[string]string, len(s.environment))
	for name, value := range s.environment {
		result[name] = value
	}
	return result
}

func nativeWorkerEnvironment(private map[string]string) ([]string, error) {
	policy, err := nativeBootstrapPolicy()
	if err != nil {
		return nil, err
	}
	var routes struct {
		Exclusions []string `json:"system_lookup_environment_exclusions"`
		Bypass     []string `json:"environment_bypass_precedence"`
	}
	if json.Unmarshal(bootstrapProxyBytes, &routes) != nil {
		return nil, fail("protocol")
	}
	omitted := make(map[string]bool)
	for _, names := range [][]string{routes.Exclusions, routes.Bypass, policy.TrustNames} {
		for _, name := range names {
			omitted[name] = true
		}
	}
	result := make([]string, 0)
	for _, pair := range os.Environ() {
		name, _, _ := strings.Cut(pair, "=")
		if !omitted[name] {
			result = append(result, pair)
		}
	}
	// Only certificate data is sent to the signed native worker. Credentials
	// from explicit proxy choices remain in Go's request-local transport.
	for _, name := range policy.TrustNames {
		if value, exists := private[name]; exists {
			result = append(result, name+"="+value)
		}
	}
	return result, nil
}

// decodeNetworkBootstrap authenticates the exact private bytes. An unrelated
// session or a modified duplicate field cannot mint an environment snapshot.
func decodeNetworkBootstrap(data, sessionBytes []byte, session *Session, publicStore bootstrapStore) (*networkSnapshot, error) {
	policy, err := nativeBootstrapPolicy()
	if err != nil || len(data) > policy.MaximumBytes || session == nil || !utf8.Valid(data) {
		return nil, fail("protocol")
	}
	var envelope bootstrapEnvelope
	if decodeObject(data, &envelope, "version", "session_sha256", "payload", "mac") != nil || envelope.Version != 1 || !lowerHex(envelope.SessionSHA256, 64) || !lowerHex(envelope.MAC, 64) {
		return nil, fail("protocol")
	}
	digest := sha256.Sum256(sessionBytes)
	if envelope.SessionSHA256 != hex.EncodeToString(digest[:]) {
		return nil, fail("protocol")
	}
	// Compare all eight admitted fields, while hashing the original bytes above.
	var observed Session
	if decodeObject(sessionBytes, &observed, "version", "token", "source_commit", "binary_sha256", "asset_sha256", "device", "inode", "port") != nil || observed != *session {
		return nil, fail("protocol")
	}
	payload, err := base64.StdEncoding.Strict().DecodeString(envelope.Payload)
	if err != nil || base64.StdEncoding.EncodeToString(payload) != envelope.Payload || len(payload) > policy.MaximumBytes || !utf8.Valid(payload) {
		return nil, fail("protocol")
	}
	key, err := hex.DecodeString(session.Token)
	if err != nil || len(key) != sha256.Size {
		return nil, fail("protocol")
	}
	proof := hmac.New(sha256.New, key)
	proof.Write([]byte(policy.Domain))
	proof.Write([]byte(envelope.SessionSHA256))
	proof.Write([]byte("\n"))
	proof.Write(payload)
	claimed, _ := hex.DecodeString(envelope.MAC)
	if !hmac.Equal(proof.Sum(nil), claimed) {
		return nil, fail("protocol")
	}
	var decoded bootstrapPayload
	if decodeObject(payload, &decoded, "environment", "store", "idle_timeout_ms") != nil || decoded.Environment == nil || decoded.IdleMilliseconds <= 0 || decoded.IdleMilliseconds > int64((1<<63-1)/int64(time.Millisecond)) {
		return nil, fail("protocol")
	}
	var store bootstrapStore
	if decodeObject(decoded.Store, &store, "mode", "value", "cwd") != nil || store != publicStore || !filepath.IsAbs(store.CWD) || filepath.Clean(store.CWD) != store.CWD || strings.ContainsRune(store.CWD, 0) || !utf8.ValidString(store.Value) || strings.ContainsRune(store.Value, 0) || store.Mode != "default" && store.Mode != "environment" || store.Mode == "default" && store.Value != "" || store.Mode == "environment" && store.Value == "" {
		return nil, fail("protocol")
	}
	var canonical struct {
		Exclusions []string `json:"system_lookup_environment_exclusions"`
		Bypass     []string `json:"environment_bypass_precedence"`
		Maximum    int      `json:"max_proxy_bytes"`
	}
	if json.Unmarshal(bootstrapProxyBytes, &canonical) != nil || len(canonical.Exclusions) == 0 || len(canonical.Bypass) == 0 || canonical.Maximum <= 0 {
		return nil, fail("protocol")
	}
	allowed := make(map[string]bool)
	for _, names := range [][]string{canonical.Exclusions, canonical.Bypass, policy.TrustNames} {
		for _, name := range names {
			allowed[name] = true
		}
	}
	environment := make(map[string]string)
	for _, pair := range decoded.Environment {
		if len(pair) != 2 || !allowed[pair[0]] || !utf8.ValidString(pair[1]) || strings.ContainsRune(pair[1], 0) || len(pair[1]) > canonical.Maximum {
			return nil, fail("protocol")
		}
		if _, exists := environment[pair[0]]; exists {
			return nil, fail("protocol")
		}
		environment[pair[0]] = pair[1]
	}
	routes, err := parsePolicy(bootstrapProxyBytes)
	if err != nil {
		return nil, err
	}
	return &networkSnapshot{environment: environment, policy: routes, idle: time.Duration(decoded.IdleMilliseconds) * time.Millisecond, trust: policy}, nil
}

// bootstrapTLSConfig clones the caller's trust configuration. Extra anchors
// augment account/system roots; no process environment or host trust is changed.
func bootstrapTLSConfig(original *tls.Config, environment map[string]string) (*tls.Config, error) {
	policy, err := nativeBootstrapPolicy()
	if err != nil {
		return nil, err
	}
	if environment[policy.TrustNames[0]] == "" && environment[policy.TrustNames[1]] == "" {
		return original, nil
	}
	var selected *tls.Config
	if original == nil {
		selected = &tls.Config{}
	} else {
		selected = original.Clone()
	}
	if selected.RootCAs == nil {
		selected.RootCAs, err = x509.SystemCertPool()
		if err != nil || selected.RootCAs == nil {
			return nil, fail("certificate")
		}
	} else {
		selected.RootCAs = selected.RootCAs.Clone()
	}
	var files int
	var received int64
	var admitted int
	read := func(path string) error {
		files++
		if files > policy.CertificateFiles {
			return fail("certificate")
		}
		file, err := openCertificateFile(path)
		if err != nil {
			return fail("certificate")
		}
		info, statErr := file.Stat()
		if statErr != nil || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > policy.CertificateBytes-received {
			file.Close()
			return fail("certificate")
		}
		data, readErr := io.ReadAll(io.LimitReader(file, policy.CertificateBytes-received+1))
		closeErr := file.Close()
		if readErr != nil || closeErr != nil || int64(len(data)) > policy.CertificateBytes-received {
			return fail("certificate")
		}
		received += int64(len(data))
		count := 0
		for len(bytes.TrimSpace(data)) != 0 {
			data = bytes.TrimSpace(data)
			if !bytes.HasPrefix(data, []byte("-----BEGIN CERTIFICATE-----")) {
				return fail("certificate")
			}
			block, rest := pem.Decode(data)
			if block == nil || block.Type != "CERTIFICATE" || len(block.Headers) != 0 {
				return fail("certificate")
			}
			certificate, err := x509.ParseCertificate(block.Bytes)
			if err != nil {
				return fail("certificate")
			}
			selected.RootCAs.AddCert(certificate)
			count++
			data = rest
		}
		if count == 0 {
			return fail("certificate")
		}
		admitted += count
		return nil
	}
	if path := environment[policy.TrustNames[0]]; path != "" {
		if err := read(path); err != nil {
			return nil, err
		}
	}
	if paths := environment[policy.TrustNames[1]]; paths != "" {
		for _, directory := range strings.Split(paths, string(os.PathListSeparator)) {
			if directory == "" {
				return nil, fail("certificate")
			}
			entries, err := os.ReadDir(directory)
			if err != nil || len(entries) > policy.CertificateFiles-files {
				return nil, fail("certificate")
			}
			for _, entry := range entries {
				if entry.IsDir() {
					continue
				}
				if err := read(filepath.Join(directory, entry.Name())); err != nil {
					return nil, err
				}
			}
		}
	}
	if admitted == 0 {
		return nil, fail("certificate")
	}
	return selected, nil
}
