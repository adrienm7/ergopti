//go:build darwin

package nativehttp

import (
	"sync"
	"testing"
)

// These controls exercise the actual production cache-choice boundary. Seeding
// a snapshot/refusal in a test is not native image or session qualification.
func resetBootstrapChoice(t *testing.T) {
	t.Helper()
	reset := func() {
		admittedNetworkBootstrap.Once = sync.Once{}
		admittedNetworkBootstrap.snapshot = nil
		admittedNetworkBootstrap.err = nil
	}
	reset()
	t.Cleanup(reset)
}

func TestBootstrapDarwinAdmittedSnapshotSurvivesRemovedPublicPath(t *testing.T) {
	resetBootstrapChoice(t)
	original := &networkSnapshot{environment: map[string]string{"https_proxy": "http://original.invalid:8080"}}
	admittedNetworkBootstrap.Do(func() { admittedNetworkBootstrap.snapshot = original })
	t.Setenv("ERGOPTI_OLLAMA_NETWORK_BOOTSTRAP", "")
	selected, err := loadNetworkBootstrap()
	if err != nil || selected != original {
		t.Fatal("removed public path reverted immutable admitted authority")
	}
}

func TestBootstrapDarwinAdmittedSnapshotSurvivesChangedPublicPath(t *testing.T) {
	resetBootstrapChoice(t)
	original := &networkSnapshot{environment: map[string]string{"https_proxy": "http://original.invalid:8080"}}
	admittedNetworkBootstrap.Do(func() { admittedNetworkBootstrap.snapshot = original })
	t.Setenv("ERGOPTI_OLLAMA_NETWORK_BOOTSTRAP", "/foreign/network.json")
	selected, err := loadNetworkBootstrap()
	if err != nil || selected != original {
		t.Fatal("changed public path replaced immutable admitted authority")
	}
}

func TestBootstrapDarwinOriginalAbsenceCannotStartLaterLookup(t *testing.T) {
	resetBootstrapChoice(t)
	t.Setenv("ERGOPTI_OLLAMA_NETWORK_BOOTSTRAP", "")
	selected, err := loadNetworkBootstrap()
	if err != nil || selected != nil {
		t.Fatal("original legacy choice refused")
	}
	t.Setenv("ERGOPTI_OLLAMA_NETWORK_BOOTSTRAP", "/foreign/network.json")
	t.Setenv("ERGOPTI_OLLAMA_NATIVE_SESSION", t.TempDir()+"/missing-source-session.json")
	selected, err = loadNetworkBootstrap()
	if err != nil || selected != nil {
		t.Fatal("late public path started an unauthorized lookup")
	}
}

func TestBootstrapDarwinOriginalRefusalSurvivesRemovedPublicPath(t *testing.T) {
	resetBootstrapChoice(t)
	original := fail("protocol")
	admittedNetworkBootstrap.Do(func() { admittedNetworkBootstrap.err = original })
	t.Setenv("ERGOPTI_OLLAMA_NETWORK_BOOTSTRAP", "")
	selected, err := loadNetworkBootstrap()
	if selected != nil || err != original {
		t.Fatal("removed public path hid the original admission refusal")
	}
}
