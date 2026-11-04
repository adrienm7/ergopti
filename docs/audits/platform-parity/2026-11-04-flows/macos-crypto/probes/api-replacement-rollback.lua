-- Use original persistence fixture setup, replace its TokenCrypto stand-in with actual module
-- over an in-memory signed-helper task boundary. Real coordinator + real token owner execute.
local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..root..'macos/tests/stubs/?.lua;'..package.path
local helpers=require('tests.helpers')
local keychain={['local-omlx']='OLD-SYNTHETIC-SECRET'}
local mutations=0
function audit_install_crypto(fixture)
 package.loaded['modules.llm.api_token_crypto']=nil
 package.loaded['infra.timings']={sec=function() return 10 end}
 package.loaded['platform.remap.lease_helper']={resolve=function() return '/synthetic/signed-launcher' end}
 package.loaded['adapters.timer_scheduler']={after=function() return {timer=true,committed=true},true end,cancel=function(h) h.timer=nil;return true end,now=function() return 0 end}
 package.loaded['adapters.shell_runner']={spawn=function(executable,args,done)
  assert(executable=='/synthetic/signed-launcher')
  local input
  return {set_input=function(s) input=s;return true end,terminate=function() return true,'settled' end,start=function()
   if args[1]=='--keychain-token-write' then keychain[args[2]]=input;mutations=mutations+1;done(0,'','')
   elseif args[1]=='--keychain-token-delete' then keychain[args[2]]=nil;done(0,'','')
   else done(keychain[args[2]] and 0 or 70,keychain[args[2]] or '','') end
   return true
  end}
 end}
 require('modules.llm.api_token_crypto')
end
local path=root..'macos/tests/unit/modules/llm/remote/test_api_entry_persistence_async.lua'
local f=assert(io.open(path));local src=f:read('*a');f:close()
local prefix=src:sub(1,assert(src:find('helpers.describe(',1,true))-1)
local anchor='\tpackage.loaded["modules.llm"] = nil'
assert(prefix:find(anchor,1,true))
prefix=prefix:gsub(anchor:gsub('(%W)','%%%1'),'\taudit_install_crypto(fixture)\n'..anchor,1)
local with_fixture=assert(load(prefix..'\nreturn with_persistence_fixture','@original-persistence-fixture-with-native-port-install','t',_G))()
local prior={version=1,entries={{id='local-omlx',provider='omlx',base_url='http://127.0.0.1:8000/v1',token='keychain:local-omlx',model='old-model'}},active_id='local-omlx',pending_keychain_deletes={}}
local store={llm_api_state_v1=prior}
with_fixture({initial_store=store,corrupt_on_write=2,local_provider='omlx'},function(llm,fixture)
 assert(llm.load_api_entries()==true)
 assert(keychain['local-omlx']=='OLD-SYNTHETIC-SECRET')
 fixture.api_remote.set_entries{{id='local-omlx',provider='omlx',base_url='http://127.0.0.1:8000/v1',token='NEW-SYNTHETIC-SECRET',model='old-model'}}
 fixture.api_remote.set_active_entry_id('local-omlx')
 local result
 llm.persist_api_entries(function(ok,reason,durable) result={ok=ok,reason=reason,durable=durable} end)
 assert(result and result.ok==false and result.reason=='settings_readback_failed')
 assert(store.llm_api_state_v1.entries[1].model=='old-model')
 assert(store.llm_api_state_v1.entries[1].token=='keychain:local-omlx')
 assert(keychain['local-omlx']=='NEW-SYNTHETIC-SECRET')
 print('result='..result.reason..'; durable='..tostring(result.durable))
 print('prior_metadata_restored=true; same_keychain_reference_retained=true; referenced_secret_is_NEW_not_OLD=true; native_write_count='..mutations)
end)
print('Actual coordinator+TokenCrypto; all settings/SecItem effects in memory; no live Keychain/network/clipboard.')
