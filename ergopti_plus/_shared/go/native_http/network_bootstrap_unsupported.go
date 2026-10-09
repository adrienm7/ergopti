//go:build !darwin && !linux

package nativehttp

import "os"

func openCertificateFile(path string) (*os.File, error) {
	return nil, fail("unavailable")
}
