local root=assert(arg[1]);local out=assert(debug.getinfo(1,'S').source:match('^@(.*)/[^/]+$'));local base=root..'/static/ergopti_plus/'
package.path=base..'macos/?.lua;'..base..'macos/?/init.lua;'..base..'_shared/lua/?.lua;'..base..'_shared/lua/?/init.lua;'..package.path
local source=assert(io.open(base..'macos/tests/unit/modules/dynamic_hotstrings/injection/test_personal_preview_static_ownership.lua')):read('*a')
local prefix=assert(source:match('^(.-)helpers%.describe%('))
local f=assert(load(prefix..'return { install=install_collaborators, drain=drain_immediate_timers, tap=find_keydown_tap, key=physical_key }','@native-fixture-prefix'))()
local helpers=require('tests.helpers');local effects={emitted={}};f.install(effects)
local Keymap=helpers.load_with_stubs('modules.keymap');local hs=hs
-- Immediate native app/window/AX ports; business classification remains real.
local function watcher()return {start=function(self)return self end,stop=function(self)return self end}end
local app={pid=function()return 777 end,name=function()return 'SyntheticEditor'end,bundleID=function()return 'audit.synthetic.editor'end,newWatcher=function()return watcher()end}
local win={id=function()return 901 end,title=function()return 'Synthetic fixture'end,application=function()return app end,newWatcher=function()return watcher()end}
hs.application.frontmostApplication=function()return app end;hs.window.focusedWindow=function()return win end;hs.window.frontmostWindow=function()return win end
hs.application.__set_for_pid(777,app)
local now=100;hs.timer.secondsSinceEpoch=function()return now end
assert(Keymap.start());local Utils=require('modules.keymap.utils');assert(Utils.is_ignored_window({}, {},now)==false);assert(Utils.is_secure_field(now)==false)
local Personal=require('modules.dynamic_hotstrings.personal_info');local Rules=require('modules.dynamic_hotstrings.rules_engine');local Codec=require('toml_codec.codec')
local info={first_name='Synthetic {Tab} 雪',last_name='Fixture',city='Audit City',country='Audit Country',postal_code='12345',iban='FR1212345678901234567890123',bic='AUDITBIC',credit_card='1111 2222 3333 4444',social_security_number='1 11 11 11 111 111 11',phone_number='0102030405',phone_number_clean='01 02 03 04 05',street_address='Line1\nLine2',date_of_birth='01/02/2000',email_address='audit@example.test',work_email_address='work@example.test'}
local path=out..'/synthetic-personal-info.toml';local file=assert(io.open(path,'wb'));assert(file:write(Codec.encode({info=info,letters={p='first_name',x='city'}})));assert(file:close())
assert(Personal.start('',Keymap,path,Rules.refresh_personal_data));assert(Rules.inject_data(Personal.get_info(),'★'));assert(Rules.start(Keymap));Keymap.set_preview_star_enabled(true);Keymap.set_preview_autocorrect_enabled(true)
local tap=assert(f.tap(hs));local events={}
local function press(ch)
 now=now+0.001
 local consumed,returned=tap.fn(f.key(ch));for _,e in ipairs(returned or{})do events[#events+1]=e end
 return consumed
end
local function type_combo(alias)
 effects.rows=nil;effects.emitted={};events={};press(' ');press('@');for i=1,#alias do press(alias:sub(i,i))end;f.drain(hs);local row=effects.rows and effects.rows[1] and effects.rows[1].text;local consumed=press('★');f.drain(hs);return consumed,row,effects.emitted[1]
end
local consumed,preview,emitted=type_combo('p');assert(consumed==true and emitted==info.first_name);print('healthy default alias p: actual Keymap/Personal/Expander/Synthetic emit exact literal braces+Unicode; preview='..tostring(preview))
local consumed_x,preview_x,emitted_x=type_combo('x');assert(consumed_x==false and preview_x==nil and emitted_x==nil);print('PIM-001 extra alias x=city: configured valid known field; preview=nil consumed=false emitted=nil')
local before=assert(io.open(path,'rb')):read('*a');assert(Codec.decode(before).letters.x=='city');local b=assert(io.open(out..'/aliases.before.toml','wb'));assert(b:write(before));assert(b:close())
assert(Personal.save_info({last_name='Edited Fixture'}));local after=assert(io.open(path,'rb')):read('*a');assert(Codec.decode(after).letters.x==nil);local a=assert(io.open(out..'/aliases.after.toml','wb'));assert(a:write(after));assert(a:close());assert(Personal.get_info().city==info.city);print('PIM-001 normal editor save: save=true; extra alias x removed from actual TOML; known city value retained')
local multiconsumed,_,multiemitted=type_combo('pn');assert(multiconsumed and multiemitted==info.first_name..'Edited Fixture');local tabs=0;for _,e in ipairs(events)do if e.key=='tab' and e.isDown then tabs=tabs+1 end end;assert(tabs==1);print('healthy multifield pn: literal {Tab} remains field data; exactly one real Tab pair; logical emitted value has no tab')
assert(Personal.disable());local c,pr,em=type_combo('p');assert(not c and pr==nil and em==nil);print('disabled control: no personal preview/consume/emission')
assert(Personal.enable());assert(Personal.set_trigger_char('§'));local old,_,eold=type_combo('p');assert(not old and eold==nil);print('trigger change control: old magic event cannot expand')
Personal.stop();assert(Rules.stop());local remap=assert(io.open(path,'wb'));assert(remap:write(Codec.encode({info=info,letters={p='city',x='city'}})));assert(remap:close());assert(Personal.start('',Keymap,path,Rules.refresh_personal_data));assert(Rules.inject_data(Personal.get_info(),'★'));assert(Rules.start(Keymap));local cp,pp,ep=type_combo('p');assert(cp and pp==info.city and ep==info.city);local cx,px,ex=type_combo('x');assert(not cx and px==nil and ex==nil);print('positive alias remap control: p=city works with exact Audit City preview+output; x=city in SAME source remains inert');Personal.stop();assert(Rules.stop());assert(Keymap.stop(true));print('PASS stopped actual owners; no native Darwin or real secret used')
