//go:build darwin

package nativehttp

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"strconv"
	"strings"
	"syscall"
)

func resolveWorker() (string, error) {
	path := os.Getenv("ERGOPTI_LAUNCHER_EXECUTABLE")
	if !strings.HasSuffix(path, "/Contents/MacOS/ErgoptiPlus") {
		return "", fail("unavailable")
	}
	observed, err := os.Lstat(path)
	if err != nil || !observed.Mode().IsRegular() || observed.Mode().Perm()&0111 == 0 {
		return "", fail("unavailable")
	}
	identity, ok := observed.Sys().(*syscall.Stat_t)
	if !ok || os.Getenv("ERGOPTI_LAUNCHER_DEVICE") != strconv.FormatInt(int64(identity.Dev), 10) || os.Getenv("ERGOPTI_LAUNCHER_INODE") != strconv.FormatUint(identity.Ino, 10) {
		return "", fail("unavailable")
	}
	return path, nil
}

func loadNativeSession(path string) *Session {
	// Admission reads only an already-owned private lease; no shell, PATH or
	// URL carries its bearer secret. Retain the admitted FD through the read.
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0600 || info.Size() > 4096 {
		return nil
	}
	identity, ok := info.Sys().(*syscall.Stat_t)
	if !ok || identity.Uid != uint32(os.Geteuid()) || identity.Nlink != 1 {
		return nil
	}
	session := decodeNativeSession(file)
	if session == nil || BuiltSourceCommit == "" || session.SourceCommit != BuiltSourceCommit {
		return nil
	}
	executable, err := os.Executable()
	if err != nil {
		return nil
	}
	binaryFD, err := syscall.Open(executable, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil
	}
	binary := os.NewFile(uintptr(binaryFD), executable)
	defer binary.Close()
	info, err = binary.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
		return nil
	}
	identity, ok = info.Sys().(*syscall.Stat_t)
	if !ok || session.Device != strconv.FormatUint(uint64(uint32(identity.Dev)), 10) || session.Inode != strconv.FormatUint(identity.Ino, 10) {
		return nil
	}
	digest := sha256.New()
	if _, err := io.Copy(digest, binary); err != nil || hex.EncodeToString(digest.Sum(nil)) != session.BinarySHA256 {
		return nil
	}
	return session
}
