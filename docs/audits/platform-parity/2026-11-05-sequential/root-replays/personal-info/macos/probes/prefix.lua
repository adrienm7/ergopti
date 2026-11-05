local root=assert(arg[1]);local dir=assert(debug.getinfo(1,'S').source:match('^@(.*)/[^/]+$'));local file=assert(io.open(dir..'/engine.lua'));local src=file:read('*a');file:close()
local prefix=assert(src:match('^(.-)local consumed,preview,emitted=type_combo'))
local scenario=[[
assert(Keymap.enable_section('dynamichotstrings','phoneprefixes'))
assert(Keymap.enable_group('dynamichotstrings'))
local native={windows={},retained={},deferred={},timers={}}
local create=require('tests.support.native_webview_close_fixture')(native)
local bridge
hs.focus=function()end;hs.webview.windowMasks={titled=1,closable=2,utility=16}
hs.webview.usercontent.new=function()local b={};function b:setCallback(cb)self.callback=cb;return self end;bridge=b;return b end
hs.webview.new=function(...)local v=create(...);function v:evaluateJavaScript(_,callback)if callback then callback(nil,nil)end;return self end;return v end
Personal.open_editor();assert(bridge and bridge.callback and native.windows[1].visible)
bridge.callback({body={action='save',values={phone_number='0123{Tab}45'}}})
assert(Personal.get_info().phone_number=='0123{Tab}45');native.drain_native_close()
print('REACHABLE editor control: actual editor/controller/UIBuilder/bridge accepts phone string; actual save commits and closes native-shaped view')
local full='0123{Tab}45'
local ca,pa,ea=type_combo('t');assert(ca and ea==full);local atabs=0;for _,e in ipairs(events)do if e.key=='tab'and e.isDown then atabs=atabs+1 end end;assert(atabs==0)
print('CONTROL @t: emits exact full phone value 0123{Tab}45 as literal data; native Tab count=0')
effects.emitted={};events={};press(' ');local consumed=false
for ch in ('0123'):gmatch('.')do consumed=press(ch)or consumed end
f.drain(hs)
local tabs=0;for _,e in ipairs(events)do if e.key=='tab'and e.isDown then tabs=tabs+1 end end
print('PREFIX trigger0123 consumed='..tostring(consumed)..' logical='..string.format('%q',effects.emitted[1])..' native Tab count='..tabs)
assert(consumed and effects.emitted[1]~=full and tabs==1)
Personal.stop();assert(Rules.stop());assert(Keymap.stop(true))
]]
assert(load(prefix..scenario,'@'..dir..'/prefix.lua'))()
