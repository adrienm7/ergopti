-- Executes original shared parser and row policy; does not execute/emulate AHK.
local root = assert(arg[1], 'repository root required')
package.path = root .. '/static/ergopti_plus/_shared/lua/?.lua;' .. package.path
local Json = require('json')
local Parser = require('layouts.keylayout')
local Policy = require('layout.layout_rows_policy')
local function read(path)
 local f = assert(io.open(root .. '/' .. path, 'rb')); local s = f:read('*a'); f:close(); return s
end
local model = Parser.parse(read('static/layouts/registry/ergopti_plus/ergopti_plus.keylayout'))
local actions = {}
for _, action in ipairs(model.actions) do actions[action.id] = action.whens end
local map
for _, set in ipairs(model.key_map_sets) do
 if set.id == model.map_set then
  for _, candidate in ipairs(set.key_maps) do if candidate.index == 0 then map = candidate end end
 end
end
assert(map)
local function key(code)
 for _, entry in ipairs(map.keys) do if entry.code == code then return entry end end
 error('missing code ' .. code)
end
local function when(action, state)
 for _, entry in ipairs(assert(actions[action])) do if entry.state == state then return entry end end
 error('missing state ' .. state)
end
local trigger, follow = key(42), key(14)
local state = assert(when(trigger.action, 'none').next)
local selected = when(follow.action, state).output
local native_counterpart
for id in pairs(actions) do
 local neutral
 for _, w in ipairs(actions[id]) do if w.state == 'none' and w.output == 'e' then neutral = true end end
 if neutral then
  for _, w in ipairs(actions[id]) do
   if w.state == state then
    assert(native_counterpart == nil or native_counterpart == w.output)
    native_counterpart = w.output
   end
  end
 end
end
local rows = Policy.keys(Json.decode_lossless(read('static/ergopti_plus/_shared/data/keycodes/physical_keys.json')), Json.is_null)
local function contains(row, code) for _, entry in ipairs(rows[row]) do if entry == code then return true end end return false end
assert(contains('home_row', 'Backslash') and contains('top_row', 'KeyE'))
local switches = {emulate_number_row=true, emulate_top_row=false, emulate_home_row=true, emulate_bottom_row=true}
assert(Policy.emulates(switches, 'home_row') and not Policy.emulates(switches, 'top_row'))
assert(state == 's1_circumflex' and when(follow.action,'none').output == 'o')
assert(selected == 'ô' and native_counterpart == 'ê')
print(Json.encode({basis='original Lua parser and row-policy execution; Windows dispatch source-only', trigger={scan='SC02B',mac_code=42,row='home_row',state=state}, follow={scan='SC012',mac_code=14,row='top_row',emulated=false,selected_neutral='o',selected_pending=selected}, native_scenario={assumption='native US layout SC012 resolves e; no native reader executed',text='e',composition=native_counterpart}, result='distinct selected and native composition outputs confirmed in shipped data'}))
