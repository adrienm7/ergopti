--- tests/unit/ui/healthcheck/test_healthcheck_permissions.lua

--- ==============================================================================
--- MODULE: Healthcheck reports the privacy permissions (macOS)
--- DESCRIPTION:
--- A packaged ErgoptiPlus.app without Screen Recording showed the Ctrl+H
--- selector and left nothing on the clipboard, and no diagnostic said why. The
--- diagnostics now report every permission the schema lists for macOS, in its
--- order, without ever prompting, and the page offers the settings page of a
--- missing one.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The macOS permission ids, as the schema declares them, sorted
local IDS = { "accessibility", "input_monitoring", "login_items", "screen_recording" }

--- Runs body with the real collectors over stubbed permission adapters.
--- @param states table accessibility and screen_recording native results, guardian status.
--- @param body function Receives (H, prompts).
local function with_permissions(states, body)
	local saved, prior_hs = {}, _G.hs
	for name, value in pairs(package.loaded) do saved[name] = value end
	local prompts = {}
	local ok, err = xpcall(function()
		helpers.load_with_stubs("infra.logger")
		-- Phase A reads the cached answers only: a live query fails the case
		package.loaded["adapters.accessibility_permission"] = {
			is_trusted = function() error("phase A must not query Accessibility live") end,
			last_known = function()
				local answer = states.accessibility
				return answer[1], answer[2], answer[3] ~= false
			end,
			request_prompt = function() prompts[#prompts + 1] = "accessibility" return true end,
		}
		package.loaded["adapters.screen_capture"] = {
			permission_state = function() error("phase A must not query Screen Recording live") end,
			last_known_permission = function()
				local answer = states.screen_recording
				return answer[1], answer[2], answer[3] ~= false
			end,
			request_permission = function() prompts[#prompts + 1] = "screen" return true end,
		}
		package.loaded["platform.remap.lease_controller"] = {
			is_initialized = function() return true end,
			status = function()
				if states.guardian == "raise" then error("not initialised") end
				return "starting", { phase = "starting", guardian_status = states.guardian }
			end,
		}
		-- The remap owner's diagnostic state: it alone knows whether Ergopti
		-- uses Karabiner at all, which the lease controller cannot tell.
		package.loaded["platform.remap"] = {
			guardian_state = function()
				if states.guardian == "raise" then error("not initialised") end
				return states.guardian
			end,
		}
		package.loaded["ui.healthcheck.helpers"] = nil
		body(require("ui.healthcheck.helpers"), prompts)
	end, debug.traceback)
	for name in pairs(package.loaded) do
		if saved[name] == nil then package.loaded[name] = nil end
	end
	for name, value in pairs(saved) do package.loaded[name] = value end
	_G.hs = prior_hs
	if not ok then error(err, 0) end
end

--- The items as an id → state map.
--- @param section table { items }
--- @return table
local function states_of(section)
	local out = {}
	for _, item in ipairs(section.items) do out[item.id] = item.state end
	return out
end

helpers.describe("healthcheck: macOS privacy permissions", function()
	helpers.it("the collector's ids are the schema's, in its order", function()
		local schema = require("healthcheck.snapshot").load_schema(helpers.shared("modules/diagnostics/schema.json"))
		local declared = {}
		for id in pairs(schema.permissions.macos) do declared[#declared + 1] = id end
		table.sort(declared)
		helpers.assert_eq(declared, IDS)
		with_permissions({ accessibility = { true }, screen_recording = { true }, guardian = "ready" }, function(H)
			local ids = {}
			for _, item in ipairs(H.collect_permissions(IDS).items) do ids[#ids + 1] = item.id end
			helpers.assert_eq(ids, IDS)
		end)
	end)

	helpers.it("reports a missing Screen Recording grant without prompting", function()
		with_permissions({ accessibility = { true }, screen_recording = { false }, guardian = "ready" },
			function(H, prompts)
				local states = states_of(H.collect_permissions(IDS))
				helpers.assert_eq(states.screen_recording, "missing")
				helpers.assert_eq(states.accessibility, "granted")
				helpers.assert_eq(#prompts, 0, "a diagnostic must never show a macOS prompt")
			end)
	end)

	helpers.it("reports a failed query as unknown", function()
		with_permissions({ accessibility = { nil, "ax down" }, screen_recording = { nil, "tcc down" }, guardian = "ready" },
			function(H)
				local states = states_of(H.collect_permissions(IDS))
				helpers.assert_eq(states.screen_recording, "unknown")
				helpers.assert_eq(states.accessibility, "unknown")
			end)
	end)

	helpers.it("reports a permission no live read answered yet as unknown", function()
		with_permissions({ accessibility = { nil, nil, false }, screen_recording = { nil, nil, false },
			guardian = "ready" }, function(H)
			local states = states_of(H.collect_permissions(IDS))
			helpers.assert_eq(states.accessibility, "unknown")
			helpers.assert_eq(states.screen_recording, "unknown")
		end)
	end)

	helpers.it("never claims Input Monitoring: Hammerspoon cannot ask without prompting", function()
		with_permissions({ accessibility = { true }, screen_recording = { true }, guardian = "ready" }, function(H)
			helpers.assert_eq(states_of(H.collect_permissions(IDS)).input_monitoring, "unknown")
		end)
	end)
end)

-- Field report 2026-11-05: phase A took 5.2 ms against its 5 ms budget, the
-- two live permission queries included.
helpers.describe("healthcheck: permission answers are cached by their live reads", function()
	--- Loads an adapter fresh over a scripted native answer.
	local function fresh(name, native)
		local saved_hs, saved_module = _G.hs, package.loaded[name]
		_G.hs = native
		package.loaded[name] = nil
		local ok, module = pcall(require, name)
		return ok and module or error(module, 0), function()
			_G.hs, package.loaded[name] = saved_hs, saved_module
		end
	end

	helpers.it("remembers the latest Accessibility answer (phase-a-permission-cache)", function()
		local answer = true
		local Permission, restore = fresh("adapters.accessibility_permission",
			{ accessibilityState = function() return answer end })
		local ok, err = pcall(function()
			helpers.assert_eq(select(3, Permission.last_known()), false)
			helpers.assert_eq(Permission.is_trusted(), true)
			answer = false
			helpers.assert_eq(Permission.last_known(), true, "no live read happens on last_known")
			helpers.assert_eq(Permission.is_trusted(), false)
			helpers.assert_eq(Permission.last_known(), false)
		end)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("remembers the latest Screen Recording answer (phase-a-permission-cache)", function()
		local Capture, restore = fresh("adapters.screen_capture",
			{ screenRecordingState = function() error("tcc down") end })
		local ok, err = pcall(function()
			helpers.assert_eq(select(3, Capture.last_known_permission()), false)
			helpers.assert_nil(Capture.permission_state())
			local granted, detail = Capture.last_known_permission()
			helpers.assert_nil(granted)
			helpers.assert_true(tostring(detail):find("tcc down", 1, true) ~= nil)
		end)
		restore()
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("healthcheck: remap approval state", function()
	helpers.it("reports a helper that requires Login Items approval as missing", function()
		with_permissions({ accessibility = { true }, screen_recording = { true }, guardian = "requires_approval" },
			function(H)
				helpers.assert_eq(states_of(H.collect_permissions(IDS)).login_items, "missing")
				helpers.assert_eq(H.collect_input().remap_phase, "starting")
			end)
	end)

	helpers.it("reports an approved helper as granted", function()
		with_permissions({ accessibility = { true }, screen_recording = { true }, guardian = "ready" }, function(H)
			helpers.assert_eq(states_of(H.collect_permissions(IDS)).login_items, "granted")
		end)
	end)

	helpers.it("reports an unavailable helper as unavailable, not as unknown", function()
		with_permissions({ accessibility = { true }, screen_recording = { true }, guardian = "unavailable" },
			function(H)
				helpers.assert_eq(states_of(H.collect_permissions(IDS)).login_items, "unavailable",
					"inert remaps need the Login Items action, not a shrug")
			end)
	end)

	helpers.it("reports the helper as not used while Ergopti does not use Karabiner", function()
		with_permissions({ accessibility = { true }, screen_recording = { true }, guardian = "not_used" },
			function(H)
				helpers.assert_eq(states_of(H.collect_permissions(IDS)).login_items, "not_used")
			end)
	end)

	helpers.it("degrades to unknown when the lease cannot be read", function()
		with_permissions({ accessibility = { true }, screen_recording = { true }, guardian = "raise" }, function(H)
			helpers.assert_eq(states_of(H.collect_permissions(IDS)).login_items, "unknown")
			helpers.assert_nil(H.collect_input().remap_phase)
		end)
	end)
end)
