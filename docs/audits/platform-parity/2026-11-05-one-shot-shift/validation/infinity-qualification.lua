-- Programmatic positive-infinity boundary; no native event or UI claim.
local root = assert(arg[1])
package.path = root .. '/static/ergopti_plus/macos/?.lua;'
 .. root .. '/static/ergopti_plus/macos/?/init.lua;'
 .. root .. '/static/ergopti_plus/_shared/lua/?.lua;'
 .. root .. '/static/ergopti_plus/_shared/lua/?/init.lua;' .. package.path
local Owner = require('modules.keymap.one_shot_shift')
local Json = require('json')
local f = assert(io.open(root .. '/static/ergopti_plus/_shared/tap_hold/one_shot_shift.json', 'rb'))
local owner = Owner.new(assert(Json.decode(f:read('*a')))); f:close()
assert(not pcall(function() owner:arm(10, 0) end))
owner:arm(10, math.huge)
assert(owner.deadline == math.huge)
print(Json.encode({zero_rejected=true, positive_infinity_accepted=true,
 qualification='Actual original Owner.arm accepts math.huge. Positive does not mean finite. No infinite UI preset or persistence support is established; frozen shared report remains unchanged.'}))
