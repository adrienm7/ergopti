-- Original Remap setter and original Config persistence on private temporary files.
local root=assert(arg[1],"Pass repository root")
local directory=assert(arg[2],"Pass an existing private temporary directory")
local driver=root.."/static/ergopti_plus/macos"
package.path=driver.."/?.lua;"..driver.."/?/init.lua;"..driver.."/tests/stubs/?.lua;"..root.."/static/ergopti_plus/_shared/lua/?.lua;"..root.."/static/ergopti_plus/_shared/lua/?/init.lua;"..package.path
require("test.runner_home").isolate()
_G.hs=require("hs")
local with_fixture=require("tests.support.remap_transaction_fixture")
local function read(path)
 local stream=assert(io.open(path,"rb"));local bytes=assert(stream:read("*a"));assert(stream:close());return bytes
end
local function describe(value)
 if type(value)=="number" then
  if value~=value then return {type="number",class="nan"} end
  if value==math.huge then return {type="number",class="positive-infinity"} end
  if value==-math.huge then return {type="number",class="negative-infinity"} end
  return {type="number",class="finite",value=value}
 end
 return {type=type(value),text=tostring(value)}
end
local rows={}
for _,enabled in ipairs({false,true}) do
 for _,input in ipairs({{"control-2000",2000},{"positive-infinity",math.huge},{"large-finite",1e20},{"zero",0},{"fraction-to-zero",0.1}}) do
  local config=directory.."/config-"..tostring(enabled).."-"..input[1]..".toml"
  local original='[karabiner]\nruntime = "shared"\nintegration_enabled = '..tostring(enabled)..'\n[tap_holds]\nenabled = true\nsticky_timeout_ms = 1000\n'
  local stream=assert(io.open(config,"wb"));assert(stream:write(original));assert(stream:close())
  with_fixture(function(fixture)
   local remap,calls=fixture.load_enabled_remap({initially_enabled=enabled,real_user_config_path=config,real_user_config_writes=true})
   local paths=package.loaded["infra.config_paths"]
   paths.get=function() return config end
   paths.get_config_dir=function() return directory end
   local before=remap.get_sticky_timeout()
   local outcome=table.pack(pcall(remap.set_sticky_timeout,input[2]))
   local bytes=read(config)
   local reload=table.pack(pcall(package.loaded["platform.remap.config"].load_user_config,{{id="left_shift"}},{{id="left_shift+right_shift"}}))
   local row={name=input[1],initially_enabled=enabled,actual_enabled=remap.get_enabled(),input=describe(input[2]),
    before=describe(before),called=outcome[1],return_arity=outcome.n-1,first_return=describe(outcome[2]),
    after=describe(remap.get_sticky_timeout()),save_calls=calls.save,original_bytes=original,published_bytes=bytes,
    reload_called=reload[1],reload_return_arity=reload.n-1,generator_build_calls=calls.build,generator_deploy_calls=calls.deploy}
   if reload[1] and type(reload[2])=="table" then row.reloaded_sticky=describe(reload[2].sticky_timeout_ms)
   elseif not reload[1] then row.reload_error=tostring(reload[2]) end
   rows[#rows+1]=row
  end)
  assert(os.remove(config))
 end
end
assert(#rows==10)
print(assert(require("json").encode(rows)))
