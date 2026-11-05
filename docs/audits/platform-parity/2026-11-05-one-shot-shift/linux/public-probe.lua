-- Audit the actual tap-hold manager and Hook using recorded native layout ports.
local root=assert(arg[1]);local driver=root.."/static/ergopti_plus/linux"
package.path=driver.."/?.lua;"..driver.."/?/init.lua;"..root.."/static/ergopti_plus/_shared/lua/?.lua;"..root.."/static/ergopti_plus/_shared/lua/?/init.lua;"..package.path
require("test.runner_home").isolate();require("compat.utf8").install()
local Capture=require("adapters.xkb_capture")
Capture._set_backend({create=function()return {down={},caps=false}end,destroy=function()end,
key_sym=function(_,key)local code=key-8;return ({[42]=0xffe1,[54]=0xffe2,[29]=0xffe3,[97]=0xffe4,[56]=0xffe9,[100]=0xfe03,[125]=0xffeb,[58]=0xffe5,[28]=0xff0d,[15]=0xff09,[14]=0xff08,[1]=0xff1b,[111]=0xffff,[105]=0xff51,[106]=0xff53})[code]end,
key_utf8=function(s,key)local code=key-8;local ch=({[30]='a',[48]='b',[46]='c',[36]='j',[57]=' ',[52]='.'})[code];if ch and #ch==1 and ch:match('%a') and ((s.down[42]==true or s.down[54]==true)~=(s.caps==true))then return ch:upper()end;return ch end,
sym_utf8=function()end,update_key=function(s,key,value)local code=key-8;if value==1 then s.down[code]=true elseif value==0 then s.down[code]=nil end;if code==58 and value==1 then s.caps=not s.caps end end,
caps_locked=function(s)return s.caps end,compose_feed=function()end,compose_status=function()return 'nothing'end,compose_utf8=function()end,compose_reset=function()end})
assert(Capture.load('keymap','C'))
local sourcefile=assert(io.open(driver..'/tests/unit/platform/remap/tap_hold/test_tap_hold_integration.lua','rb'));local source=sourcefile:read('*a');sourcefile:close()
local boundary=assert(source:find('\n--- Asserts every key',1,true))
local session=assert((loadstring or load)(source:sub(1,boundary-1)..'\nreturn session','@recorded-integration-native-fixture'))()
local observations={}
local function fixture(name,events,body)
 require('logger.shim').set_sink(nil)
 assert(Capture.load('keymap','C'))
 local s=session('[tap_hold]\ninherit_defaults=false\n[tap_hold.keys.right_ctrl]\ntap_action="one_shot_shift"\ntime_activation_seconds=0.2\n')
 local Layout=require('adapters.keyboard_layout');Layout._set_table_for_test({a={keycode=30,mods={},level=1},A={keycode=30,mods={'shift'},level=2},b={keycode=48,mods={},level=1},B={keycode=48,mods={'shift'},level=2},c={keycode=46,mods={},level=1},C={keycode=46,mods={'shift'},level=2},[' ']={keycode=57,mods={},level=1},['-']={keycode=12,mods={},level=1}})
 local native=s.hook._test_drive
 local chars,wire,logs={},{},{}
 local logger=require("logger.shim");logger.set_level("trace");logger.set_sink(function(line,variant)if variant=="error" or variant=="warn" then logs[#logs+1]=line end end)
 local stream={};for _,e in ipairs(events)do stream[#stream+1]={type=1,code=e[1],value=e[2],at_ms=e[3],timestamp_us=e[3]*1000}end
 local ok,err=pcall(native,stream,{liveXkb=true,onEmitRaw=function(code,value)wire[#wire+1]={code=code,value=value};return true end,onChar=function(ch)chars[#chars+1]=ch end,onPhysical=function(code,key,ch,value) end},true)
 local row={name=name,wire=wire,chars=chars,logs=logs,caps=Capture.caps_locked(),deadline=s.manager.configuration_snapshot().engine.one_shot_until}
 if ok and body then body(s,row)end
 s.close();logger.set_sink(nil);assert(ok,err);observations[#observations+1]=row
end
fixture('three-fast-letters',{{97,1,0},{97,0,100},{30,1,150},{48,1,160},{30,0,170},{48,0,180},{46,1,190},{46,0,200}})
fixture('expired-letter',{{97,1,0},{97,0,100},{30,1,2200},{30,0,2210}})
fixture('arrow-keeps-arm',{{97,1,0},{97,0,100},{105,1,150},{105,0,160},{30,1,170},{30,0,180}})
fixture('control-spends-arm',{{97,1,0},{97,0,100},{28,1,150},{28,0,160},{30,1,170},{30,0,180}})
fixture('caps-lock-plus-held-shift',{{58,1,0},{58,0,10},{97,1,20},{97,0,120},{42,1,150},{30,1,170},{30,0,180},{42,0,190},{48,1,200},{48,0,210}})
fixture('caps-lock-alone',{{58,1,0},{58,0,10},{97,1,20},{97,0,120},{30,1,170},{30,0,180},{48,1,200},{48,0,210}})
fixture('ctrl-a-keeps-arm',{{97,1,0},{97,0,100},{29,1,120},{30,1,130},{30,0,140},{29,0,150},{48,1,170},{48,0,180}})
fixture('ctrl-enter-spends-arm',{{97,1,0},{97,0,100},{29,1,120},{28,1,130},{28,0,140},{29,0,150},{48,1,170},{48,0,180}})
fixture('physical-shift-alone',{{97,1,0},{97,0,100},{42,1,150},{30,1,170},{30,0,180},{42,0,190},{48,1,200},{48,0,210}})
fixture('caps-lock-plus-right-shift',{{58,1,0},{58,0,10},{97,1,20},{97,0,120},{54,1,150},{30,1,170},{30,0,180},{54,0,190},{48,1,200},{48,0,210}})
fixture('repeat-before-release',{{97,1,0},{97,0,100},{30,1,170},{30,2,180},{30,2,190},{30,0,200},{48,1,210},{48,0,220}})
fixture('right-arrow-keeps-arm',{{97,1,0},{97,0,100},{106,1,150},{106,0,160},{30,1,170},{30,0,180}})
fixture('backspace-spends',{{97,1,0},{97,0,100},{14,1,150},{14,0,160},{30,1,170},{30,0,180}})
fixture('tab-spends',{{97,1,0},{97,0,100},{15,1,150},{15,0,160},{30,1,170},{30,0,180}})
fixture('delete-spends',{{97,1,0},{97,0,100},{111,1,150},{111,0,160},{30,1,170},{30,0,180}})
fixture('escape-spends',{{97,1,0},{97,0,100},{1,1,150},{1,0,160},{30,1,170},{30,0,180}})
fixture('at-inclusive-deadline',{{97,1,0},{97,0,100},{30,1,2100},{30,0,2110}})
fixture('past-deadline',{{97,1,0},{97,0,100},{30,1,2101},{30,0,2110}})
fixture('retrigger-extends-deadline',{{97,1,0},{97,0,100},{97,1,1500},{97,0,1600},{30,1,2500},{30,0,2510}})
fixture('rearm-after-spent',{{97,1,0},{97,0,100},{30,1,170},{30,0,180},{97,1,300},{97,0,400},{30,1,470},{30,0,480}})
local expected={['retrigger-extends-deadline']={'A'},['rearm-after-spent']={'A','A'},['three-fast-letters']={'A','b','c'},['expired-letter']={'a'},['arrow-keeps-arm']={'A'},['control-spends-arm']={'\n','a'},['caps-lock-plus-held-shift']={'a','B'},['caps-lock-alone']={'A','B'},['ctrl-a-keeps-arm']={'B'},['ctrl-enter-spends-arm']={'b'},['physical-shift-alone']={'A','b'},['caps-lock-plus-right-shift']={'a','B'},['repeat-before-release']={'A'},['right-arrow-keeps-arm']={'A'},['backspace-spends']={'a'},['tab-spends']={'\t','a'},['delete-spends']={'a'},['escape-spends']={'a'},['at-inclusive-deadline']={'A'},['past-deadline']={'a'}}
for _,row in ipairs(observations)do local want=assert(expected[row.name]);assert(#row.chars==#want,row.name);for i,value in ipairs(want)do assert(row.chars[i]==value,row.name)end;if row.name=='repeat-before-release'then assert(#row.logs>=1 and row.logs[1]:find('Emergency keyboard stop',1,true))else for _,line in ipairs(row.logs)do assert(not line:find('[ERROR]',1,true),row.name..': '..line)end end end
print('ONE_SHOT_PUBLIC='..assert(require('json').encode({qualification='Actual Manager/Hook/Engine with actual XKB adapter over recording backend and native writer callback; no receiving application.',observations=observations})))
