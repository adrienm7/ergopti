package.path = "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;" .. package.path
local helpers = require("tests.helpers")
local Fixture = require("tests.support.keylogger_provenance_fixture")
local owners = {
	"hs", "tests.stubs.hs", "infra.logger", "infra.manifest_reader", "infra.config_paths",
	"infra.dialog_util", "infra.teardown_transaction", "modules.keylogger.init",
	"modules.keylogger.log_manager", "modules.keylogger.context_tracker",
	"modules.keylogger.kc_bridge", "modules.keylogger.watchers", "modules.keylogger.timestamp",
	"adapters.synthetic_input", "adapters.event_provenance", "adapters.process_lifecycle",
	"adapters.keyboard_hook", "adapters.input_source_broker", "adapters.storage",
	"adapters.timer_scheduler", "modules.keylogger.aggregator.events",
	"modules.keylogger.aggregator.state", "modules.keylogger.aggregator.core",
	"ui.metrics_typing.init",
}
for _, managed in ipairs({ false, true }) do
	helpers.with_stub_scope(owners, function()
		local fixture = Fixture.load_keylogger()
		local handle_key
		for index = 1, 100 do
			local name, value = debug.getupvalue(fixture.keylogger.start, index)
			if not name then break end
			if name == "handle_key" then handle_key = value; break end
		end
		assert(type(handle_key) == "function", "real key handler missing")
		fixture.state.is_enabled = true
		fixture.state.is_secure_field = false
		fixture.state.session_start_time = 1
		package.loaded["modules.keylogger.kc_bridge"].is_ke_managed_output_kc = function(keycode)
			assert(keycode == 0)
			return managed
		end
		handle_key({
			getType = function() return fixture.hs.eventtap.event.types.keyDown end,
			getKeyCode = function() return 0 end,
			getCharacters = function() return "a" end,
			getFlags = function() return {} end,
			getProperty = function() return 0 end,
		})
		assert(#fixture.state.buffer_events == 1)
		local entry = fixture.state.buffer_events[1]
		assert(entry[1] == "a" and entry[3].s == false)
		local Events = require("modules.keylogger.aggregator.events")
		local State = require("modules.keylogger.aggregator.state")
		local Core = require("modules.keylogger.aggregator.core")
		State.initialized = true
		State.device_id = "managed-output-proof"
		Core.reset_batch()
		if managed then
			Events.walk_system_event({ timestamp = "2026-09-08 10:00:00.000",
				action = "karabiner_press", keycode = 36, app = "TestApp" })
		end
		Events.walk_typing({ timestamp = "2026-09-08 10:00:00.000",
			app = "TestApp", events = fixture.state.buffer_events })
		local counts = {}
		for _, row in pairs(State.agg_batch.kc_ngram) do counts[row.keycode] = row.count end
		print("managed=" .. tostring(managed) .. " output=" .. tostring(counts[0])
			.. " physical=" .. tostring(counts[36]))
		if managed then
			assert(counts[36] == 1 and counts[0] == nil, "remapped output double-counted")
		else
			assert(counts[0] == 1 and counts[36] == nil, "ordinary key count lost")
		end
	end)
end
