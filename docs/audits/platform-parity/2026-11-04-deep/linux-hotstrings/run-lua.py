import ctypes, pathlib, sys

lua = ctypes.CDLL("liblua5.4.so.0")
lua.luaL_newstate.restype = ctypes.c_void_p
lua.luaL_openlibs.argtypes = [ctypes.c_void_p]
lua.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lua.lua_pcallk.argtypes = [
    ctypes.c_void_p,
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_longlong,
    ctypes.c_void_p,
]
lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
lua.lua_tolstring.restype = ctypes.c_char_p
state = lua.luaL_newstate()
lua.luaL_openlibs(state)
status = lua.luaL_loadstring(state, pathlib.Path(sys.argv[1]).read_bytes())
if status == 0:
    status = lua.lua_pcallk(state, 0, -1, 0, 0, None)
if status:
    raise RuntimeError(lua.lua_tolstring(state, -1, None).decode())
