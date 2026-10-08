/* No network or OS policy lives here: platform bridges own native observations. */
#include "pac_runtime.h"
#include "duktape.h"
#include <stdlib.h>
#include <string.h>
#if !defined(DUK_USE_INTERRUPT_COUNTER) || !defined(DUK_USE_EXEC_TIMEOUT_CHECK)
#error The PAC worker requires the canonical Duktape absolute-clock configuration.
#endif

typedef union {
	size_t bytes;
	long double alignment;
	void *pointer_alignment;
} allocation_header;

typedef struct {
	const ergopti_pac_platform *platform;
	const ergopti_pac_limits *limits;
	ergopti_pac_receipt receipt;
	int budget_expired;
	int native_failed;
	int memory_refused;
} execution;

int ergopti_pac_should_interrupt(void *owner)
{
	execution *state = (execution *)owner;
	if (state == NULL || state->platform->tick(state->platform->owner) >= state->limits->deadline_tick) {
		if (state != NULL) state->budget_expired = 1;
		return 1;
	}
	return 0;
}

static void *allocate(void *owner, duk_size_t bytes)
{
	execution *state = (execution *)owner;
	allocation_header *block;
	size_t total;
	if (bytes == 0) return NULL;
	if (bytes > SIZE_MAX - sizeof(allocation_header)) { state->memory_refused = 1; return NULL; }
	total = (size_t)bytes + sizeof(allocation_header);
	if (state->receipt.retained_heap_bytes > state->limits->max_heap_bytes ||
		total > state->limits->max_heap_bytes - state->receipt.retained_heap_bytes) {
		state->memory_refused = 1; return NULL;
	}
	block = (allocation_header *)malloc(total);
	if (block == NULL) { state->memory_refused = 1; return NULL; }
	block->bytes = total;
	state->receipt.retained_heap_bytes += total;
	if (state->receipt.retained_heap_bytes > state->receipt.peak_heap_bytes)
		state->receipt.peak_heap_bytes = state->receipt.retained_heap_bytes;
	return block + 1;
}

static void release(void *owner, void *pointer)
{
	execution *state = (execution *)owner;
	allocation_header *block;
	if (pointer == NULL) return;
	block = (allocation_header *)pointer - 1;
	state->receipt.retained_heap_bytes -= block->bytes;
	free(block);
}

static void *resize(void *owner, void *pointer, duk_size_t bytes)
{
	execution *state = (execution *)owner;
	allocation_header *previous, *replacement;
	size_t total, retained;
	if (pointer == NULL) return allocate(owner, bytes);
	if (bytes == 0) { release(owner, pointer); return NULL; }
	previous = (allocation_header *)pointer - 1;
	if (bytes > SIZE_MAX - sizeof(allocation_header)) { state->memory_refused = 1; return NULL; }
	total = (size_t)bytes + sizeof(allocation_header);
	retained = state->receipt.retained_heap_bytes - previous->bytes;
	if (retained > state->limits->max_heap_bytes || total > state->limits->max_heap_bytes - retained) {
		state->memory_refused = 1; return NULL;
	}
	replacement = (allocation_header *)realloc(previous, total);
	if (replacement == NULL) { state->memory_refused = 1; return NULL; }
	replacement->bytes = total;
	state->receipt.retained_heap_bytes = retained + total;
	if (state->receipt.retained_heap_bytes > state->receipt.peak_heap_bytes)
		state->receipt.peak_heap_bytes = state->receipt.retained_heap_bytes;
	return replacement + 1;
}

static void fatal(void *owner, const char *message)
{
	/* A fatal VM error cannot be recovered. Do not create a private-memory dump. */
	(void)owner; (void)message;
	_Exit(125);
}

static execution *context_owner(duk_context *context)
{
	duk_memory_functions memory;
	duk_get_memory_functions(context, &memory);
	return (execution *)memory.udata;
}

static duk_ret_t native_query(duk_context *context)
{
	execution *state = context_owner(context);
	int mode = duk_get_current_magic(context), extended = 0, result;
	duk_size_t argument_bytes = 0;
	const char *argument = NULL;
	char *output;
	ergopti_pac_native_error error = {0, ERGOPTI_PAC_ERROR_NONE};
	size_t length;
	if (ergopti_pac_should_interrupt(state)) return duk_error(context, DUK_ERR_ERROR, "PAC budget expired.");
	if (state->receipt.native_queries >= state->limits->max_native_queries) {
		state->native_failed = 1;
		return duk_error(context, DUK_ERR_ERROR, "PAC native query bound refused.");
	}
	state->receipt.native_queries++;
	if (mode != 1) {
		argument = duk_require_lstring(context, 0, &argument_bytes);
		if (argument_bytes == 0 || argument_bytes > state->limits->max_input_bytes ||
			memchr(argument, 0, argument_bytes) != NULL)
			return duk_error(context, DUK_ERR_TYPE_ERROR, "PAC native argument refused.");
	}
	if (mode == 0) extended = duk_require_boolean(context, 1);
	else if (mode == 1) extended = duk_require_boolean(context, 0);
	/* This buffer uses the accounted VM heap and is released with that heap. */
	output = (char *)duk_push_fixed_buffer(context, state->limits->max_output_bytes + 1);
	memset(output, 0, state->limits->max_output_bytes + 1);
	if (mode == 0) result = state->platform->dns(state->platform->owner, argument, extended, output, state->limits->max_output_bytes + 1, &error);
	else if (mode == 1) result = state->platform->local_addresses(state->platform->owner, extended, output, state->limits->max_output_bytes + 1, &error);
	else result = state->platform->sort_addresses(state->platform->owner, argument, output, state->limits->max_output_bytes + 1, &error);
	if (ergopti_pac_should_interrupt(state)) return duk_error(context, DUK_ERR_ERROR, "PAC budget expired.");
	if (result < 0) {
		state->native_failed = 1;
		state->receipt.native_error = error.code;
		if (error.code != 0 && error.domain >= ERGOPTI_PAC_ERROR_WIN32 && error.domain <= ERGOPTI_PAC_ERROR_POSIX)
			state->receipt.native_error_domain = error.domain;
		return duk_error(context, DUK_ERR_ERROR, "PAC native observation refused.");
	}
	if (result == 0) { duk_pop(context); duk_push_null(context); return 1; }
	length = 0;
	while (length <= state->limits->max_output_bytes && output[length] != 0) length++;
	if (length == 0 || length > state->limits->max_output_bytes) {
		state->native_failed = 1;
		return duk_error(context, DUK_ERR_ERROR, "PAC native output refused.");
	}
	duk_push_lstring(context, output, length);
	duk_remove(context, -2);
	return 1;
}

static void bind_native(duk_context *context, const char *name, int mode)
{
	duk_push_c_function(context, native_query, DUK_VARARGS);
	duk_set_magic(context, -1, mode);
	duk_put_global_string(context, name);
}

ergopti_pac_receipt ergopti_pac_execute(const ergopti_pac_platform *platform,
	const ergopti_pac_limits *limits, const char *helpers, size_t helper_bytes,
	const char *script, size_t script_bytes, const char *url, size_t url_bytes,
	const char *host, size_t host_bytes, char *output, size_t output_capacity)
{
	execution state;
	duk_context *context = NULL;
	const char *selection;
	duk_size_t selection_bytes;
	memset(&state, 0, sizeof(state));
	state.platform = platform; state.limits = limits;
	state.receipt.status = ERGOPTI_PAC_INVALID_INPUT;
	if (output != NULL && output_capacity > 0) output[0] = 0;
	if (platform == NULL || limits == NULL || platform->tick == NULL || platform->dns == NULL ||
		platform->local_addresses == NULL || platform->sort_addresses == NULL || helpers == NULL || script == NULL ||
		url == NULL || host == NULL || output == NULL || limits->max_heap_bytes == 0 || limits->max_native_queries == 0 ||
		limits->max_output_bytes == 0 || limits->max_output_bytes == SIZE_MAX ||
		output_capacity <= limits->max_output_bytes || helper_bytes == 0 || helper_bytes > limits->max_script_bytes ||
		script_bytes == 0 || script_bytes > limits->max_script_bytes || url_bytes == 0 || url_bytes > limits->max_input_bytes ||
		host_bytes == 0 || host_bytes > limits->max_input_bytes || memchr(url, 0, url_bytes) != NULL || memchr(host, 0, host_bytes) != NULL)
		return state.receipt;
	if (ergopti_pac_should_interrupt(&state)) { state.receipt.status = ERGOPTI_PAC_BUDGET_EXPIRED; return state.receipt; }
	context = duk_create_heap(allocate, resize, release, &state, fatal);
	if (context == NULL) { state.receipt.status = ERGOPTI_PAC_MEMORY_REFUSED; return state.receipt; }
	bind_native(context, "__ergoptiDns", 0);
	bind_native(context, "__ergoptiLocalAddresses", 1);
	bind_native(context, "__ergoptiSortAddresses", 2);
	state.receipt.status = ERGOPTI_PAC_SCRIPT_REFUSED;
	if (duk_peval_lstring_noresult(context, helpers, helper_bytes) != 0 ||
		duk_peval_lstring_noresult(context, script, script_bytes) != 0) goto finished;
	duk_get_global_string(context, "FindProxyForURL");
	duk_push_lstring(context, url, url_bytes);
	duk_push_lstring(context, host, host_bytes);
	if (duk_pcall(context, 2) != 0) goto finished;
	state.receipt.status = ERGOPTI_PAC_OUTPUT_REFUSED;
	if (!duk_is_string(context, -1)) goto finished;
	selection = duk_get_lstring(context, -1, &selection_bytes);
	if (selection_bytes == 0 || selection_bytes > limits->max_output_bytes || memchr(selection, 0, selection_bytes) != NULL) goto finished;
	if (ergopti_pac_should_interrupt(&state)) goto finished;
	memcpy(output, selection, selection_bytes); output[selection_bytes] = 0;
	state.receipt.output_bytes = selection_bytes;
	state.receipt.status = ERGOPTI_PAC_OK;
finished:
	duk_destroy_heap(context);
	if (state.budget_expired) state.receipt.status = ERGOPTI_PAC_BUDGET_EXPIRED;
	else if (state.native_failed) state.receipt.status = ERGOPTI_PAC_NATIVE_REFUSED;
	else if (state.memory_refused) state.receipt.status = ERGOPTI_PAC_MEMORY_REFUSED;
	if (state.receipt.status != ERGOPTI_PAC_OK) { output[0] = 0; state.receipt.output_bytes = 0; }
	return state.receipt;
}
