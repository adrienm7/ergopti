package.path = "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;" .. package.path
local helpers = require("tests.helpers")
local fixture = require("tests.support.keylogger_provenance_fixture").load_keylogger()
local callback
for index = 1, 100 do
	local name, value = debug.getupvalue(fixture.keylogger.start, index)
	if not name then break end
	if name == "handle_key" then callback = value end
end
assert(type(callback) == "function")
local captured_bridge = package.loaded["modules.keylogger.kc_bridge"]
package.loaded["modules.keylogger.kc_bridge"] = nil
local real_bridge = require("modules.keylogger.kc_bridge")
assert(real_bridge.refresh_managed_set({
	escape = { tap = "space", hold = "none" },
	spacebar = { tap = "none", hold = "none" },
}, { { id = "space", karabiner_to = { { key_code = "spacebar" } } } }))
assert(real_bridge.is_ke_managed_output_kc(49))
captured_bridge.is_ke_managed_output_kc = real_bridge.is_ke_managed_output_kc
fixture.state.is_enabled = true
fixture.state.is_secure_field = false
fixture.state.session_start_time = 1
callback({
	getType = function() return fixture.hs.eventtap.event.types.keyDown end,
	getKeyCode = function() return 49 end,
	getCharacters = function() return " " end,
	getFlags = function() return {} end,
	getProperty = function() return 0 end,
})
assert(#fixture.flushes == 1, "space must terminate the typing run")
local events = fixture.flushes[1].events
assert(#events == 1 and events[1][1] == " ")
local Events = require("modules.keylogger.aggregator.events")
local State = require("modules.keylogger.aggregator.state")
local Core = require("modules.keylogger.aggregator.core")
State.initialized = true
State.device_id = "managed-output-collision"
Core.reset_batch()
Events.walk_typing({ timestamp = "2026-09-08 10:00:00.000", app = "TestApp", events = events })
local counts = {}
for _, row in pairs(State.agg_batch.kc_ngram) do counts[row.keycode] = row.count end
print("physical_space_count=" .. tostring(counts[49]))
assert(counts[49] == 1, "global suppression lost the unjournaled physical Space")
