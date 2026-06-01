--- tests/unit/modules/gestures/test_touchdevice_fallback.lua

--- ==============================================================================
--- MODULE: gestures.touchdevice Fallback Regression Tests
--- DESCRIPTION:
--- Protects startup behavior when touchdevice is unavailable in packaged
--- runtimes: loader candidate ordering, warning-level degradation, and no
--- hard-error path on M.start.
--- ============================================================================== 

local helpers = require("tests.helpers")




-- =========================================
-- =========================================
-- ======= 1/ Source-level invariants ======
-- =========================================
-- =========================================

local function read_source()
	local path = helpers.driver_root() .. "modules/gestures/init.lua"
	local fh = io.open(path, "r")
	if not fh then return "" end
	local body = fh:read("*a") or ""
	fh:close()
	return body
end

local SOURCE = read_source()

helpers.describe("gestures touchdevice loader source invariants", function()
	helpers.it("defines load_touchdevice_module helper", function()
		helpers.assert_true(SOURCE:find("local function load_touchdevice_module()", 1, true) ~= nil)
	end)

	helpers.it("tries hs._asm candidate first", function()
		local a = SOURCE:find("\"hs._asm.undocumented.touchdevice\"", 1, true)
		local b = SOURCE:find("\"vendor.hs_asm.undocumented.touchdevice\"", 1, true)
		helpers.assert_true(a ~= nil and b ~= nil)
		helpers.assert_true(a < b, "hs._asm candidate must be attempted before vendor fallback")
	end)

	helpers.it("logs the resolved touchdevice source module", function()
		helpers.assert_true(SOURCE:find("Touchdevice module loaded from '%s'.", 1, true) ~= nil)
	end)

	helpers.it("binds touchdevice from load_touchdevice_module", function()
		helpers.assert_true(SOURCE:find("local touchdevice = load_touchdevice_module()", 1, true) ~= nil)
	end)

	helpers.it("degrades with WARNING instead of ERROR when unavailable", function()
		helpers.assert_true(
			SOURCE:find("Touchdevice API is not available — gestures module disabled on this runtime.", 1, true) ~= nil
		)
		helpers.assert_true(
			SOURCE:find("Touchdevice API is not available — gestures module DISABLED.", 1, true) == nil
		)
	end)
end)




-- =======================================
-- =======================================
-- ======= 2/ Runtime degraded mode ======
-- =======================================
-- =======================================

helpers.describe("gestures startup degraded mode", function()
	local original_logger = package.loaded["lib.logger"]
	local original_notifications = package.loaded["lib.notifications"]
	local original_actions = package.loaded["modules.gestures.actions"]
	local original_engine = package.loaded["modules.gestures.engine"]
	local original_conflicts = package.loaded["modules.gestures.conflicts"]
	local original_gestures = package.loaded["modules.gestures"]

	local logs = {
		warn = 0,
		error = 0,
		messages = {},
	}

	local logger_stub = {
		start = function() end,
		info = function() end,
		debug = function() end,
		success = function() end,
		trace = function() end,
		done = function() end,
		warn = function(_, fmt)
			logs.warn = logs.warn + 1
			logs.messages[#logs.messages + 1] = tostring(fmt)
		end,
		error = function(_, fmt)
			logs.error = logs.error + 1
			logs.messages[#logs.messages + 1] = tostring(fmt)
		end,
	}

	package.loaded["lib.logger"] = logger_stub
	package.loaded["lib.notifications"] = { notify = function() end }
	package.loaded["modules.gestures.actions"] = {
		AX_NAMES = {},
		SG_NAMES = {},
		init = function() end,
		get_sg_names = function() return {} end,
		get_label = function() return "" end,
		force_cleanup = function() end,
		toggle_right_click = function() end,
		trigger_lookup = function() end,
		is_right_click_held = function() return false end,
	}
	package.loaded["modules.gestures.engine"] = {
		init = function() end,
		process_frame = function() end,
	}
	package.loaded["modules.gestures.conflicts"] = {
		on_action_changed = function() end,
		apply_all_overrides = function() end,
		restore_all_overrides = function() end,
	}

	package.loaded["modules.gestures"] = nil
	local gestures = helpers.load_with_stubs("modules.gestures")

	helpers.it("M.start does not throw when touchdevice cannot be loaded", function()
		local ok = pcall(gestures.start)
		helpers.assert_true(ok)
	end)

	helpers.it("M.start logs a warning and no error on missing touchdevice", function()
		helpers.assert_true(logs.warn >= 1)
		helpers.assert_eq(logs.error, 0)
	end)

	package.loaded["lib.logger"] = original_logger
	package.loaded["lib.notifications"] = original_notifications
	package.loaded["modules.gestures.actions"] = original_actions
	package.loaded["modules.gestures.engine"] = original_engine
	package.loaded["modules.gestures.conflicts"] = original_conflicts
	package.loaded["modules.gestures"] = original_gestures
end)
