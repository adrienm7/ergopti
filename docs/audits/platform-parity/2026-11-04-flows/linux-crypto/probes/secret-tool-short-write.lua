local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('compat.utf8').install();require('tests.helpers')
local uv=require('luv');local dir=assert(uv.fs_mkdtemp('/tmp/ergopti-audit-secret-XXXXXX'))
local quote=require('adapters.shell_runner').quote
local function put(path,data)local f=assert(io.open(path,'wb'));assert(f:write(data));assert(f:close())end
local tool=dir..'/secret-tool';local stored=dir..'/synthetic-secret'
put(tool,'#!/bin/sh\ncase "$1" in\nstore) cat > '..quote(stored)..';;\nlookup) cat '..quote(stored)..';;\nclear) rm -f '..quote(stored)..';;\nesac\n')
assert(uv.fs_chmod(tool,448))
local Store=require('modules.llm.api_token_store');Store._set_backend_for_test(nil);Store._set_tool_for_test(tool)
local Entries=require('modules.llm.api_entries');Entries._set_path_for_test(dir..'/api_keys.json')
local original_popen=io.popen;local injected=0
io.popen=function(command,mode)
 local pipe=original_popen(command,mode)
 if mode=='w' and command:find(tool,1,true) then
  return {write=function(_,data)injected=injected+1;assert(pipe:write(data:sub(1,3)));return nil,'controlled short write' end,
   close=function()return pipe:close()end}
 end
 return pipe
end
local entry=assert(Entries.add({provider='cerebras',token='SYNTHETIC_ONLY_COMPLETE_KEY',label='fixture'}),'public add unexpectedly refused')
io.popen=original_popen
assert(injected==1)
local f=assert(io.open(stored,'rb'));local actual=f:read('*a');f:close();assert(actual=='SYN')
local id=entry.id;assert(entry.token=='SYNTHETIC_ONLY_COMPLETE_KEY')
Entries._set_path_for_test(dir..'/api_keys.json')
local loaded=assert(Entries.get(id));assert(loaded.token=='SYN')
print('Public add accepted a secret-service reference after stdin write returned nil; backend stored 3/27 synthetic bytes.')
print('Current RAM token=complete synthetic key; next source load resolves only truncated SYN. Original token was never stored in metadata.')
Store._set_tool_for_test(nil)
for name in uv.fs_scandir_next,assert(uv.fs_scandir(dir))do assert(uv.fs_unlink(dir..'/'..name))end
assert(uv.fs_rmdir(dir));print('PASS: scratch tool+files retired; no live secret service, user key or clipboard touched.')
