package nativehttp

import (
	"os"
	"testing"
)

// The literal expectation is the product decision (local models only), not a
// value derived from the embedded declaration under test.
func TestServeEnvironmentDisablesOllamaCloud(t *testing.T) {
	t.Setenv("OLLAMA_NO_CLOUD", "0")
	if err := ApplyServeEnvironment(); err != nil {
		t.Fatalf("The embedded serve environment was refused: %v", err)
	}
	if value := os.Getenv("OLLAMA_NO_CLOUD"); value != "1" {
		t.Fatalf("The managed server would keep Ollama cloud contact: OLLAMA_NO_CLOUD=%q", value)
	}
}

func TestServeEnvironmentRefusesInvalidDeclarations(t *testing.T) {
	for _, payload := range []string{
		`{"schema_version":1,"serve_environment":{}}`,
		`{"schema_version":2,"serve_environment":{"OLLAMA_NO_CLOUD":"1"}}`,
		`{"schema_version":1,"serve_environment":{"OLLAMA_HOST":"0.0.0.0"}}`,
		`{"schema_version":1,"serve_environment":{"OLLAMA_MODELS":"/tmp"}}`,
		`{"schema_version":1,"serve_environment":{"lower_case":"1"}}`,
		`{"schema_version":1,"serve_environment":{"OLLAMA_NO_CLOUD":"1\n"}}`,
		`{"schema_version":1,"serve_environment":{"OLLAMA_NO_CLOUD":"1"},"extra":1}`,
		`{"schema_version":1}`,
	} {
		if _, err := serveEnvironment([]byte(payload)); err == nil {
			t.Fatalf("An invalid serve environment was admitted: %s", payload)
		}
	}
}
