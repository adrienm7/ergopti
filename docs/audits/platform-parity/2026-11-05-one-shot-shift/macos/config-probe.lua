-- Actual remap setter with native lease/persistence ports from the registered fixture.
local root=assert(arg[1]);local driver=root.."/static/ergopti_plus/macos"
package.path=driver.."/?.lua;"..driver.."/?/init.lua;"..driver.."/tests/stubs/?.lua;"..root.."/static/ergopti_plus/_shared/lua/?.lua;"..root.."/static/ergopti_plus/_shared/lua/?/init.lua;"..package.path
local with_fixture=require("tests.support.remap_transaction_fixture")
local rows={}
for _,value in ipairs({0,0.1,0.9,1,2.5,2000}) do
 with_fixture(function(fixture)
  local remap,calls=fixture.load_enabled_remap({initially_enabled=false})
  local before=remap.get_sticky_timeout()
  local accepted=remap.set_sticky_timeout(value)
  rows[#rows+1]={input=value,before=before,accepted=accepted,after=remap.get_sticky_timeout(),save_calls=calls.save,saved=calls.saved_payloads[#calls.saved_payloads] and calls.saved_payloads[#calls.saved_payloads].sticky_timeout_ms}
 end)
end
print(require("json").encode(rows))
