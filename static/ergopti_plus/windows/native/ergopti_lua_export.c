/* static/ergopti_plus/windows/native/ergopti_lua_export.c
 *
 * The Windows driver's Lua export step: one bounded process that runs the shared
 * _shared/layouts/engine/composer/export_step.lua for the layout editor window,
 * as the macOS and Linux hosts run it with their own Lua (manager_bridge.lua
 * lua_export). The caller passes the shared folder and the step name in argv,
 * and the step's JSON input on stdin or, as the AutoHotkey host does (its
 * process runner has no stdin), in a file named by a third argument. stdout
 * carries the result's JSON text with exit code 0, or one "<code>\t<detail>"
 * line with a non-zero exit code; stderr only says how to call it.
 *
 * Built against the pinned Lua 5.4 release (ergopti_lua_export.pin.json) by
 * tools/build/build_windows_lua_export.ps1; the same file builds with gcc for
 * the local proof (tools/build/build-lua-export-host.cjs).
 *
 * Restricted on purpose: only the base, string, table, math and utf8 libraries
 * are linked and opened; io, os, debug, package and coroutine are not compiled
 * in, and the base library's file loaders, load and print are removed. require
 * is this host's own: it reads <shared>/<a/b/c>.lua for a dotted lower-case
 * module name, as text only, and nothing else.
 *
 * Exit codes: 0 result written, 1 the step refused (its code on stdout),
 * 2 usage, 3 the host could not run the step (lua_export_host on stdout). */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#endif

#ifndef ERGOPTI_LUA_EXPORT_FINGERPRINT
#error "ERGOPTI_LUA_EXPORT_FINGERPRINT names the pinned sources this host is built from"
#endif
/* Passed as a bare hex token (/D or -D), so no shell has to quote a C string. */
#define HOST_STRINGIFY_(value) #value
#define HOST_STRINGIFY(value) HOST_STRINGIFY_(value)
#define HOST_FINGERPRINT HOST_STRINGIFY(ERGOPTI_LUA_EXPORT_FINGERPRINT)

#define HOST_FAILURE "lua_export_host"
#define EXIT_REFUSED 1
#define EXIT_USAGE 2
#define EXIT_HOST 3
/* A shared module or the layout defaults are far smaller; a larger file is refused. */
#define MAX_SOURCE_BYTES (4u * 1024u * 1024u)
#define MAX_MODULE_NAME 128u
#define MAX_PATH_BYTES 4096u
#define LOADED_KEY "ergopti.lua_export.loaded"
#define ROOT_KEY "ergopti.lua_export.root"

/* The step runner: the shared modules do the work, the host only carries bytes. */
static const char DRIVER[] =
	"local defaults_text = ...\n"
	"local Json = require('core.text.engine.json')\n"
	"local ExportStep = require('layouts.engine.composer.export_step')\n"
	"local settings, problem = ExportStep.settings(Json.decode(defaults_text))\n"
	"if not settings then error(problem, 0) end\n"
	"return settings.max_bytes, function(step, input)\n"
	"  return ExportStep.run(settings, step, input)\n"
	"end\n";

/* Opens a UTF-8 path; Windows needs the wide form for a non-ASCII profile folder. */
static FILE *open_utf8(const char *path)
{
#ifdef _WIN32
	wchar_t wide[MAX_PATH_BYTES];
	if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, (int)MAX_PATH_BYTES) == 0)
		return NULL;
	return _wfopen(wide, L"rb");
#else
	return fopen(path, "rb");
#endif
}

/* Reads a whole file of at most MAX_SOURCE_BYTES; NULL with a reason on failure. */
static char *read_file(const char *path, size_t *length, const char **reason)
{
	FILE *file = open_utf8(path);
	char *bytes;
	size_t used = 0;
	size_t got;
	if (file == NULL) {
		*reason = "cannot be opened";
		return NULL;
	}
	bytes = (char *)malloc(MAX_SOURCE_BYTES + 1u);
	if (bytes == NULL) {
		fclose(file);
		*reason = "out of memory";
		return NULL;
	}
	while ((got = fread(bytes + used, 1, MAX_SOURCE_BYTES + 1u - used, file)) > 0) {
		used += got;
		if (used > MAX_SOURCE_BYTES) break;
	}
	if (ferror(file) || used > MAX_SOURCE_BYTES) {
		fclose(file);
		free(bytes);
		*reason = used > MAX_SOURCE_BYTES ? "is larger than its bound" : "cannot be read";
		return NULL;
	}
	fclose(file);
	*length = used;
	return bytes;
}

/* A module name the host admits: dotted lower-case words, nothing that leaves the folder. */
static int admitted_module(const char *name, size_t length)
{
	size_t index;
	if (length == 0 || length > MAX_MODULE_NAME || name[0] == '.' || name[length - 1] == '.') return 0;
	for (index = 0; index < length; index++) {
		char c = name[index];
		if (c == '.') {
			if (name[index + 1] == '.') return 0;
		} else if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')) {
			return 0;
		}
	}
	return 1;
}

/* require(name): <shared>/<name with dots as slashes>.lua, run once, as text only. */
static int host_require(lua_State *L)
{
	size_t length = 0;
	const char *name = luaL_checklstring(L, 1, &length);
	const char *root;
	char path[MAX_PATH_BYTES];
	size_t root_length = 0, index;
	char *source;
	size_t source_length = 0;
	const char *reason = NULL;
	if (!admitted_module(name, length)) return luaL_error(L, "module name refused: %s", name);
	lua_getfield(L, LUA_REGISTRYINDEX, LOADED_KEY);
	lua_getfield(L, -1, name);
	if (!lua_isnil(L, -1)) return 1;
	lua_pop(L, 1);
	lua_getfield(L, LUA_REGISTRYINDEX, ROOT_KEY);
	root = lua_tolstring(L, -1, &root_length);
	if (root_length + 1u + length + 4u + 1u > sizeof(path)) return luaL_error(L, "module path too long: %s", name);
	memcpy(path, root, root_length);
	path[root_length] = '/';
	for (index = 0; index < length; index++) path[root_length + 1u + index] = name[index] == '.' ? '/' : name[index];
	memcpy(path + root_length + 1u + length, ".lua", 5u);
	lua_pop(L, 1);
	source = read_file(path, &source_length, &reason);
	if (source == NULL) return luaL_error(L, "module %s %s", name, reason);
	lua_pushfstring(L, "@%s", name);
	if (luaL_loadbufferx(L, source, source_length, lua_tostring(L, -1), "t") != LUA_OK) {
		free(source);
		return lua_error(L);
	}
	free(source);
	lua_pushstring(L, name);
	lua_call(L, 1, 1);
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		lua_pushboolean(L, 1);
	}
	lua_pushvalue(L, -1);
	lua_setfield(L, -4, name);
	return 1;
}

/* A state with only the admitted libraries and this host's require. */
static lua_State *new_sandbox(const char *root)
{
	static const luaL_Reg libraries[] = {
		{ LUA_GNAME, luaopen_base },
		{ LUA_STRLIBNAME, luaopen_string },
		{ LUA_TABLIBNAME, luaopen_table },
		{ LUA_MATHLIBNAME, luaopen_math },
		{ LUA_UTF8LIBNAME, luaopen_utf8 },
		{ NULL, NULL }
	};
	static const char *const removed[] = { "dofile", "loadfile", "load", "print", NULL };
	const luaL_Reg *library;
	const char *const *global;
	lua_State *L = luaL_newstate();
	if (L == NULL) return NULL;
	for (library = libraries; library->func != NULL; library++) {
		luaL_requiref(L, library->name, library->func, 1);
		lua_pop(L, 1);
	}
	for (global = removed; *global != NULL; global++) {
		lua_pushnil(L);
		lua_setglobal(L, *global);
	}
	lua_newtable(L);
	lua_setfield(L, LUA_REGISTRYINDEX, LOADED_KEY);
	lua_pushstring(L, root);
	lua_setfield(L, LUA_REGISTRYINDEX, ROOT_KEY);
	lua_pushcfunction(L, host_require);
	lua_setglobal(L, "require");
	return L;
}

/* The identity the AutoHotkey host and the build compare with the committed JSON. */
static void write_identity(void)
{
	printf("{\"schema_version\":1,\"host\":\"ergopti_lua_export\",\"lua_release\":\"%s\","
		"\"source_fingerprint\":\"%s\"}\n", LUA_RELEASE, HOST_FINGERPRINT);
}

static int host_failure(const char *detail)
{
	printf("%s\t%s\n", HOST_FAILURE, detail != NULL ? detail : "unknown failure");
	return EXIT_HOST;
}

/* Reads a stream up to bound + 1 bytes: the step itself refuses an input over its bound. */
static char *read_input(FILE *stream, size_t bound, size_t *length)
{
	char *bytes = (char *)malloc(bound + 2u);
	size_t used = 0;
	size_t got;
	if (bytes == NULL) return NULL;
	while (used <= bound && (got = fread(bytes + used, 1, bound + 1u - used, stream)) > 0) used += got;
	if (ferror(stream)) {
		free(bytes);
		return NULL;
	}
	*length = used;
	return bytes;
}

static int run_step(const char *root, const char *step, const char *input_path)
{
	char defaults_path[MAX_PATH_BYTES];
	char *defaults;
	size_t defaults_length = 0;
	const char *reason = NULL;
	char *input;
	/* Initialized: MSVC /W4 /WX (C4701) cannot see that the stream == NULL path,
	 * which skips read_input, returns before input_length is read. */
	size_t input_length = 0;
	lua_Integer bound;
	int status;
	lua_State *L;
	if (strlen(root) + sizeof("/layouts/data/defaults.json") > sizeof(defaults_path))
		return host_failure("the shared folder path is too long");
	snprintf(defaults_path, sizeof(defaults_path), "%s/layouts/data/defaults.json", root);
	defaults = read_file(defaults_path, &defaults_length, &reason);
	if (defaults == NULL) return host_failure("the layout defaults cannot be read");
	L = new_sandbox(root);
	if (L == NULL) {
		free(defaults);
		return host_failure("no Lua state");
	}
	if (luaL_loadbufferx(L, DRIVER, sizeof(DRIVER) - 1u, "=ergopti_lua_export", "t") != LUA_OK) {
		free(defaults);
		status = host_failure(lua_tostring(L, -1));
		lua_close(L);
		return status;
	}
	lua_pushlstring(L, defaults, defaults_length);
	free(defaults);
	if (lua_pcall(L, 1, 2, 0) != LUA_OK || !lua_isinteger(L, -2) || lua_tointeger(L, -2) <= 0) {
		status = host_failure(lua_isstring(L, -1) ? lua_tostring(L, -1) : "the export step settings are refused");
		lua_close(L);
		return status;
	}
	bound = lua_tointeger(L, -2);
	if (input_path != NULL) {
		FILE *stream = open_utf8(input_path);
		input = stream == NULL ? NULL : read_input(stream, (size_t)bound, &input_length);
		if (stream != NULL) fclose(stream);
	} else {
		input = read_input(stdin, (size_t)bound, &input_length);
	}
	if (input == NULL) {
		lua_close(L);
		return host_failure("the step's input cannot be read");
	}
	lua_pushstring(L, step);
	lua_pushlstring(L, input, input_length);
	free(input);
	if (lua_pcall(L, 2, 3, 0) != LUA_OK) {
		status = host_failure(lua_tostring(L, -1));
		lua_close(L);
		return status;
	}
	if (lua_toboolean(L, -3)) {
		size_t output_length = 0;
		const char *output = lua_tolstring(L, -2, &output_length);
		if (output == NULL || fwrite(output, 1, output_length, stdout) != output_length || fflush(stdout) != 0) {
			lua_close(L);
			return host_failure("the result cannot be written");
		}
		lua_close(L);
		return 0;
	}
	printf("%s\t%s\n", luaL_optstring(L, -2, HOST_FAILURE), luaL_optstring(L, -1, ""));
	lua_close(L);
	return EXIT_REFUSED;
}

static int host_main(int argc, char **argv)
{
#ifdef _WIN32
	/* Binary streams: the JSON bytes pass unchanged, with no CRLF translation. */
	if (_setmode(_fileno(stdin), _O_BINARY) == -1 || _setmode(_fileno(stdout), _O_BINARY) == -1)
		return host_failure("binary streams refused");
#endif
	if (argc == 2 && strcmp(argv[1], "--identity") == 0) {
		write_identity();
		return 0;
	}
	if ((argc != 3 && argc != 4) || argv[1][0] == '\0' || argv[2][0] == '\0' || (argc == 4 && argv[3][0] == '\0')) {
		fprintf(stderr, "usage: ergopti_lua_export <shared folder> <read|xkb> [<input file>] < input.json\n"
			"       ergopti_lua_export --identity\n");
		return EXIT_USAGE;
	}
	return run_step(argv[1], argv[2], argc == 4 ? argv[3] : NULL);
}

#ifndef ERGOPTI_LUA_EXPORT_NO_MAIN
int main(int argc, char **argv)
{
	return host_main(argc, argv);
}
#endif
