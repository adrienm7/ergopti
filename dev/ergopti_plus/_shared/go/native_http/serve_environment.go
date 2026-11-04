package nativehttp

import (
	_ "embed"
	"os"
	"regexp"
)

// The managed runtime only serves local models. Ollama 0.40.4 otherwise
// contacts ollama.com from the daemon (model recommendations, the cloud model
// cache), so every driver applies the shared serve environment to the server
// it owns. The native producer copies the canonical file into this package.
//
//go:embed managed_ollama_environment.json
var serveEnvironmentBytes []byte

var serveEnvironmentName = regexp.MustCompile(`^[A-Z][A-Z0-9_]*$`)

type serveEnvironmentPolicy struct {
	Version     int               `json:"schema_version"`
	Environment map[string]string `json:"serve_environment"`
}

// serveEnvironment decodes the embedded declaration and refuses any invalid entry.
func serveEnvironment(payload []byte) (map[string]string, error) {
	var policy serveEnvironmentPolicy
	if decodeObject(payload, &policy, "schema_version", "serve_environment") != nil || policy.Version != 1 || len(policy.Environment) == 0 {
		return nil, fail("protocol")
	}
	for name, value := range policy.Environment {
		// The listener address and the model store stay with the launch owner.
		if !serveEnvironmentName.MatchString(name) || name == "OLLAMA_HOST" || name == "OLLAMA_MODELS" || !validEnvironmentValue(value) {
			return nil, fail("protocol")
		}
	}
	return policy.Environment, nil
}

func validEnvironmentValue(value string) bool {
	for _, character := range value {
		if character == 0 || character == '\r' || character == '\n' {
			return false
		}
	}
	return true
}

// ApplyServeEnvironment sets the shared managed serve environment before the
// server reads its configuration. Ollama reads these variables on each use.
func ApplyServeEnvironment() error {
	environment, err := serveEnvironment(serveEnvironmentBytes)
	if err != nil {
		return err
	}
	for name, value := range environment {
		if err := os.Setenv(name, value); err != nil {
			return err
		}
	}
	return nil
}
