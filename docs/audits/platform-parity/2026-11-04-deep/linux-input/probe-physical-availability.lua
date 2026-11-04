local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('tests.helpers') -- isolate the test home before imports
local keyboard=require('modules.shortcuts.keyboard_shortcuts')
local bridge=require('ui.physical_shortcuts.bridge')
local Availability=require('shortcuts.physical_availability')
assert(keyboard.physical_delivery_available()==false)
assert(bridge.physical_delivery_available()==false)
local native_checks=0
local original_native=bridge.native_available
bridge.native_available=function() native_checks=native_checks+1; return true end
local scope={physical_delivery_available=keyboard.physical_delivery_available,
 capture_editor_inventory=function() error('must not capture unavailable input') end,
 editor_source_current=function()return true end,edit=function()error('must not save unavailable mapping') end}
assert(bridge.available(scope)==false)
assert(bridge.open({scope=scope,is_paused=function()return false end})==false)
local menu=require('shortcuts.physical_editor_menu').new({scope=function()return scope end,
 host=function()return bridge end,paused=function()return false end,refused=function()end})
assert(menu.ready()==false);assert(menu.open()==false)
assert(native_checks==0)
bridge.native_available=original_native
print('PASS: production physical delivery=false; bridge availability=false; bridge open=false; menu ready=false; menu open=false; native GUI/capture/save never consulted.')
-- Mechanism is also explicit on macOS, but do not import its runtime here.
