--- tests/unit/modules/test_caps_word_constructor_custody.lua

--- ==============================================================================
--- MODULE: CapsWord Original Constructor Software Custody Controls
--- DESCRIPTION:
--- Runs the actual controlled Hook/Reader/output consumers. Cache/preload/source
--- labels never qualify a native semantic producer. No native IO is performed.
--- ==============================================================================

local h = require("tests.helpers")
local Fixture = require("tests.support.input_owner_fixture")
local actual_public = require("adapters.caps_word")
local original_source = debug.getinfo(actual_public.capture, "S").source

local function case(mode)
	local saved, preload = package.loaded["adapters.caps_word"], package.preload["adapters.caps_word"]
	local calls = { capture = 0, current = 0, plan = 0, preload = 0 }
	local factory = assert((loadstring or load)([[
		return function(calls)
			local token = {}
			return {
				capture = function() calls.capture = calls.capture + 1; return token end,
				current = function(owner) calls.current = calls.current + 1; return owner == token end,
				plan = function(owner, text)
					assert(owner == token and text == "A"); calls.plan = calls.plan + 1
					return { { keycode = 30, mods = { "shift" } } }, function() return true end
				end }
		end
	]], mode:find("source-label", 1, true) and original_source or "@/controlled/facade.lua"))()
	local facade = factory(calls)
	if mode:find("source-label", 1, true) then
		h.assert_eq(debug.getinfo(facade.capture, "S").source, original_source,
			"the counterfeit carries the exact actual semantic filename label")
	end
	if mode:find("preload", 1, true) then
		package.loaded["adapters.caps_word"] = nil
		package.preload["adapters.caps_word"] = function() calls.preload = calls.preload + 1; return facade end
	else
		package.loaded["adapters.caps_word"] = mode:find("genuine-warm", 1, true) and actual_public or facade
	end
	local succeeded, failure = pcall(function()
		Fixture.with_session({}, function(s)
			local pair = require("modules.shortcuts.key_combinations").new({
				keys = { { id = "caps_lock", key = "caps_lock" }, { id = "tab", key = "tab" } },
				hold_picker = { modifiers = { "ctrl", "shift" }, layers = { "nav" } },
				files = { read_with_status = function()
					return '[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "caps_word"\n', "ok"
				end }, route = function() return "/controlled/caps-word.toml" end,
				is_paused = function() return false end, changed = function() return true end,
				actions = { is_assignable = function(action) return action == "caps_word" end } })
			s.base.caps_word_plan = s.hook.plan_caps_word
			local installed = require("platform.remap.key_combination_engine").new(s.base,
				pair.engine_options({ caps_lock = 300, tab = 300 }))
			assert(s.hook.set_remapper(installed, function(action) return action end))
			s.pair(); s.edge("a", 58, 0, 101)
			h.assert_nil(s.base:input_arm_state(), "a modeled source has no genuine desktop semantic receipt")
			local before = #s.rows
			s.edge("a", 30, 1, 102); s.edge("a", 30, 0, 103)
			local wire = {}
			for index = before + 1, #s.rows do wire[#wire + 1] = s.rows[index][1] .. ":" .. s.rows[index][2] end
			h.assert_eq(table.concat(wire, ","), "30:1,30:0", "only ordinary physical A survives unqualified semantic admission")
			h.assert_eq(calls, { capture = 0, current = 0, plan = 0, preload = 0 },
				"neither cached table nor preloader supplies semantic calls or output authority")
			if mode == "genuine-warm-reinit" then
				s.hook.stop(); h.assert_true(not s.hook.isRunning(), "original consumer acknowledges modeled stop")
				s.hook.start(s.start_options); h.assert_true(s.hook.isRunning(), "same original Hook accepts legitimate reinit")
			elseif mode == "genuine-warm-hotplug" then
				local finder = package.loaded["modules.hotstrings.device_finder"]
				local find = finder.find_devices
				finder.find_devices = function() return { s.paths.a }, {} end
				s.hook.check_device(); h.assert_true(s.hook.isRunning(), "original consumer preserves the surviving modeled keyboard")
				finder.find_devices = find
				s.hook.check_device(); h.assert_true(s.hook.isRunning(), "original consumer reconciles the legitimate successor modeled source")
			end
			if mode == "genuine-warm-reinit" or mode == "genuine-warm-hotplug" then
				before = #s.rows; s.edge("a", 30, 1, 104); s.edge("a", 30, 0, 105)
				wire = {}
				for index = before + 1, #s.rows do wire[#wire + 1] = s.rows[index][1] .. ":" .. s.rows[index][2] end
				h.assert_eq(table.concat(wire, ","), "30:1,30:0", "legitimate lifecycle preserves original ordinary input")
				h.assert_eq(package.loaded["adapters.caps_word"], actual_public, "lifecycle never evicts a legitimate public cached module")
				h.assert_eq(calls, { capture = 0, current = 0, plan = 0, preload = 0 }, "lifecycle cannot borrow a semantic facade")
			end
		end)
	end)
	package.loaded["adapters.caps_word"], package.preload["adapters.caps_word"] = saved, preload
	if not succeeded then error(failure, 0) end
end

h.describe("CapsWord private original constructor custody", function()
	for _, mode in ipairs({ "cached", "source-label-cache", "preload", "source-label-preload", "genuine-warm", "genuine-warm-reinit", "genuine-warm-hotplug" }) do
		h.it("preserves normal consumers and denies facade authority: " .. mode, function() case(mode) end)
	end
end)
return true
