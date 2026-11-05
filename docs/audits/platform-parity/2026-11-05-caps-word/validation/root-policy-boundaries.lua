-- Independent root characterization of the actual shared CapsWord policy.
local root = assert(arg[1], "Pass the repository root")
package.path = root .. "/static/ergopti_plus/_shared/lua/?.lua;" .. root .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
local Policy = require("caps_word.auto_off")
local function compile(seconds)
 return assert(Policy.compile({ idle_timeout_seconds=seconds, terminators={"space"}, pointer={pointer_motion=false} }, {"pointer_motion"}))
end
for _, seconds in ipairs({0,0.0001,0.00049,0.0005,0.001,1,10}) do
 local policy=compile(seconds)
 print(string.format("seconds=%.5f idle_ms=%s expired_at_0=%s expired_at_1=%s", seconds,tostring(Policy.idle_delay_ms(policy)),tostring(Policy.idle_expired(policy,0,0)),tostring(Policy.idle_expired(policy,0,1))))
end
local zero,tiny,one=compile(0),compile(0.0001),compile(0.001)
assert(Policy.idle_delay_ms(zero)==nil and not Policy.idle_expired(zero,0,100000))
assert(Policy.idle_delay_ms(tiny)==0 and Policy.idle_expired(tiny,0,0))
assert(Policy.idle_delay_ms(one)==1 and not Policy.idle_expired(one,0,0) and Policy.idle_expired(one,0,1))
assert(Policy.ends_on_text(tiny,"x y") and not Policy.ends_on_text(tiny,"xyz"))
print("Independent root policy controls passed; no AHK or desktop execution.")
