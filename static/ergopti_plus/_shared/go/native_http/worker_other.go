//go:build !darwin

package nativehttp

func resolveWorker() (string, error)         { return "", fail("unavailable") }
func loadNativeSession(path string) *Session { return nil }
