/* tools/test/fixtures/lua54-provider-entry.c */
/* Official Lua API and dlsym only; no guessed interpreter/FFI object layout. */
#include <dlfcn.h>
#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>

int main(int argc, char **argv) {
    if (argc != 2) return 1;
    lua_State *state = luaL_newstate();
    if (state == NULL) return 1;
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) { lua_close(state); return 1; }
    dlerror();
    void *cffi = dlsym(library, "luaopen_cffi");
    const char *first_error = dlerror();
    void *ffi = dlsym(library, "luaopen_ffi");
    const char *second_error = dlerror();
    int admitted = first_error == NULL && second_error == NULL && cffi != NULL && ffi != NULL && cffi == ffi;
    int closed = dlclose(library) == 0;
    lua_close(state);
    if (!admitted || !closed) return 1;
    return puts("Native Lua54 provider: same nonnull dynamic entries") < 0 ? 1 : 0;
}
