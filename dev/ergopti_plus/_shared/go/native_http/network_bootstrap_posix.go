//go:build darwin || linux

package nativehttp

import (
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

func openCertificateFile(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
}

func samePrivateIdentity(left, right os.FileInfo, directory bool) bool {
	a, aOK := left.Sys().(*syscall.Stat_t)
	b, bOK := right.Sys().(*syscall.Stat_t)
	return aOK && bOK && a.Dev == b.Dev && a.Ino == b.Ino && a.Uid == uint32(os.Geteuid()) && b.Uid == a.Uid &&
		left.Mode().IsDir() == directory && right.Mode().IsDir() == directory &&
		(directory && left.Mode().Perm() == 0700 && right.Mode().Perm() == 0700 ||
			!directory && left.Mode().IsRegular() && right.Mode().IsRegular() && left.Mode().Perm() == 0600 && right.Mode().Perm() == 0600 && a.Nlink == 1 && b.Nlink == 1)
}

// readBootstrapFiles is also exercised by real POSIX FD tests on Linux. Only
// the Darwin caller can supply loadNativeSession's qualified image authority.
func readBootstrapFiles(path, device, inode, sessionPath string, admitted *Session, store bootstrapStore) (result *networkSnapshot, refusal error) {
	policy, err := nativeBootstrapPolicy()
	if err != nil {
		return nil, err
	}
	directory := filepath.Join(os.Getenv("HOME"), "Library/Application Support/Ergopti/ollama-native-sessions")
	if filepath.Dir(path) != directory || filepath.Dir(sessionPath) != directory || filepath.Clean(path) != path || filepath.Clean(sessionPath) != sessionPath {
		return nil, fail("protocol")
	}
	sessionName := filepath.Base(sessionPath)
	if len(sessionName) != len("daemon-")+32+len(".json") || !strings.HasPrefix(sessionName, "daemon-") || !strings.HasSuffix(sessionName, ".json") {
		return nil, fail("protocol")
	}
	nonce := strings.TrimSuffix(strings.TrimPrefix(sessionName, "daemon-"), ".json")
	if !lowerHex(nonce, 32) || filepath.Base(path) != "network-"+nonce+".json" {
		return nil, fail("protocol")
	}
	expectedDevice, err := strconv.ParseUint(device, 10, 32)
	if err != nil || strconv.FormatUint(expectedDevice, 10) != device {
		return nil, fail("protocol")
	}
	expectedInode, err := strconv.ParseUint(inode, 10, 64)
	if err != nil || expectedInode == 0 || strconv.FormatUint(expectedInode, 10) != inode {
		return nil, fail("protocol")
	}
	var owned []*os.File
	defer func() {
		for index := len(owned) - 1; index >= 0; index-- {
			if owned[index].Close() != nil {
				result = nil
				refusal = fail("protocol")
			}
		}
	}()
	open := func(selected string, flags int) (*os.File, error) {
		fd, err := syscall.Open(selected, flags|syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC|syscall.O_NONBLOCK, 0)
		if err != nil {
			return nil, fail("protocol")
		}
		file := os.NewFile(uintptr(fd), selected)
		owned = append(owned, file)
		return file, nil
	}
	dir, err := open(directory, syscall.O_DIRECTORY)
	if err != nil {
		return nil, err
	}
	initialDirectory, err := dir.Stat()
	namedDirectory, namedErr := os.Lstat(directory)
	if err != nil || namedErr != nil || !samePrivateIdentity(initialDirectory, namedDirectory, true) {
		return nil, fail("protocol")
	}
	read := func(selected string, maximum int64, expected bool) ([]byte, error) {
		file, err := open(selected, 0)
		if err != nil {
			return nil, err
		}
		initial, err := file.Stat()
		named, namedErr := os.Lstat(selected)
		if err != nil || namedErr != nil || !samePrivateIdentity(initial, named, false) || initial.Size() <= 0 || initial.Size() > maximum {
			return nil, fail("protocol")
		}
		identity := initial.Sys().(*syscall.Stat_t)
		if expected && (uint64(uint32(identity.Dev)) != expectedDevice || uint64(identity.Ino) != expectedInode) {
			return nil, fail("protocol")
		}
		data, err := io.ReadAll(io.LimitReader(file, maximum+1))
		after, statErr := file.Stat()
		named, namedErr = os.Lstat(selected)
		if err != nil || statErr != nil || namedErr != nil || int64(len(data)) != initial.Size() || !samePrivateIdentity(initial, after, false) || !samePrivateIdentity(after, named, false) || after.Size() != initial.Size() || after.ModTime() != initial.ModTime() {
			return nil, fail("protocol")
		}
		return data, nil
	}
	sessionBytes, err := read(sessionPath, 4096, false)
	if err != nil {
		return nil, err
	}
	data, err := read(path, int64(policy.MaximumBytes), true)
	if err != nil {
		return nil, err
	}
	result, refusal = decodeNetworkBootstrap(data, sessionBytes, admitted, store)
	afterDirectory, statErr := dir.Stat()
	namedDirectory, namedErr = os.Lstat(directory)
	if statErr != nil || namedErr != nil || !samePrivateIdentity(initialDirectory, afterDirectory, true) || !samePrivateIdentity(afterDirectory, namedDirectory, true) {
		return nil, fail("protocol")
	}
	return result, refusal
}
