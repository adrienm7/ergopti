--- tests/unit/modules/shortcuts/system_actions/test_keep_awake_end_notice.lua

--- ==============================================================================
--- MODULE: Keep-Awake End Notice Vectors (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/shortcuts/keep_awake_end_notice_vectors.json:
--- the toggle, the user's activity and a pause each show the shared end banner
--- once, a pause while off and the driver's exit show none (maintainer decision
--- SNU-12, 2026-11-21). Before, the activity cut and the pause were silent.
--- Windows and Linux replay the same file.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("core.text.engine.json")
local fixture = require("tests.support.system_actions_fixture")
local load_system = fixture.load_system
local with_fixture = fixture.with_fixture
local as_physical = fixture.as_physical
local fire_post_callback_actions = fixture.fire_post_callback_actions

local function read_vectors()
	local path = helpers.driver_root() .. "/../_shared/tests/corpus/shortcuts/keep_awake_end_notice_vectors.json"
	local file = assert(io.open(path, "r"), "keep-awake end notice vectors not found")
	local raw = file:read("*a")
	file:close()
	return assert(json.decode(raw), "keep-awake end notice vectors did not decode")
end

--- A fresh module with a banner spy, a settable clock and the watcher callback.
local function build()
	package.loaded["platform.input.keycodes"] = nil
	package.loaded["modules.shortcuts.actions.system"] = nil
	package.loaded["core.events.timer_scheduler"] = nil
	package.loaded["platform.input.synthetic_input"] = nil
	package.loaded["diagnostics.adapters.event_provenance"] = nil
	local sys = load_system()
	local hs = _G.hs
	local state = { now = 1000, shown = {}, cb = nil }
	hs.timer.secondsSinceEpoch = function() return state.now end
	hs.timer.absoluteTime = function() return state.now * 1e9 end
	hs.alert.show = function(msg) state.shown[#state.shown + 1] = msg; return "uuid" end
	hs.alert.closeAll = function() end
	hs.alert.closeSpecific = function() end
	hs.eventtap.new = function(_types, cb)
		state.cb = cb
		local tap = { enabled = false }
		function tap:start() self.enabled = true; return self end
		function tap:stop() self.enabled = false; return self end
		function tap:isEnabled() return self.enabled end
		return tap
	end
	return sys, state
end

--- Ends the session the way the case's cause does on macOS.
local function finish(sys, state, cause)
	if cause == "toggle" then
		sys.toggle_awake()
	elseif cause == "activity" then
		state.now = state.now + 100 -- past the activation grace window
		state.cb(as_physical({
			getType = function() return 4242 end,
			getFlags = function() return {} end,
			location = function() return { x = 0, y = 0 } end,
		}))
		fire_post_callback_actions(_G.hs)
	elseif cause == "pause" then
		sys.pause_awake()
	elseif cause == "exit" then
		sys.stop_awake()
	else
		error("unknown keep-awake end cause: " .. tostring(cause))
	end
end

helpers.describe("keep-awake end notice (snu-12-2026-11-21)", function()
	helpers.it("every end of a running session shows the shared end banner once", function()
		local data = read_vectors()
		local replayed = 0
		for _, case in ipairs(data.cases) do
			local applies = false
			for _, driver in ipairs(case.drivers) do applies = applies or driver == "macos" end
			if applies then
				with_fixture(function()
					local sys, state = build()
					local expected = require("core.i18n.engine.i18n").get(data.key)
					if case.active then
						sys.toggle_awake()
						helpers.assert_true(sys.is_awake_active(), case.id .. ": the session runs")
					end
					state.shown = {}
					finish(sys, state, case.cause)
					helpers.assert_eq(#state.shown, case.notices, case.id .. ": banners shown at the end")
					for _, msg in ipairs(state.shown) do
						helpers.assert_eq(msg, expected, case.id .. ": the banner is the shared end key's text")
					end
				end)
				replayed = replayed + 1
			end
		end
		helpers.assert_eq(replayed, 5, "every macOS case of the shared vectors is replayed")
	end)
end)
