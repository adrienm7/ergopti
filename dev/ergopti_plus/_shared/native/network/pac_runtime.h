/* Portable PAC execution. The caller owns its process and absolute deadline. */
#ifndef ERGOPTI_PAC_RUNTIME_H
#define ERGOPTI_PAC_RUNTIME_H
#include <stddef.h>
#include <stdint.h>

typedef enum {
	ERGOPTI_PAC_OK = 0,
	ERGOPTI_PAC_INVALID_INPUT = 1,
	ERGOPTI_PAC_MEMORY_REFUSED = 2,
	ERGOPTI_PAC_SCRIPT_REFUSED = 3,
	ERGOPTI_PAC_BUDGET_EXPIRED = 4,
	ERGOPTI_PAC_NATIVE_REFUSED = 5,
	ERGOPTI_PAC_OUTPUT_REFUSED = 6
} ergopti_pac_status;

typedef enum {
	ERGOPTI_PAC_ERROR_NONE = 0,
	ERGOPTI_PAC_ERROR_WIN32 = 1,
	ERGOPTI_PAC_ERROR_WINSOCK = 2,
	ERGOPTI_PAC_ERROR_POSIX = 3
} ergopti_pac_error_domain;

typedef struct {
	int32_t code;
	ergopti_pac_error_domain domain;
} ergopti_pac_native_error;

typedef struct {
	void *owner;
	uint64_t (*tick)(void *owner);
	int (*dns)(void *owner, const char *host, int extended, char *output, size_t capacity, ergopti_pac_native_error *native_error);
	int (*local_addresses)(void *owner, int extended, char *output, size_t capacity, ergopti_pac_native_error *native_error);
	int (*sort_addresses)(void *owner, const char *addresses, char *output, size_t capacity, ergopti_pac_native_error *native_error);
} ergopti_pac_platform;

typedef struct {
	uint64_t deadline_tick;
	size_t max_heap_bytes;
	size_t max_script_bytes;
	size_t max_input_bytes;
	size_t max_output_bytes;
	size_t max_native_queries;
} ergopti_pac_limits;

typedef struct {
	ergopti_pac_status status;
	int32_t native_error;
	ergopti_pac_error_domain native_error_domain;
	size_t output_bytes;
	size_t peak_heap_bytes;
	size_t retained_heap_bytes;
	size_t native_queries;
} ergopti_pac_receipt;

ergopti_pac_receipt ergopti_pac_execute(const ergopti_pac_platform *platform,
	const ergopti_pac_limits *limits, const char *helpers, size_t helper_bytes,
	const char *script, size_t script_bytes, const char *url, size_t url_bytes,
	const char *host, size_t host_bytes, char *output, size_t output_capacity);

/* The pinned Duktape configuration invokes this same absolute-clock guard. */
int ergopti_pac_should_interrupt(void *owner);
#endif
