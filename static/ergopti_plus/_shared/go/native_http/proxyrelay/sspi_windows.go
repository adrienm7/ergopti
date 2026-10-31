//go:build windows

package proxyrelay

import (
	"errors"
	"syscall"
	"unsafe"
)

// SSPI through secur32.dll with the standard library only: the current logon
// session's credentials, never a stored or prompted password.
var (
	secur32                        = syscall.NewLazyDLL("secur32.dll")
	procAcquireCredentialsHandleW  = secur32.NewProc("AcquireCredentialsHandleW")
	procInitializeSecurityContextW = secur32.NewProc("InitializeSecurityContextW")
	procCompleteAuthToken          = secur32.NewProc("CompleteAuthToken")
	procDeleteSecurityContext      = secur32.NewProc("DeleteSecurityContext")
	procFreeCredentialsHandle      = secur32.NewProc("FreeCredentialsHandle")
	procFreeContextBuffer          = secur32.NewProc("FreeContextBuffer")
)

const (
	secpkgCredOutbound      = 2
	securityNativeDrep      = 0x10
	secbufferToken          = 2
	iscReqAllocateMemory    = 0x100
	iscReqConnection        = 0x800
	secEOK                  = 0
	secIContinueNeeded      = 0x00090312
	secICompleteNeeded      = 0x00090313
	secICompleteAndContinue = 0x00090314
	secbufferVersion        = 0
)

type secHandle struct{ lower, upper uintptr }

type secBuffer struct {
	length     uint32
	bufferType uint32
	buffer     *byte
}

type secBufferDesc struct {
	version uint32
	count   uint32
	buffers *secBuffer
}

// windowsAuthenticator answers both schemes with the logged-in user.
type windowsAuthenticator struct{}

// DefaultAuthenticator is the logged-in user's OS sign-in.
func DefaultAuthenticator() Authenticator { return windowsAuthenticator{} }

func (windowsAuthenticator) Supports(scheme Scheme) bool {
	return scheme == SchemeNegotiate || scheme == SchemeNTLM
}

type sspiContext struct {
	credentials secHandle
	context     secHandle
	started     bool
	target      *uint16
	done        bool
}

func (windowsAuthenticator) NewContext(scheme Scheme, proxyHost string) (SecurityContext, error) {
	if err := secur32.Load(); err != nil {
		return nil, refuse(RefusalSignInUnavailable, err)
	}
	pkg, err := syscall.UTF16PtrFromString(scheme.Header())
	if err != nil {
		return nil, refuse(RefusalInvalidArguments, err)
	}
	target, err := syscall.UTF16PtrFromString("HTTP/" + proxyHost)
	if err != nil {
		return nil, refuse(RefusalInvalidArguments, err)
	}
	security := &sspiContext{target: target}
	var expiry int64
	status, _, _ := procAcquireCredentialsHandleW.Call(0, uintptr(unsafe.Pointer(pkg)), secpkgCredOutbound,
		0, 0, 0, 0, uintptr(unsafe.Pointer(&security.credentials)), uintptr(unsafe.Pointer(&expiry)))
	if uint32(status) != secEOK {
		return nil, refuse(RefusalSignInUnavailable, errors.New("sspi credentials unavailable"))
	}
	return security, nil
}

func (s *sspiContext) Step(challenge []byte) ([]byte, error) {
	if s.done {
		return nil, refuse(RefusalSignInRejected, nil)
	}
	output := secBuffer{bufferType: secbufferToken}
	outputDesc := secBufferDesc{version: secbufferVersion, count: 1, buffers: &output}
	var inputDesc *secBufferDesc
	if len(challenge) > 0 {
		input := secBuffer{length: uint32(len(challenge)), bufferType: secbufferToken, buffer: &challenge[0]}
		inputDesc = &secBufferDesc{version: secbufferVersion, count: 1, buffers: &input}
	}
	var current uintptr
	if s.started {
		current = uintptr(unsafe.Pointer(&s.context))
	}
	var attributes uint32
	var expiry int64
	status, _, _ := procInitializeSecurityContextW.Call(uintptr(unsafe.Pointer(&s.credentials)), current,
		uintptr(unsafe.Pointer(s.target)), iscReqAllocateMemory|iscReqConnection, 0, securityNativeDrep,
		uintptr(unsafe.Pointer(inputDesc)), 0, uintptr(unsafe.Pointer(&s.context)),
		uintptr(unsafe.Pointer(&outputDesc)), uintptr(unsafe.Pointer(&attributes)), uintptr(unsafe.Pointer(&expiry)))
	if output.buffer != nil {
		defer procFreeContextBuffer.Call(uintptr(unsafe.Pointer(output.buffer)))
	}
	switch uint32(status) {
	case secEOK, secIContinueNeeded:
	case secICompleteNeeded, secICompleteAndContinue:
		if done, _, _ := procCompleteAuthToken.Call(uintptr(unsafe.Pointer(&s.context)), uintptr(unsafe.Pointer(&outputDesc))); uint32(done) != secEOK {
			return nil, refuse(RefusalSignInUnavailable, errors.New("sspi completion refused"))
		}
	default:
		return nil, refuse(RefusalSignInUnavailable, errors.New("sspi context refused"))
	}
	s.started = true
	s.done = uint32(status) == secEOK || uint32(status) == secICompleteNeeded
	if output.buffer == nil || output.length == 0 {
		return nil, nil
	}
	token := make([]byte, output.length)
	copy(token, unsafe.Slice(output.buffer, output.length))
	return token, nil
}

func (s *sspiContext) Close() {
	if s.started {
		procDeleteSecurityContext.Call(uintptr(unsafe.Pointer(&s.context)))
	}
	procFreeCredentialsHandle.Call(uintptr(unsafe.Pointer(&s.credentials)))
}
