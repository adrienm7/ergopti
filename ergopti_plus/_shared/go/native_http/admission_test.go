package nativehttp

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func signFixture(request *http.Request, token string) {
	challenge := strings.Repeat("e", 64)
	body := sha256.Sum256(nil)
	digest := hex.EncodeToString(body[:])
	payload := "ERGOPTI_NATIVE_AUTH_V1\n" + request.Method + "\n" + request.Host + "\n" + request.URL.EscapedPath() + "\n" + digest + "\n" + request.Header.Get("X-Ergopti-Native-Operation") + "\n" + challenge
	mac := hmac.New(sha256.New, []byte(token))
	mac.Write([]byte(payload))
	request.Header.Set("X-Ergopti-Native-Session", hex.EncodeToString(mac.Sum(nil)))
	request.Header.Set("X-Ergopti-Native-Challenge", challenge)
	request.Header.Set("X-Ergopti-Native-Body-SHA256", digest)
}

func TestPrivateHMACFrozenIndependentVectorBindsAuthorityPathAndBody(t *testing.T) {
	request := httptest.NewRequest("GET", "http://127.0.0.1:11434/api/ergopti-native-http-admission", nil)
	request.RemoteAddr = "127.0.0.1:43210"
	signFixture(request, strings.Repeat("a", 64))
	// Frozen independently using Python hmac/hashlib over the published wire
	// grammar, not regenerated from the Go request implementation.
	if request.Header.Get("X-Ergopti-Native-Session") != "81847eb08c9c9c21dc36d6cad790aaeef26ff1bfb10e085d8cea5157aac0d95f" {
		t.Fatal("independent request HMAC vector changed")
	}
	empty := sha256.Sum256(nil)
	digest := hex.EncodeToString(empty[:])
	session := &Session{Token: strings.Repeat("a", 64), Port: "11434"}
	if !authorized(session, request, digest) {
		t.Fatal("independent HMAC not admitted")
	}
	request.Host = "127.0.0.1:11435"
	if authorized(session, request, digest) {
		t.Fatal("foreign listener authority admitted")
	}
	request.Host = "127.0.0.1:11434"
	request.URL.Path = "/api/pull"
	if authorized(session, request, digest) {
		t.Fatal("foreign request path admitted")
	}
	request.URL.Path = "/api/ergopti-native-http-admission"
	if authorized(session, request, strings.Repeat("f", 64)) {
		t.Fatal("mutated request body admitted")
	}
}

func TestPrivateAdmissionRequiresExactSecretAndLoopback(t *testing.T) {
	session := &Session{Version: 1, Token: strings.Repeat("a", 64), SourceCommit: strings.Repeat("b", 40),
		BinarySHA256: strings.Repeat("c", 64), AssetSHA256: strings.Repeat("d", 64), Device: "1", Inode: "2", Port: "11434"}
	handler := admissionHandler(session, 456)
	for _, row := range []struct {
		remote, token, method string
		status                int
	}{
		{"127.0.0.2:54321", session.Token, "GET", 200},
		{"[0:0:0:0:0:0:0:1]:1234", session.Token, "GET", 200},
		{"127.0.0.1:1234", "", "GET", 404},
		{"127.0.0.1:1234", strings.Repeat("f", 64), "GET", 404},
		{"192.0.2.1:1234", session.Token, "GET", 404},
		{"127.0.0.1:1234", session.Token, "POST", 404},
	} {
		r := httptest.NewRequest(row.method, "http://127.0.0.1:11434/api/ergopti-native-http-admission", nil)
		r.RemoteAddr = row.remote
		signFixture(r, row.token)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != row.status || strings.Contains(w.Body.String(), session.Token) {
			t.Fatalf("secret admission status/disclosure: %d", w.Code)
		}
		if row.status == 200 {
			var result map[string]any
			if json.Unmarshal(w.Body.Bytes(), &result) != nil || result["pid"] != float64(456) || result["capability"] != Capability() || len(result) != 10 {
				t.Fatal("actual daemon identity missing")
			}
		}
	}
	r := httptest.NewRequest("GET", "http://127.0.0.1:11434/api/ergopti-native-http-admission", nil)
	r.RemoteAddr = "127.0.0.1:1234"
	signFixture(r, session.Token)
	r.Header.Add("X-Ergopti-Native-Session", r.Header.Get("X-Ergopti-Native-Session"))
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != http.StatusNotFound {
		t.Fatal("duplicate secret admitted")
	}
}

func TestPrivateAdmissionDoesNotDiscloseUnqualifiedDaemon(t *testing.T) {
	r := httptest.NewRequest("GET", "http://127.0.0.1/api/ergopti-native-http-admission", nil)
	r.RemoteAddr = "127.0.0.1:1234"
	w := httptest.NewRecorder()
	admissionHandler(nil, 999).ServeHTTP(w, r)
	if w.Code != 404 || w.Body.String() != "Unavailable\n" {
		t.Fatal("unqualified daemon disclosure")
	}
}

func TestPrivateSessionRejectsDuplicateNullAndMalformedIdentity(t *testing.T) {
	valid := `{"version":1,"token":"` + strings.Repeat("a", 64) + `","source_commit":"` + strings.Repeat("b", 40) + `","binary_sha256":"` + strings.Repeat("c", 64) + `","asset_sha256":"` + strings.Repeat("d", 64) + `","device":"1","inode":"2","port":"11434"}`
	for _, row := range []struct {
		bytes    string
		accepted bool
	}{
		{valid, true},
		{strings.Replace(valid, `"version":1`, `"version":1,"version":1`, 1), false},
		{strings.Replace(valid, `"device":"1"`, `"device":"01"`, 1), false},
		{strings.Replace(valid, `"inode":"2"`, `"inode":null`, 1), false},
		{strings.Replace(valid, `"version":1`, `"version":true`, 1), false},
		{valid + ` {}`, false},
	} {
		path := t.TempDir() + "/private"
		if os.WriteFile(path, []byte(row.bytes), 0600) != nil {
			t.Fatal("fixture create")
		}
		file, err := os.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		actual := decodeNativeSession(file)
		file.Close()
		if (actual != nil) != row.accepted {
			t.Fatal("private session admission differs")
		}
	}
}

func TestOwnedPullRetirementWaitsForPhysicalNativeAndBackgroundOwners(t *testing.T) {
	session := &Session{Token: strings.Repeat("a", 64), Port: "11434"}
	state := &admissionState{session: session, operations: make(map[string]bool)}
	daemonAdmission.Lock()
	previous := daemonAdmission.state
	daemonAdmission.state = state
	daemonAdmission.Unlock()
	defer func() { daemonAdmission.Lock(); daemonAdmission.state = previous; daemonAdmission.Unlock() }()
	operation := strings.Repeat("b", 32)
	request := httptest.NewRequest("POST", "http://127.0.0.1:11434/api/pull", nil)
	request.RemoteAddr = "127.0.0.1:54321"
	request.Header.Set("X-Ergopti-Native-Operation", operation)
	signFixture(request, session.Token)
	finish, err := BeginPull(request)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := BeginPull(request); err == nil {
		t.Fatal("duplicate operation admitted")
	}
	status := func() string {
		query := httptest.NewRequest("GET", "http://127.0.0.1:11434/api/ergopti-native-http-admission", nil)
		query.RemoteAddr = "127.0.0.1:54321"
		query.Header = request.Header.Clone()
		signFixture(query, session.Token)
		response := httptest.NewRecorder()
		stateHandler(state, 123).ServeHTTP(response, query)
		var result map[string]any
		if json.Unmarshal(response.Body.Bytes(), &result) != nil || response.Code != 200 {
			t.Fatal("private query failed")
		}
		return result["operation_state"].(string)
	}
	retireNative := track(&nativeHelpers)
	retireDownload := TrackBackgroundDownload()
	finish()
	finish()
	if status() != "active" {
		t.Fatal("goroutine return credited native process before wait")
	}
	retireNative()
	retireNative()
	if status() != "active" {
		t.Fatal("process wait credited live background download")
	}
	retireDownload()
	retireDownload()
	if status() != "retired" {
		t.Fatal("actual completed owners not admitted")
	}
}

func TestOrdinaryPullAndPrivateForeignSessionStaySeparate(t *testing.T) {
	request := httptest.NewRequest("POST", "http://127.0.0.1/api/pull", nil)
	finish, err := BeginPull(request)
	if err != nil || finish == nil {
		t.Fatal("ordinary upstream pull changed")
	}
	finish()
	request.Header.Set("X-Ergopti-Native-Operation", strings.Repeat("b", 32))
	if _, err := BeginPull(request); err == nil {
		t.Fatal("unqualified operation admitted")
	}
}
