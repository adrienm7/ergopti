/* static/ergopti_plus/windows/native/ergopti_lua_export_test.c
 *
 * Self-test of the Lua export host, built from the same file and Lua objects as
 * the shipped executable and run by the build before it is published
 * (tools/build/build_windows_lua_export.ps1, and build-lua-export-host.cjs with
 * gcc). It proves the restriction is real: the libraries that reach files,
 * processes or the interpreter's internals are absent, require reads only a
 * dotted module name under the shared folder, as text, and runs it once.
 * Usage: ergopti_lua_export_test <shared folder> <empty scratch folder>; exit 0
 * when every check holds. The scratch folder receives two tiny modules. */

#define ERGOPTI_LUA_EXPORT_NO_MAIN
#include "ergopti_lua_export.c"

static int failures = 0;

/* Runs one Lua check in a fresh sandbox; it passes when the chunk returns true. */
static void check(const char *root, const char *label, const char *chunk)
{
	lua_State *L = new_sandbox(root);
	int passed = 0;
	if (L != NULL && luaL_loadbufferx(L, chunk, strlen(chunk), "=check", "t") == LUA_OK &&
		lua_pcall(L, 0, 1, 0) == LUA_OK)
		passed = lua_toboolean(L, -1);
	if (!passed) {
		failures++;
		fprintf(stderr, "FAIL %s%s%s\n", label, L != NULL && lua_isstring(L, -1) ? ": " : "",
			L != NULL && lua_isstring(L, -1) ? lua_tostring(L, -1) : "");
	} else {
		printf("ok   %s\n", label);
	}
	if (L != NULL) lua_close(L);
}

static int dump_writer(lua_State *L, const void *bytes, size_t size, void *file)
{
	(void)L;
	return fwrite(bytes, 1, size, (FILE *)file) == size ? 0 : 1;
}

/* Writes <scratch>/binary_module.lua (a precompiled chunk) and text_module.lua. */
static int write_binary_module(const char *scratch)
{
	char path[MAX_PATH_BYTES];
	FILE *file;
	int written;
	lua_State *L = luaL_newstate();
	if (L == NULL || luaL_loadstring(L, "return 42") != LUA_OK) return 0;
	snprintf(path, sizeof(path), "%s/binary_module.lua", scratch);
	file = fopen(path, "wb");
	if (file == NULL) {
		lua_close(L);
		return 0;
	}
	written = lua_dump(L, dump_writer, file, 1) == 0;
	written = fclose(file) == 0 && written;
	lua_close(L);
	snprintf(path, sizeof(path), "%s/text_module.lua", scratch);
	file = fopen(path, "wb");
	if (file == NULL) return 0;
	written = fputs("return 42\n", file) >= 0 && written;
	return fclose(file) == 0 && written;
}

int main(int argc, char **argv)
{
	const char *root;
	const char *scratch;
	if (argc != 3) {
		fprintf(stderr, "usage: ergopti_lua_export_test <shared folder> <empty scratch folder>\n");
		return EXIT_USAGE;
	}
	root = argv[1];
	scratch = argv[2];
	check(root, "no io, os, debug, package or coroutine library",
		"return io == nil and os == nil and debug == nil and package == nil and coroutine == nil");
	check(root, "no file loader, load or print in the base library",
		"return dofile == nil and loadfile == nil and load == nil and print == nil");
	check(root, "string, table, math and utf8 are there",
		"return type(string.format) == 'function' and type(table.concat) == 'function'"
		" and type(math.floor) == 'function' and type(utf8.char) == 'function'");
	check(root, "require refuses a name that leaves the shared folder",
		"return not pcall(require, '..core.text.engine.json')"
		" and not pcall(require, 'core/text/engine/json')"
		" and not pcall(require, 'Core.text') and not pcall(require, 'core..text')");
	check(root, "require finds no library outside the shared folder",
		"return not pcall(require, 'io') and not pcall(require, 'os') and not pcall(require, 'debug')");
	check(root, "require runs a shared module once and returns its table",
		"local a = require('core.text.engine.json'); local b = require('core.text.engine.json')"
		" return type(a.decode) == 'function' and a == b");
	check(root, "the export step loads with its settings",
		"local ExportStep = require('layouts.engine.composer.export_step')"
		" return ExportStep.STEPS.read == true and ExportStep.STEPS.xkb == true");
	{
		char *usage[] = { "ergopti_lua_export", "only-one-argument", NULL };
		char *identity[] = { "ergopti_lua_export", "--identity", NULL };
		if (host_main(2, usage) != EXIT_USAGE) {
			failures++;
			fprintf(stderr, "FAIL a call without a step is a usage error\n");
		} else {
			printf("ok   a call without a step is a usage error\n");
		}
		if (host_main(2, identity) != 0) {
			failures++;
			fprintf(stderr, "FAIL --identity answers\n");
		} else {
			printf("ok   --identity answers\n");
		}
	}
	/* A precompiled chunk saved as a module is refused: require loads text only. */
	if (!write_binary_module(scratch)) {
		failures++;
		fprintf(stderr, "FAIL the binary module could not be written in %s\n", scratch);
	} else {
		check(scratch, "require refuses a precompiled (binary) module",
			"local ok, problem = pcall(require, 'binary_module')"
			" return not ok and tostring(problem):find('binary', 1, true) ~= nil");
		check(scratch, "the same module as text would run",
			"return pcall(require, 'text_module') and require('text_module') == 42");
	}
	if (failures != 0) {
		fprintf(stderr, "%d check(s) failed\n", failures);
		return 1;
	}
	printf("Lua export host self-test passed\n");
	return 0;
}
