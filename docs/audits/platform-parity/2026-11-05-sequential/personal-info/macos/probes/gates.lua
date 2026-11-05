local root=assert(arg[1]);local dir=assert(debug.getinfo(1,'S').source:match('^@(.*)/[^/]+$'));local file=assert(io.open(dir..'/engine.lua'));local src=file:read('*a');file:close();local prefix=assert(src:match('^(.-)local consumed,preview,emitted=type_combo'))
local scenario=[[
local function decline(label)local c,p,e=type_combo('p');assert(c==false and p==nil and e==nil);print(label..': pass-through, no personal preview/output')end
local c,_,e=type_combo('p');assert(c and e==info.first_name);print('healthy native-classified control: personal expansion accepted');assert(Keymap.pause_processing());decline('pause control');assert(Keymap.resume_processing())
local element=hs.axuielement.applicationElementForPID(777):attributeValue('AXFocusedUIElement');local original_attribute=element.attributeValue
element.attributeValue=function(_,a)if a=='AXRole'or a=='AXSubrole'then return 'AXSecureTextField'end end
Utils.ignored_window_rules_changed();assert(Utils.prewarm_ignored_win_watchers({},{}));assert(Utils.is_secure_field(now)==true);decline('native secure-field control')
element.attributeValue=original_attribute;Utils.ignored_window_rules_changed();assert(Utils.prewarm_ignored_win_watchers({},{}))
local original_focus=hs.window.focusedWindow;hs.window.focusedWindow=function()return nil end;Utils.ignored_window_rules_changed();assert(Utils.prewarm_ignored_win_watchers({},{})==false);decline('native unknown-field control');hs.window.focusedWindow=original_focus
local original_name=app.name;app.name=function()return 'Hammerspoon'end;Utils.ignored_window_rules_changed();assert(Utils.prewarm_ignored_win_watchers({},{}));assert(Utils.is_ignored_window({}, {},now)==true);decline('native ignored-app control');app.name=original_name
Utils.ignored_window_rules_changed();assert(Utils.prewarm_ignored_win_watchers({},{}));Personal.stop();decline('retired personal callback control');assert(Rules.stop());assert(Keymap.stop(true));decline('stopped keymap control')
]]
assert(load(prefix..scenario,'@'..dir..'/gates.lua'))()
