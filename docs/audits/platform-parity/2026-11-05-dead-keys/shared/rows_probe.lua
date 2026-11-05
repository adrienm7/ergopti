-- Original physical-row policy, not a duplicate geometry implementation.
local root = assert(arg[1], "Pass repository root")
local shared = root .. "/static/ergopti_plus/_shared"
package.path = shared .. "/lua/?.lua;" .. shared .. "/lua/?/init.lua;" .. package.path
local file = assert(io.open(shared .. "/data/keycodes/physical_keys.json", "rb"))
local Json = require("json")
local registry = assert(Json.decode(file:read("*a"))); file:close()
local Policy = require("layout.layout_rows_policy")
local rows = Policy.keys(registry, function(value) return value == Json.null end)
local membership = {}
for row, codes in pairs(rows) do
 for _, code in ipairs(codes) do membership[code] = row end
end
assert(membership.Backslash == "home_row" and membership.KeyE == "top_row")
local settings = {emulate_number_row = true, emulate_top_row = false,
 emulate_home_row = true, emulate_bottom_row = true}
assert(Policy.emulates(settings, membership.Backslash))
assert(not Policy.emulates(settings, membership.KeyE))
print(assert(Json.encode({rows = rows, trigger_row = membership.Backslash,
 follow_row = membership.KeyE, trigger_enabled = true, follow_enabled = false,
 trigger = registry.keys.Backslash.ahk, follow = registry.keys.KeyE.ahk,
 qualification = "Actual shared row policy and physical registry; no Windows hotkey or native admission executed."})))
