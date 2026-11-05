-- Audit fixture: execute the real generator; the graph model is not native Karabiner.
local repository=assert(arg[1],"repository root required")
local driver=repository.."/static/ergopti_plus/macos"
package.path=driver.."/?.lua;"..driver.."/?/init.lua;"..driver.."/tests/stubs/?.lua;"..repository.."/static/ergopti_plus/_shared/lua/?.lua;"..repository.."/static/ergopti_plus/_shared/lua/?/init.lua;"..package.path
_G.hs=require("hs")
local function prefix(relative, suffix)
 local f=assert(io.open(driver.."/tests/"..relative,"rb"));local source=f:read("*a");f:close()
 local stop=assert(source:find("\nhelpers.describe(",1,true))
 return assert(load(source:sub(1,stop-1)..suffix,"@capsword-graph-fixture","t"))()
end
local build,exits=prefix("unit/platform/remap/generator/test_generator_capsword_setting_exits.lua","\nreturn build,exits")
local config,context=build()
local rules=config.profiles[1].complex_modifications.rules
local actual=exits(rules[1])
local old=exits(context.static_anchors.capsword)
for _,name in ipairs({"spacebar","return_or_enter","tab","g","v","button1","button2"}) do assert(not actual[name] and old[name]) end
for _,name in ipairs({"caps_lock","escape","delete_forward","up_arrow","page_down","home","f1"}) do assert(actual[name]) end
local Generator=require("platform.remap.generator")
local Model=require("tests.support.karabiner_model")
local token="0123456789abcdef0123456789abcdef"
local model=Model.new(rules,{variables={ [Generator.mode_variable_name(token)]=1 }})
model:down("right_option");model:down("caps_lock")
assert(model:variable("ergopti_capsword_"..token)==1)
local caps,tag=0,0
for _,event in ipairs(model:emissions()) do if event.key_code=="caps_lock" then caps=caps+1 elseif event.key_code=="f20" then tag=tag+1 end end
assert(caps==1 and tag==1)
print("generated-key-activation","caps_lock_emissions="..caps,"control_tags="..tag,"variable=1","native_initial_capslock_unmeasured=true")
model:up("caps_lock");model:up("right_option");model:clear()
model:down("escape")
assert(model:variable("ergopti_capsword_"..token)==0)
caps,tag=0,0
for _,event in ipairs(model:emissions()) do if event.key_code=="caps_lock" then caps=caps+1 elseif event.key_code=="f20" then tag=tag+1 end end
assert(caps==1 and tag==1)
print("generated-key-exit","caps_lock_emissions="..caps,"control_tags="..tag,"variable=0")
local fresh_registry=prefix("unit/modules/gestures/actions/test_karabiner_actions_reachable.lua","\nreturn fresh_registry")
for _,initial in ipairs({false,true}) do
 local Actions,seen=fresh_registry()
 seen.capslock=initial
 assert(Actions.execute_single("capsword"))
 assert(seen.capslock==initial)
 seen.complete(1,true)
 assert(seen.capslock==true)
 print("catalogue-action","recorded_initial="..tostring(initial),"after_write_settles_requested=true","preexisting_state_not_read_by_handler=true")
end
