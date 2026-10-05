--- tests/unit/modules/llm/test_runtime_publication_admission.lua

--- ==============================================================================
--- MODULE: Registered Ollama Runtime Regression Cases
--- DESCRIPTION:
--- Preserves independent controlled receipts through the normal Linux helpers.
--- Actual filesystem/process/serve/UI acceptance remains a separate gate.
--- ==============================================================================

local helpers = require("tests.helpers")
local names = {"llm.bootstrap_budget", "llm.runtime_repair", "modules.llm.runtime_source", "modules.llm.owned_timer", "modules.llm.runtime_composition", "infra.logger", "logger.shim", "infra.i18n", "llm.profile_selector", "infra.llm_bridge", "infra.manifest_reader", "infra.config_paths", "config_outdated", "toml_codec.writer", "infra.llm_preferences", "modules.llm.profiles"}
local previous = {}
for _, name in ipairs(names) do previous[name] = package.loaded[name] end
local function run_registered()
-- Exercises actual shared Writer nil-adapter publication with controlled native
-- file ports. No disk/native qualification or weakened legacy assertion claim.
local logger={};for _,name in ipairs({'debug','info','warn','error'})do logger[name]=function()end end
package.loaded['infra.logger']=logger;package.loaded['logger.shim']=logger
package.loaded['infra.i18n']={get=function(key)return key end}
local Writer = helpers.load_module("toml_codec.writer")
local function eq(a,b)assert(a==b,'expected '..tostring(b)..' got '..tostring(a))end
local function test(name, body) helpers.it(name .. " (ollama-runtime)", body) end
local function fixture()
 return {live='old',revision=5,epoch=2,opens=0,renames=0,reads=0,ordinary=0,admitted=0}
end
local function controlled(w,action)
 local old_open,old_rename,old_remove=io.open,os.rename,os.remove
 io.open=function(path,mode)
  w.opens=w.opens+1
  if mode=='w' then
   return {write=function(_,bytes)w.stage=bytes;return true end,close=function()return true end}
  end
  return {read=function()
   w.reads=w.reads+1;if w.on_read then w.on_read()end;return w.live
  end,close=function()return true end}
 end
 os.rename=function()w.renames=w.renames+1;w.live=w.stage;w.stage=nil;return true end
 os.remove=function()w.stage=nil;return true end
 local ok,a,b=pcall(action)
 io.open,os.rename,os.remove=old_open,old_rename,old_remove
 if not ok then error(a,0)end
 return a,b
end
local function guard(w)return function()return w.revision==5 and w.epoch==2 end end
local function publish(w,admission,content)
 return controlled(w,function()return Writer.publish_if_unchanged('/controlled/config.toml',content or 'new',nil,{status='ok',content='old'},nil,admission)end)
end
test('nil legacy admission preserves existing publication',function()
 local w=fixture();eq(publish(w,nil),true);eq(w.live,'new');eq(w.renames,1)
end)
test('captured final admission permits exact current publication',function()
 local w=fixture();eq(publish(w,guard(w)),true);eq(w.live,'new');eq(w.reads,1)
end)
test('last fallback classified read revocation prevents native publication',function()
 local w=fixture();w.on_read=function()w.revision=6 end
 eq(publish(w,guard(w)),false);eq(w.live,'old');eq(w.renames,0);eq(w.stage,nil)
end)
test('last fallback classified read app lifetime revocation prevents rename',function()
 local w=fixture();w.on_read=function()w.epoch=3 end
 eq(publish(w,guard(w)),false);eq(w.live,'old');eq(w.renames,0)
end)
test('unchanged acknowledgment requires current final admission',function()
 local w=fixture();w.on_read=function()w.revision=6 end
 eq(publish(w,guard(w),'old'),false);eq(w.live,'old');eq(w.renames,0)
end)
test('final admission exception refuses and retires own staging',function()
 local w=fixture();eq(publish(w,function()error('revoked authority')end),false)
 eq(w.live,'old');eq(w.renames,0);eq(w.stage,nil)
end)
test('nonliteral final verdict refuses publication',function()
 local w=fixture();eq(publish(w,function()return 1 end),false);eq(w.renames,0)
end)
test('malformed admission acquires no staging or native IO',function()
 local w=fixture();eq(publish(w,{}),false);eq(w.opens,0);eq(w.renames,0)
end)
test('ordinary conditional adapter cannot silently discard final guard',function()
 local w=fixture();local adapter={read_with_status=function()return w.live,'ok' end,
 write_if_unchanged=function()w.ordinary=w.ordinary+1;return true end}
 eq(Writer.publish_if_unchanged('/controlled/config.toml','new',adapter,{status='ok',content='old'},nil,guard(w)),false)
 eq(w.ordinary,0);eq(w.live,'old')
end)
test('advertised adapter receives the exact captured guard',function()
 local w=fixture();local admission=guard(w);local received
 local adapter={read_with_status=function()return w.live,'ok' end,
 write_if_unchanged_admitted=function(_,content,expected,on_error,fn)
  received=fn;w.admitted=w.admitted+1
  if fn()~=true or expected.content~=w.live then return false end
  w.live=content;return true
 end}
 eq(Writer.publish_if_unchanged('/controlled/config.toml','new',adapter,{status='ok',content='old'},nil,admission),true)
 eq(received,admission);eq(w.admitted,1);eq(w.live,'new')
end)
test('legacy adapter keeps its authoritative four-argument conditional invocation',function()
 local arity;local adapter={read_with_status=function()return 'old','ok' end,
 write_if_unchanged=function(...)arity=select('#',...);return true end}
 eq(Writer.publish_if_unchanged('/controlled/config.toml','new',adapter,{status='ok',content='old'}),true);eq(arity,4)
end)
test('classified adapter read cannot replace the captured admission publisher',function()
 local original,foreign=0,0;local adapter={}
 adapter.write_if_unchanged_admitted=function(_,_,_,on_error,admission)
  original=original+1;return admission()==true
 end
 adapter.read_with_status=function()
  adapter.write_if_unchanged_admitted=function()foreign=foreign+1;return true end
  return 'old','ok'
 end
 eq(Writer.publish_if_unchanged('/controlled/config.toml','new',adapter,{status='ok',content='old'},nil,function()return true end),true)
 eq(original,1);eq(foreign,0)
end)

end
local called, detail = pcall(run_registered)
for _, name in ipairs(names) do package.loaded[name] = previous[name] end
if not called then error(detail, 0) end
