-- Original public TapKeys/Reader/Hook and two genuine native Capture owners.
local root=assert(arg[1], 'Pass the repository root')
local here=assert(arg[0]:match('^(.*)/[^/]+$'))
local generated=arg[2] or here..'/generated'
local driver=root..'/static/ergopti_plus/linux'
package.path=driver..'/?.lua;'..driver..'/?/init.lua;'..root..'/static/ergopti_plus/_shared/lua/?.lua;'..root..'/static/ergopti_plus/_shared/lua/?/init.lua;'..package.path
require('compat.utf8').install();require('test.runner_home').isolate()
local function read(path)local f=assert(io.open(path,'rb'));local b=f:read('*a');f:close();return b end
assert(os.getenv('XCOMPOSEFILE')==generated..'/ergopti_plus.XCompose', 'Set XCOMPOSEFILE to the retained generated table')
local symbols,count=read(generated..'/ergopti_plus.xkb'):gsub('^partial alphanumeric_keys%s*','');assert(count==1)
local types=read(generated..'/xkb_types.txt')
local map='xkb_keymap { xkb_keycodes { include "evdev+aliases(qwerty)" }; '..types..' xkb_compatibility { include "complete" }; '..symbols..' };'
local Capture=require('adapters.xkb_capture')
local Reference=assert(loadfile(driver..'/adapters/xkb_capture.lua'))()
local h=require('tests.helpers')
local Manager=require('modules.gestures.manager')
assert(Manager.is_assignable('screen_capture'), 'The unchanged real catalogue must admit the binding')
local Routes=require('infra.config_paths');local saved_route=Routes.config
local cases={
 {name='unassigned-second',assigned=false,active=true,dead=43},
 {name='assigned-second',assigned=true,active=true,dead=43},
 {name='inactive-second',assigned=true,active=false,dead=43},
 {name='queue-refused-second',assigned=true,active=true,refuse=true,dead=43},
 {name='assigned-first-dead',assigned=true,active=true,dead=12,first=true},
 {name='no-prefix-assigned',assigned=true,active=true},
 {name='plain-compose',assigned=false,active=true,dead=43,skip_tap=true},
}
local observations={}
for _,case in ipairs(cases) do
 local selected=map
 -- A second explicit native keymap control moves the same dead symbol onto
 -- the actual public tap-key position; this changes data, not a Lua body.
 if case.first then selected=selected:gsub('};%s*};%s*$', 'key <AE11> { [ dead_circumflex ] }; }; };') end
 assert(Capture.load(selected,'C.UTF-8'));assert(Reference.load(selected,'C.UTF-8'))
 assert(Capture.peek_text(32)=='e')
 local config=os.tmpname();local f=assert(io.open(config,'wb'))
 assert(f:write('[shortcuts]\nenabled = true\n[shortcuts.tap_keys]\nnumber_row_right_1 = "'..(case.assigned and 'screen_capture' or 'none')..'"\n'));assert(f:close())
 Routes.config=function(name)if name=='config.toml' then return config end;return saved_route(name) end
 package.loaded['modules.shortcuts.tap_keys']=nil
 local TapKeys=require('modules.shortcuts.tap_keys')
 local Loop=h.load_module('adapters.event_loop')
 local queued,executed=0,0
 TapKeys.init({is_active=function() return case.active end,defer=function(fn)
  if case.refuse then return false end
  local accepted=Loop.defer(function()executed=executed+1;return fn()end)
  if accepted then queued=queued+1 end;return accepted
 end})
 assert(TapKeys.get_action('number_row_right_1')==(case.assigned and 'screen_capture' or 'none'))
 local Hook=h.load_module('adapters.keyboard_hook')
 local chars,reference,wire,decisions={},{},{},{}
 local events={}
 local function key(code)events[#events+1]={type=1,code=code,value=1};events[#events+1]={type=1,code=code,value=0}end
 if case.dead then key(case.dead) end
 if not case.first and not case.skip_tap then key(12) end
 key(32)
 local drained=Hook._test_drive(events,{
  liveXkb=true,
  onConsume=function(detail)
   local consumed=TapKeys.on_key(detail);decisions[#decisions+1]={code=detail.code,char=detail.char,consumed=consumed};return consumed
  end,
  onChar=function(text) chars[#chars+1]=text end,
  onEmitRaw=function(code,value)
   wire[#wire+1]={code,value};local text,_,err=Reference.process(code,value);assert(not err,err)
   if text and text~='' then reference[#reference+1]=text end;return true
  end,
 },true)
 assert(executed==0, 'Original EventLoop.defer must not run inside the Reader drain')
 local row={name=case.name,chars=chars,reference=reference,wire=wire,decisions=decisions,drained=drained,deferred=queued,executed=executed}
 if case.name=='assigned-second' then
  assert(table.concat(chars)=='e' and table.concat(reference)=='ê' and queued==1)
 elseif case.name=='plain-compose' then assert(table.concat(chars)=='ê' and table.concat(reference)=='ê')
 elseif case.first or case.name=='no-prefix-assigned' then assert(table.concat(chars)=='e' and table.concat(reference)=='e' and queued==1)
 else assert(table.concat(chars)=='%e' and table.concat(reference)=='%e' and queued==0) end
 observations[#observations+1]=row
 Loop.stop();TapKeys._reset();Routes.config=saved_route;assert(os.remove(config));Capture.clear();Reference.clear()
end
print(assert(require('json').encode({
 qualification='Original TapKeys/real action catalogue/private real assignment source, original EventLoop.defer, original Hook and Reader decoded-event seam, controlled reader/broker/raw-ACK ports. TWO original Capture adapters use genuine libxkbcommon and the exact converter-generated ErgoptiPlus symbols/types/Compose; Reference sees only acknowledged raw emissions. No deferred action executed before the next key in the same drain. No device, desktop authority or receiving application is certified. One positive control relocates a dead symbol onto the real tap position using an explicit native-data override.',
 observations=observations})))
