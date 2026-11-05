-- Replay frozen original-owner UI probe with its acknowledged save port replaced
-- by the registered fixture's existing ORIGINAL Config real-write option.
local root=assert(arg[1],"Pass repository root")
local temporary=assert(arg[2],"Pass an existing private temporary directory")
local here=assert(arg[0]:match("^(.*)/[^/]+$"),"Invoke with a path")
local driver=root.."/static/ergopti_plus/macos"
package.path=driver.."/?.lua;"..driver.."/?/init.lua;"..driver.."/tests/stubs/?.lua;"..root.."/static/ergopti_plus/_shared/lua/?.lua;"..root.."/static/ergopti_plus/_shared/lua/?/init.lua;"..package.path
require("test.runner_home").isolate()
_G.hs=require("hs")
local original_fixture=require("tests.support.remap_transaction_fixture")
local reads={}
local function describe(value)
 if type(value)=="number" then
  if value~=value then return {type="number",class="nan"} end
  if value==math.huge then return {type="number",class="positive-infinity"} end
  return {type="number",class="finite",value=value}
 end
 return {type=type(value),text=tostring(value)}
end
package.loaded["tests.support.remap_transaction_fixture"]=function(run,dependencies)
 return original_fixture(function(fixture)
  local config,load_calls
  local proxy=setmetatable({}, {__index=fixture})
  proxy.load_enabled_remap=function(options)
   config=temporary.."/menu-"..tostring(#reads+1)..".toml"
   local stream=assert(io.open(config,"wb"))
   assert(stream:write('[karabiner]\nruntime = "shared"\nintegration_enabled = '..tostring(options.initially_enabled)..'\n[tap_holds]\nenabled = true\nsticky_timeout_ms = 1000\n'))
   assert(stream:close())
   options.real_user_config_path=config;options.real_user_config_writes=true
   local remap,calls=fixture.load_enabled_remap(options);load_calls=calls
   package.loaded["infra.config_paths"].get=function() return config end
   package.loaded["infra.config_paths"].get_config_dir=function() return temporary end
   return remap,calls
  end
  run(proxy)
  local stream=assert(io.open(config,"rb"));local bytes=assert(stream:read("*a"));assert(stream:close())
  local reloaded=assert(package.loaded["platform.remap.config"].load_user_config({{id="left_shift"}},{{id="left_shift+right_shift"}}))
  reads[#reads+1]={published_bytes=bytes,reloaded_sticky=describe(reloaded.sticky_timeout_ms),save_calls=load_calls.save}
  assert(os.remove(config))
 end,dependencies)
end
local captured={}
local original_print=print
_G.print=function(value) captured[#captured+1]=value end
local ok,err=xpcall(function() assert(loadfile(here.."/../ui-domain/menu-infinity-probe.lua"))() end,debug.traceback)
_G.print=original_print
assert(ok,err);assert(#captured==1)
local rows=assert(require("json").decode(captured[1]));assert(#rows==10 and #reads==10)
for i,row in ipairs(rows) do row.real_persistence=reads[i] end
print(assert(require("json").encode(rows)))
