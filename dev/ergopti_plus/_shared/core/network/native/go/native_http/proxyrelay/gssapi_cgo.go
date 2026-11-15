//go:build cgo && (linux || darwin)

package proxyrelay

/*
#cgo linux LDFLAGS: -ldl
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// The minimal GSS-API ABI (RFC 2744), declared here so the build needs no
// Kerberos headers. Apple's GSS.framework packs these structs to 2 bytes on
// x86_64 (its gssapi.h), and not on arm64.
#if defined(__APPLE__) && defined(__x86_64__)
#pragma pack(push, 2)
#endif
typedef uint32_t OM_uint32;
typedef struct { size_t length; void *value; } ergopti_gss_buffer;
typedef struct { OM_uint32 length; void *elements; } ergopti_gss_oid;
#if defined(__APPLE__) && defined(__x86_64__)
#pragma pack(pop)
#endif

typedef OM_uint32 (*import_name_fn)(OM_uint32 *, ergopti_gss_buffer *, ergopti_gss_oid *, void **);
typedef OM_uint32 (*init_sec_context_fn)(OM_uint32 *, void *, void **, void *, ergopti_gss_oid *,
	OM_uint32, OM_uint32, void *, ergopti_gss_buffer *, ergopti_gss_oid **, ergopti_gss_buffer *,
	OM_uint32 *, OM_uint32 *);
typedef OM_uint32 (*release_buffer_fn)(OM_uint32 *, ergopti_gss_buffer *);
typedef OM_uint32 (*delete_sec_context_fn)(OM_uint32 *, void **, ergopti_gss_buffer *);
typedef OM_uint32 (*release_name_fn)(OM_uint32 *, void **);

static void *ergopti_gss_library;
static import_name_fn ergopti_import_name;
static init_sec_context_fn ergopti_init_sec_context;
static release_buffer_fn ergopti_release_buffer;
static delete_sec_context_fn ergopti_delete_sec_context;
static release_name_fn ergopti_release_name;

// GSS_C_NT_HOSTBASED_SERVICE 1.2.840.113554.1.2.1.4 and SPNEGO 1.3.6.1.5.5.2.
static unsigned char ergopti_hostbased_bytes[] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x12, 0x01, 0x02, 0x01, 0x04};
static unsigned char ergopti_spnego_bytes[] = {0x2b, 0x06, 0x01, 0x05, 0x05, 0x02};
static ergopti_gss_oid ergopti_hostbased = {10, ergopti_hostbased_bytes};
static ergopti_gss_oid ergopti_spnego = {6, ergopti_spnego_bytes};

// Opens the platform GSS-API once; 0 when it is not installed.
static int ergopti_gss_open(void) {
	if (ergopti_gss_library != NULL) return 1;
#if defined(__APPLE__)
	const char *names[] = {"/System/Library/Frameworks/GSS.framework/GSS", NULL};
#else
	const char *names[] = {"libgssapi_krb5.so.2", "libgssapi.so.3", NULL};
#endif
	for (int i = 0; names[i] != NULL && ergopti_gss_library == NULL; i++)
		ergopti_gss_library = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
	if (ergopti_gss_library == NULL) return 0;
	ergopti_import_name = (import_name_fn)dlsym(ergopti_gss_library, "gss_import_name");
	ergopti_init_sec_context = (init_sec_context_fn)dlsym(ergopti_gss_library, "gss_init_sec_context");
	ergopti_release_buffer = (release_buffer_fn)dlsym(ergopti_gss_library, "gss_release_buffer");
	ergopti_delete_sec_context = (delete_sec_context_fn)dlsym(ergopti_gss_library, "gss_delete_sec_context");
	ergopti_release_name = (release_name_fn)dlsym(ergopti_gss_library, "gss_release_name");
	if (!ergopti_import_name || !ergopti_init_sec_context || !ergopti_release_buffer ||
		!ergopti_delete_sec_context || !ergopti_release_name) {
		dlclose(ergopti_gss_library);
		ergopti_gss_library = NULL;
		return 0;
	}
	return 1;
}

static OM_uint32 ergopti_gss_name(const char *service, void **name) {
	OM_uint32 minor = 0;
	ergopti_gss_buffer buffer = {strlen(service), (void *)service};
	return ergopti_import_name(&minor, &buffer, &ergopti_hostbased, name);
}

// One SPNEGO leg with the default (ticket cache) credentials. The output token
// is copied to malloc memory the caller frees.
static OM_uint32 ergopti_gss_step(void **context, void *name, const void *input, size_t input_length,
	void **output, size_t *output_length) {
	OM_uint32 minor = 0, flags = 0;
	ergopti_gss_buffer in = {input_length, (void *)input};
	ergopti_gss_buffer out = {0, NULL};
	OM_uint32 major = ergopti_init_sec_context(&minor, NULL, context, name, &ergopti_spnego, 0, 0, NULL,
		input_length > 0 ? &in : NULL, NULL, &out, &flags, NULL);
	*output = NULL;
	*output_length = 0;
	if (out.length > 0) {
		*output = malloc(out.length);
		if (*output != NULL) {
			memcpy(*output, out.value, out.length);
			*output_length = out.length;
		}
	}
	ergopti_release_buffer(&minor, &out);
	return major;
}

static void ergopti_gss_close(void **context, void **name) {
	OM_uint32 minor = 0;
	if (*context != NULL) ergopti_delete_sec_context(&minor, context, NULL);
	if (*name != NULL) ergopti_release_name(&minor, name);
}
*/
import "C"

import (
	"errors"
	"sync"
	"unsafe"
)

var gssOpen sync.Mutex

// gssContext is one SPNEGO exchange with the ticket cache's default principal.
type gssContext struct {
	context unsafe.Pointer
	name    unsafe.Pointer
	done    bool
}

// gssRoutineError is the GSS_ERROR mask (calling and routine error bits).
const gssRoutineError = 0xffff0000

func newGSSContext(proxyHost string) (SecurityContext, error) {
	gssOpen.Lock()
	opened := C.ergopti_gss_open()
	gssOpen.Unlock()
	if opened == 0 {
		return nil, refuse(RefusalSignInUnavailable, errors.New("gss-api library unavailable"))
	}
	service := C.CString("HTTP@" + proxyHost)
	defer C.free(unsafe.Pointer(service))
	security := &gssContext{}
	if major := C.ergopti_gss_name(service, &security.name); uint32(major)&gssRoutineError != 0 {
		security.Close()
		return nil, refuse(RefusalSignInUnavailable, errors.New("gss-api name refused"))
	}
	return security, nil
}

func (g *gssContext) Step(challenge []byte) ([]byte, error) {
	if g.done {
		// A proxy that asks again after a complete context rejected the ticket.
		return nil, refuse(RefusalSignInRejected, nil)
	}
	var input unsafe.Pointer
	if len(challenge) > 0 {
		input = C.CBytes(challenge)
		defer C.free(input)
	}
	var output unsafe.Pointer
	var length C.size_t
	major := C.ergopti_gss_step(&g.context, g.name, input, C.size_t(len(challenge)), &output, &length)
	if output != nil {
		defer C.free(output)
	}
	if uint32(major)&gssRoutineError != 0 {
		// No ticket, an expired one, or no service principal for the proxy:
		// the user's sign-in is unavailable, never a prompt for a password.
		return nil, refuse(RefusalSignInUnavailable, errors.New("gss-api init refused"))
	}
	g.done = major == 0
	return C.GoBytes(output, C.int(length)), nil
}

func (g *gssContext) Close() {
	C.ergopti_gss_close(&g.context, &g.name)
}
