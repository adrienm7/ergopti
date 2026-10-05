--- tests/unit/modules/llm/test_runtime_native_claim.lua

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
-- Executes the actual candidate's narrow lexical claim functions, without a
-- daemon, mocked copies of those guards, or native filesystem/process calls.
local fh = assert(io.open(helpers.driver_root() .. "/modules/llm/prediction_engine.lua", "r"))
local source=assert(fh:read('*a'));assert(fh:close())
local begin=source:find('\tfunction engine.admit_write',1,true) or source:find('\tfunction engine.publish_enabled',1,true)
local finish=source:find('\tlocal ok, owner, reason = pcall',assert(begin),true)
assert(finish,'actual lexical claim boundary must be present')
local claims=source:sub(begin,finish-1)
local factory=assert((loadstring or load)([[return function(enabled)
local _enabled,_scope_owner,_enable_generation,_runtime_app_epoch=enabled,nil,5,2
local engine={};local pause=nil
local function _is_paused()if pause then return pause()end;return false end
]]..claims..[[
return engine,{
state=function()return _enabled,_enable_generation,_runtime_app_epoch end,
on_pause=function(fn)pause=fn end,
advance_epoch=function()_runtime_app_epoch=_runtime_app_epoch+1 end,
advance_revision=function()_enable_generation=_enable_generation+1 end,
acquire=function()_scope_owner={}end,
}
end]],'actual-runtime-native-claims'))()
local function eq(actual,expected)assert(actual==expected,'expected '..tostring(expected)..' got '..tostring(actual))end
local function test(name, body) helpers.it(name .. " (ollama-runtime)", body) end
test('actual native enable accepts exact revision and app lifetime',function()
 local engine,control=factory(false);eq(engine.publish_enabled(5,2),true);eq(control.state(),true)
end)
test('actual native enable refuses pause callback successor app epoch',function()
 local engine,control=factory(false);control.on_pause(function()control.advance_epoch();return false end)
 eq(engine.publish_enabled(5,2),false);eq(control.state(),false)
end)
test('actual native restore refuses pause callback successor app epoch',function()
 local engine,control=factory(true);control.on_pause(function()control.advance_epoch();return false end)
 eq(engine.restore_disabled(5,2),false);eq(control.state(),true)
end)
test('actual native enable refuses pause callback revision advance',function()
 local engine,control=factory(false);control.on_pause(function()control.advance_revision();return false end)
 eq(engine.publish_enabled(5,2),false);eq(control.state(),false)
end)
test('actual native restore accepts exact originating claim',function()
 local engine,control=factory(true);eq(engine.restore_disabled(5,2),true);eq(control.state(),false)
end)
test('actual final native admission rechecks observer app epoch drift',function()
 local engine,control=factory(false);assert(type(engine.admit_write)=='function','actual lexical final admission required')
 eq(engine.admit_write(5,2,false,function()control.advance_epoch();return true end),false)
end)
test('actual final native admission rechecks observer scope ownership',function()
 local engine,control=factory(false);assert(type(engine.admit_write)=='function','actual lexical final admission required')
 eq(engine.admit_write(5,2,false,function()control.acquire();return true end),false)
end)
test('actual final native admission observes source after pause callback intent',function()
 local engine,control=factory(false);assert(type(engine.admit_write)=='function','actual lexical final admission required')
 local revision=1;control.on_pause(function()revision=2;return false end)
 eq(engine.admit_write(5,2,false,function()return revision==1 end),false)
end)

end
local called, detail = pcall(run_registered)
for _, name in ipairs(names) do package.loaded[name] = previous[name] end
if not called then error(detail, 0) end
