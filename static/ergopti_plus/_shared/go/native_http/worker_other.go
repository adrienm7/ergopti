//go:build !darwin

package nativehttp

import "os"

func resolveWorker() (string, error)         { return "", fail("unavailable") }
func loadNativeSession(path string) *Session { return nil }

func loadNetworkBootstrap() (*networkSnapshot, error) {
	if os.Getenv("ERGOPTI_OLLAMA_NETWORK_BOOTSTRAP") != "" {
		return nil, fail("unavailable")
	}
	return nil, nil
}
