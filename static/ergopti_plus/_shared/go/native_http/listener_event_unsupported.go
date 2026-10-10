//go:build !darwin && !linux

package nativehttp

import (
	"errors"
	"net"
	"os"
)

func PrepareListenerEvent() error {
	_, nonce := os.LookupEnv("ERGOPTI_OLLAMA_LISTENER_EVENT")
	_, path := os.LookupEnv("ERGOPTI_OLLAMA_LISTENER_SOCKET")
	if nonce || path {
		return errors.New("Native listener event unavailable")
	}
	return nil
}
func CloseListenerEvent() error                  { return nil }
func PublishListenerBound(ln net.Listener) error { return PrepareListenerEvent() }
