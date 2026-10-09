package nativehttp

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
)

// Session is private, source-qualified daemon authority. The bearer value is
// read from an owned regular file, never a URL, argv or response metadata.
type Session struct {
	Version      int    `json:"version"`
	Token        string `json:"token"`
	SourceCommit string `json:"source_commit"`
	BinarySHA256 string `json:"binary_sha256"`
	AssetSHA256  string `json:"asset_sha256"`
	Device       string `json:"device"`
	Inode        string `json:"inode"`
	Port         string `json:"port"`
}

// BuiltSourceCommit is fixed by the pinned native producer's linker arguments.
var BuiltSourceCommit string

var nativeHelpers atomic.Int64
var backgroundDownloads atomic.Int64
var daemonAdmission struct {
	sync.RWMutex
	state *admissionState
}

type admissionState struct {
	sync.Mutex
	session    *Session
	operations map[string]bool
	completed  []string
}

func track(counter *atomic.Int64) func() {
	counter.Add(1)
	var retired sync.Once
	return func() { retired.Do(func() { counter.Add(-1) }) }
}

// TrackBackgroundDownload joins the genuine upstream shared blob worker,
// including its native HTTP children and all deferred file/body closures.
func TrackBackgroundDownload() func() { return track(&backgroundDownloads) }

func authorized(session *Session, request *http.Request, bodySHA256 string) bool {
	host, _, err := net.SplitHostPort(request.RemoteAddr)
	address := net.ParseIP(host)
	values := request.Header.Values("X-Ergopti-Native-Session")
	challenge := request.Header.Values("X-Ergopti-Native-Challenge")
	digests := request.Header.Values("X-Ergopti-Native-Body-SHA256")
	operations := request.Header.Values("X-Ergopti-Native-Operation")
	operation := ""
	if len(operations) == 1 {
		operation = operations[0]
	} else if len(operations) > 1 {
		return false
	}
	if session == nil || err != nil || address == nil || !address.IsLoopback() || request.Host != "127.0.0.1:"+session.Port ||
		len(values) != 1 || !lowerHex(values[0], 64) || len(challenge) != 1 || !lowerHex(challenge[0], 64) ||
		len(digests) != 1 || digests[0] != bodySHA256 {
		return false
	}
	payload := "ERGOPTI_NATIVE_AUTH_V1\n" + request.Method + "\n" + request.Host + "\n" + request.URL.EscapedPath() + "\n" + bodySHA256 + "\n" + operation + "\n" + challenge[0]
	proof := hmac.New(sha256.New, []byte(session.Token))
	proof.Write([]byte(payload))
	expected := hex.EncodeToString(proof.Sum(nil))
	return subtle.ConstantTimeCompare([]byte(values[0]), []byte(expected)) == 1
}

// BeginPull records only authenticated private operations. Ordinary upstream
// API callers keep their original behavior; invalid private requests refuse.
func BeginPull(request *http.Request) (func(), error) {
	values := request.Header.Values("X-Ergopti-Native-Operation")
	if len(values) == 0 {
		return func() {}, nil
	}
	daemonAdmission.RLock()
	state := daemonAdmission.state
	daemonAdmission.RUnlock()
	if state == nil || len(values) != 1 || !lowerHex(values[0], 32) {
		return nil, errors.New("Native pull admission unavailable")
	}
	body, err := io.ReadAll(io.LimitReader(request.Body, maximumFrame+1))
	if err != nil || len(body) > maximumFrame {
		return nil, errors.New("Native pull admission unavailable")
	}
	request.Body.Close()
	request.Body = io.NopCloser(bytes.NewReader(body))
	digest := sha256.Sum256(body)
	if !authorized(state.session, request, hex.EncodeToString(digest[:])) {
		return nil, errors.New("Native pull admission unavailable")
	}
	operation := values[0]
	state.Lock()
	if _, exists := state.operations[operation]; exists {
		state.Unlock()
		return nil, errors.New("Native pull admission unavailable")
	}
	// This fixed wire ledger retains at most 64 authenticated operations.
	for len(state.operations) >= 64 && len(state.completed) > 0 {
		delete(state.operations, state.completed[0])
		state.completed = state.completed[1:]
	}
	if len(state.operations) >= 64 {
		state.Unlock()
		return nil, errors.New("Native pull admission unavailable")
	}
	state.operations[operation] = false
	state.Unlock()
	var completed sync.Once
	return func() {
		completed.Do(func() {
			state.Lock()
			state.operations[operation] = true
			state.completed = append(state.completed, operation)
			state.Unlock()
		})
	}, nil
}

func lowerHex(value string, size int) bool {
	if len(value) != size || strings.ToLower(value) != value {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}

// AdmissionHandler authenticates the exact source-qualified server instance.
// Failure uses one fixed status with no token, URL, filename or runtime facts.
func AdmissionHandler() http.Handler {
	var session *Session
	if os.Getenv("ERGOPTI_OLLAMA_NATIVE_HTTP") == "1" {
		session = loadNativeSession(os.Getenv("ERGOPTI_OLLAMA_NATIVE_SESSION"))
	}
	state := &admissionState{session: session, operations: make(map[string]bool)}
	daemonAdmission.Lock()
	daemonAdmission.state = state
	daemonAdmission.Unlock()
	return stateHandler(state, os.Getpid())
}

func admissionHandler(session *Session, pid int) http.Handler {
	return stateHandler(&admissionState{session: session, operations: make(map[string]bool)}, pid)
}

func stateHandler(state *admissionState, pid int) http.Handler {
	session := state.session
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		empty := sha256.Sum256(nil)
		if r.Method != http.MethodGet || !authorized(session, r, hex.EncodeToString(empty[:])) {
			http.Error(w, "Unavailable", http.StatusNotFound)
			return
		}
		lease := sha256.Sum256([]byte(session.Token))
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		result := map[string]any{
			"version": 1, "capability": Capability(), "pid": pid, "source_commit": session.SourceCommit,
			"binary_sha256": session.BinarySHA256, "asset_sha256": session.AssetSHA256,
			"device": session.Device, "inode": session.Inode, "lease_id": hex.EncodeToString(lease[:]),
			"port": session.Port,
		}
		if values := r.Header.Values("X-Ergopti-Native-Operation"); len(values) > 0 {
			if len(values) != 1 || !lowerHex(values[0], 32) {
				http.Error(w, "Unavailable", http.StatusNotFound)
				return
			}
			state.Lock()
			finished, exists := state.operations[values[0]]
			state.Unlock()
			helpers, downloads := nativeHelpers.Load(), backgroundDownloads.Load()
			status := "unknown"
			if exists {
				status = "active"
				if finished && helpers == 0 && downloads == 0 {
					status = "retired"
				}
			}
			result["operation_id"] = values[0]
			result["operation_state"] = status
			result["native_helpers"] = helpers
			result["background_downloads"] = downloads
		}
		payload, err := json.Marshal(result)
		if err != nil {
			http.Error(w, "Unavailable", http.StatusNotFound)
			return
		}
		proof := hmac.New(sha256.New, []byte(session.Token))
		proof.Write([]byte("ERGOPTI_NATIVE_RESPONSE_V1\n" + r.Header.Get("X-Ergopti-Native-Challenge") + "\n"))
		proof.Write(payload)
		w.Header().Set("X-Ergopti-Native-Proof", hex.EncodeToString(proof.Sum(nil)))
		_, _ = w.Write(payload)
	})
}

func decodeNativeSession(file *os.File) *Session {
	bytes, err := io.ReadAll(io.LimitReader(file, 4097))
	if err != nil || len(bytes) > 4096 {
		return nil
	}
	// Duplicate fields must not let a decoder choose an unreviewed identity.
	var session Session
	if decodeObject(bytes, &session, "version", "token", "source_commit", "binary_sha256", "asset_sha256", "device", "inode", "port") != nil || session.Version != 1 || !lowerHex(session.Token, 64) ||
		!lowerHex(session.SourceCommit, 40) || !lowerHex(session.BinarySHA256, 64) || !lowerHex(session.AssetSHA256, 64) {
		return nil
	}
	for _, value := range []string{session.Device, session.Inode} {
		parsed, err := strconv.ParseUint(value, 10, 64)
		if err != nil || strconv.FormatUint(parsed, 10) != value {
			return nil
		}
	}
	port, err := strconv.ParseUint(session.Port, 10, 16)
	if err != nil || port < 1024 || strconv.FormatUint(port, 10) != session.Port {
		return nil
	}
	return &session
}
