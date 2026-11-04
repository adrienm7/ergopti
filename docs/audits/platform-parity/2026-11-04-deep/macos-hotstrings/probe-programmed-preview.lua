local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
_G.hs=require('tests.stubs.hs')
local path=root..'macos/tests/unit/modules/dynamic_hotstrings/user_code/test_user_code_native.lua'
local file=assert(io.open(path));local source=file:read('*a');file:close()
local prefix=assert(source:match('^(.-)helpers%.describe%('))
local native=assert(load(prefix..'return {run=with_native,physical=physical,drain=drain}','@'..path))()
local descriptor='Literal {Left} {U+0041}'
local provided
native.run(function(f)
 f.content=f.content:gsub('preview="Custom"',function()return 'preview="'..descriptor..'"' end)
 assert(f.User.reload())
 provided=f.User.preview('@u')
 assert(provided==descriptor)
 f.result=descriptor
 f.type_suffix()
 assert(f.calls==0)
 assert(f.tap.fn(native.physical('★'))==true)
 native.drain(f.hs)
 assert(f.calls==1 and f.outputs[1]==descriptor)
 print('PRODUCER: static descriptor and literal callback output both preserve ['..descriptor..']')
end)
local row_path=root..'macos/tests/unit/modules/keymap/preview/test_preview_masks_secrets.lua'
local r=assert(io.open(row_path));local text=r:read('*a');r:close()
local helper=assert(text:match('(local PREVIEW_OWNERSHIP.-)helpers%.describe%("preview rows:'))
local capture=assert(load('local helpers=require("tests.helpers")\n'..helper..'return capture_rows','@'..row_path))()
local rows=capture(function(Registry)
 local state
 for i=1,30 do local name,value=debug.getupvalue(Registry.init,i);if name=='_state' then state=value;break end end
 assert(state)
 state.preview_providers={function()return provided end}
end,'@u')
assert(#rows>0,'bridge did not render a row')
assert(rows[1].text=='Literal  A','unexpected projection: '..tostring(rows[1].text))
print('REPRO: actual bridge renders static descriptor ['..provided..'] as ['..rows[1].text..']')
