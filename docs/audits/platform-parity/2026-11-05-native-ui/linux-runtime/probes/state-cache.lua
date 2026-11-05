local root=assert(os.getenv('ERGOPTI_AUDIT_SOURCE_ROOT'),'explicit source root required')
local b=root..'/static/ergopti_plus/'
package.path=b..'linux/?.lua;'..b..'linux/?/init.lua;'..b..'_shared/lua/?.lua;'..b..'_shared/lua/?/init.lua;'..package.path
local uv=require('luv')
local sandbox=assert(arg[1], 'owned empty fixture directory required')
local resolver_module=require('modules.llm.ollama_install_resolver')
local runtime=require('modules.llm.ollama_installed_runtime')
local declaration=assert(io.open(b..'_shared/modules/llm/ollama_release.json','rb'))
local release=assert(require('json').decode_lossless(assert(declaration:read('*a'))));assert(declaration:close())
local function resolver() return assert(resolver_module.new{catalogue=release,environment={XDG_DATA_HOME=sandbox},app_dirs=require('app_dirs')}) end
local observer=resolver()
-- Substitute only packaged declaration/location lookup. All policy, native
-- identity, resolver, runtime inventory and state behavior remain production.
package.loaded['modules.llm.ollama_install_resolver']={new=function() return observer end}
local messages={}
package.loaded['logger.shim']={info=function(_,fmt,...) messages[#messages+1]=string.format(fmt,...) end,warn=function(_,fmt,...) messages[#messages+1]=string.format(fmt,...) end}
local state=require('modules.llm.ollama_install_state')
local llm={get_cached_models=function() return {} end,get_base_url=function() return 'http://127.0.0.1:11435' end}
local function capture() return state.capture(llm) end
local allowed,reason,cause=capture()
assert(allowed==false and cause=='absent')
local installer=resolver()
assert(installer.prepare{explicit_consent=true,authorized=function() return true end})
local p=installer.plan()
for _,path in ipairs{p.directory,p.directory..'/bin',p.directory..'/lib',p.libraries} do assert(uv.fs_mkdir(path,448)) end
local function file(path,data,mode)
 local fd=assert(uv.fs_open(path,'wx',mode));assert(uv.fs_write(fd,data,0)==#data);assert(uv.fs_close(fd))
end
file(p.executable,'#!/bin/sh\nexit 0\n',493)
file(p.libraries..'/fixture.so','fixture',420)
assert(runtime.capture(installer).status=='installed','native healthy control inventory must qualify')
state.note_repair{ok=true,origin='http://127.0.0.1:11435'}
allowed,reason,cause=capture()
local current,why=observer.current()
assert(current==false and why=='install_ancestor_substituted')
assert(allowed==false and cause=='absent' and reason=='model_browser.reason_ollama_missing')
print('ADVERSE installed=true observer_current=false cause='..cause..' reason='..reason)
print('VISIBILITY '..table.concat(messages,' | '))
state._reset()
package.loaded['modules.llm.ollama_install_resolver']={new=resolver}
allowed,reason,cause=capture()
assert(allowed==true and cause=='installed' and reason==nil)
print('HEALTHY fresh_observer cause='..cause)
-- Native refusal still fails closed under a fresh observer.
assert(uv.fs_chmod(p.executable,384))
allowed,reason,cause=capture()
assert(allowed==false and cause=='absent')
print('REFUSAL nonexecutable cause='..cause)
