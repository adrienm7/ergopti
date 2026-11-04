import ctypes

lua = ctypes.CDLL("liblua5.4.so.0")
lua.luaL_newstate.restype = ctypes.c_void_p
L = lua.luaL_newstate()
lua.luaL_openlibs.argtypes = [ctypes.c_void_p]
lua.luaL_openlibs(L)
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
src = r"""
local base='/workspace/ergopti/static/ergopti_plus/'
package.path=base..'_shared/lua/?.lua;'..base..'_shared/lua/?/init.lua;'..base..'linux/?.lua;'..package.path
package.loaded['logger.shim']=setmetatable({}, {__index=function() return function() end end})
local prefix=require('modules.dynamic_hotstrings.prefix_rules')
local rows=prefix.build({phone_number='0612345678'})
for _,r in ipairs(rows) do print('PREFIX',r.trigger,r.replacement,'auto='..tostring(r.auto_expand)) end
local engine=require('hotstring_engine').new()
engine:load_mappings(rows)
for c in ('0612'):gmatch('.') do local result=engine:on_char(c); if result then print('ENGINE', c, result.trigger, result.replacement) end end
local dyn=require('dynamic_hotstrings')
dyn.register_date_rules('★')
for _,word in ipairs({'td','@td','xtd','word@td'}) do
 local match=dyn.match_buffer(word,'dynamichotstrings',function() return true end,true)
 print('DATE',word, match and match.rule.suffix or 'NO MATCH')
end
"""
status = lua.luaL_loadstring(L, src.encode())
if status == 0:
    status = lua.lua_pcallk(L, 0, -1, 0, 0, None)
if status:
    raise RuntimeError(lua.lua_tolstring(L, -1, None).decode())
