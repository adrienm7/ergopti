-- Audit fixture composes the repository's eventtap fixture with actual Keymap,
-- Registry, Expander, RulesEngine, shared TOML catalogue and SyntheticInput.
local repo = assert(arg[1], 'repository root required')
local driver = repo .. '/static/ergopti_plus/macos'
package.path = driver .. '/?.lua;' .. driver .. '/?/init.lua;' .. driver .. '/tests/stubs/?.lua;' .. repo .. '/static/ergopti_plus/_shared/lua/?.lua;' .. repo .. '/static/ergopti_plus/_shared/lua/?/init.lua;' .. package.path
local file = assert(io.open(driver .. '/tests/unit/modules/keymap/repeat/test_star_validation_beats_repeat_key.lua', 'rb'))
local source = file:read('*a'); file:close()
local marker = '\nhelpers.describe("pressing ★ validates the tooltip on every expansion branch"'
local stop = assert(source:find(marker, 1, true), 'eventtap fixture prefix must exist')
assert(not source:find(marker, stop + 1, true), 'eventtap fixture prefix must be unique')
local fixture = assert(load(source:sub(1, stop - 1) .. '\nreturn install_collaborators,find_keydown_tap,physical_key,force_normal_window,drain_immediate_timers,helpers', '@eventtap-fixture-prefix', 't'))
local install, find_tap, physical, normal, drain, helpers = fixture()
local effects = {emitted={},visible=false}
install(effects)
local publications={}
local Keymap=helpers.load_with_stubs('modules.keymap')
local native=_G.hs
normal()
local now=100
native.timer.secondsSinceEpoch=function() return now end
local state
for index=1,64 do
 local name,value=debug.getupvalue(require('modules.keymap.expander').try_repeat_feature,index)
 if name=='_state' then state=value;break end
end
assert(state, 'read-only observation requires actual state')
local tap=assert(find_tap(native), 'production Keymap tap must be installed')
local function press(char,gap,flags)
 now=now+(gap or 0.01)
 return tap.fn(physical(char,flags))
end
local function reset()
 -- A real navigation event resets the previous scenario through Keymap.
 now=now+0.01
 tap.fn(physical('',nil,123))
 drain(native)
 publications={}
end
require('modules.keystats').notify_synthetic=function(text,source,deletes,variant,echo,private)
 publications[#publications+1]={text=text,source=source,variant=variant}
end
Keymap.set_repeat_feature_enabled(true)
assert(Keymap.set_idle_reset_seconds(0)==true, 'idle reset must be disabled to isolate timing')
-- Replace only the fixture's inert config dependency by its real owner, reading
-- the actual shipped category and a private empty overrides file, never user config.
package.loaded['modules.hotstrings.hotstrings_config']=nil
local Config=require('modules.hotstrings.hotstrings_config')
local overrides=os.tmpname()
assert(Config.init({override_path=overrides,toml_resolver=function(category)
 assert(category=='magickey');return repo..'/static/ergopti_plus/_shared/modules/hotstrings/magickey.toml'
end,base_delay=function() return Keymap.get_base_delay() end})==true)
local effective=Config.resolve('magickey',nil)
assert(type(effective.delay)=='number' and effective.delay==2)
assert(Keymap.set_delay('STAR_TRIGGER',effective.delay)==true)
local initial={shipped_resolved_delay=effective.delay,ultimate_fallback=Keymap.DELAYS_DEFAULT.STAR_TRIGGER,live_star_trigger=state.DELAYS.STAR_TRIGGER,base_delay=Keymap.get_base_delay(),idle_reset=Keymap.get_idle_reset_seconds(),complex_multiplier=state.COMPLEX_DELAY_MULT,complex_carry_ms=require('infra.timings').ms('hotstrings','complex_key_carry_ms')}
local observations={}
local function scenario(delay,gap,flags,expected)
 reset()
 assert(Keymap.set_delay('STAR_TRIGGER',delay)==true)
 press('p');press('o')
 local consumed=press('★',gap,flags)
 drain(native)
 local fired=#publications==1 and publications[1].variant=='repeat_key'
 assert(fired==expected, 'unexpected public repeat admission')
 observations[#observations+1]={star_delay=delay,gap=gap,shift=flags and flags.shift==true or false,consumed=consumed==true,fired=fired,buffer=state.buffer,complex_factor=state.cascade_complex_mult,publication_count=#publications}
end
scenario(effective.delay,1,nil,true)
scenario(effective.delay,2,nil,true)
scenario(effective.delay,2.1,nil,false)
scenario(effective.delay,3,nil,false)
scenario(effective.delay,3,{shift=true},true)
scenario(effective.delay,4.1,{shift=true},false)
scenario(0,60,nil,true)
scenario(10,3,nil,true)
scenario(10,10.1,nil,false)
scenario(0.75,1,nil,false)
scenario(0.75,1,{shift=true},true)
scenario(0.75,2,nil,false)
-- Explicit mapped star is a different policy from the fallback.
reset();Keymap.set_delay('STAR_TRIGGER',0.75)
Keymap.add('po★','EXPLICIT',{auto_expand=true,is_case_sensitive=true})
Keymap.sort_mappings();press('p');press('o')
assert(press('★',3)==true)
assert(#publications==1 and publications[1].text=='EXPLICIT')
local explicit={gap=3,star_delay=state.DELAYS.STAR_TRIGGER,typed=publications[1].text}
assert(os.remove(overrides))
print(require('json').encode({settings=initial,cases=observations,explicit_mapping_control=explicit,native_receiving=false}))
