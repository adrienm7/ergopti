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
local rows={}
local function press(code,value)local t,_,err=Capture.process(code,value or 1);assert(not err,err);return t or '' end
local function key(code)local t=press(code);press(code,0);return t end
local function check(name,expected,fn)
 assert(Capture.load(map,'C.UTF-8'));local actual=fn();assert(actual==expected,name..': '..actual);rows[#rows+1]={name=name,text=actual};Capture.clear()
end
check('plain', 'ê',function()return key(43)..key(32)end)
check('unmapped-preserves-neutral-only', '%e',function()return key(43)..key(12)..key(32)end)
check('space-terminates','^e',function()return key(43)..key(57)..key(32)end)
check('repeated-dead','^e',function()return key(43)..key(43)..key(32)end)
check('peek-does-not-feed','ê',function()key(43);assert(Capture.peek_text(12)=='%');return key(32)end)
check('explicit-cancel','e',function()key(43);assert(Capture.cancel_compose());return key(32)end)
check('reset-retires-prefix','e',function()key(43);assert(Capture.reset_state());return key(32)end)
check('load-retires-prefix','e',function()key(43);assert(Capture.load(map,'C.UTF-8'));return key(32)end)
check('empty-load-retains-prefix','ê',function()key(43);assert(not Capture.load('','C.UTF-8'));return key(32)end)
check('malformed-load-retains-prefix','ê',function()key(43);assert(not Capture.load('not a keymap','C.UTF-8'));return key(32)end)
print(assert(require('json').encode({qualification='Original Capture genuine libxkbcommon; converter-generated Ergopti symbols/types/Compose embedded with system evdev keycodes and complete compatibility. Component controls only; no device or desktop.',observations=rows})))
