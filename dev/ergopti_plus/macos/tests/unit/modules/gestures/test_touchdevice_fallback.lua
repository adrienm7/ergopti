--- tests/unit/modules/gestures/test_touchdevice_fallback.lua

--- ==============================================================================
--- MODULE: gestures.touchdevice Fallback Regression Tests
--- DESCRIPTION:
--- Protects startup behavior when touchdevice is unavailable in packaged
--- runtimes: loader candidate ordering, warning-level degradation, and no
--- hard-error path on M.start.
--- ============================================================================== 

local helpers = require("tests.helpers")





--- ==========================================
--- ==========================================
--- ======= 1/ Source-level invariants =======
--- ==========================================
--- ==========================================

-- Selected by a declaration unique to modules/gestures/init.lua rather than by
-- path, so moving or splitting the module cannot turn these invariants into a
-- path error. The old form returned "" on a missing file, which made every
-- assertion below pass against an empty string.
local SOURCE = helpers.read_driver_source("local function schedule_emergency_recycle")
helpers.assert_true(SOURCE ~= nil, "modules/gestures/init.lua source must be locatable")

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





--- ========================================
--- ========================================
--- ======= 2/ Runtime degraded mode =======
--- ========================================
--- ========================================

helpers.describe("gestures startup degraded mode", function()
	local original_logger = package.loaded["infra.logger"]
	local original_notifications = package.loaded["infra.notifications"]
	local original_actions = package.loaded["modules.gestures.actions"]
	local original_engine = package.loaded["modules.gestures.engine"]
	local original_conflicts = package.loaded["modules.gestures.conflicts"]
	local original_gestures = package.loaded["modules.gestures"]
	local touchdevice_candidates = {
		"hs._asm.undocumented.touchdevice",
		"vendor.hs_asm.undocumented.touchdevice",
	}
	local original_touchdevice = {}
	local original_touchdevice_preload = {}
	for _, name in ipairs(touchdevice_candidates) do
		original_touchdevice[name] = package.loaded[name]
		original_touchdevice_preload[name] = package.preload[name]
		package.loaded[name] = nil
		package.preload[name] = function()
			error("injected unavailable touchdevice module")
		end
	end

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

	package.loaded["infra.logger"] = logger_stub
	package.loaded["infra.notifications"] = { notify = function() end }
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
		stop = function() return true end,
	}
	package.loaded["modules.gestures.conflicts"] = {
		on_action_changed = function() end,
		apply_all_overrides = function() end,
		restore_all_overrides = function() end,
	}

	package.loaded["modules.gestures"] = nil
	local gestures = require("modules.gestures")

	helpers.it("M.start degrades without losing the module, when touchdevice cannot load", function()
		-- Called directly: a raise fails with the real error. And note what is NOT
		-- asserted — is_enabled(). It reflects the USER's feature flag, not whether a
		-- device was found, and a start with no hardware must leave that flag alone:
		-- the user still wants gestures, the trackpad just is not there. What must
		-- hold is that the module survives usable, so plugging a device in and
		-- calling start() again works.
		gestures.start()
		gestures.stop()
		gestures.start()
		helpers.assert_eq(type(gestures.get_all_actions()), "table",
			"a failed start must leave the slot table readable — the menu renders from it "
				.. "whether or not a device was found")
	end)

	helpers.it("M.start logs a warning and no error on missing touchdevice", function()
		logs.warn = 0
		logs.error = 0
		gestures.start()
		helpers.assert_true(logs.warn >= 1)
		helpers.assert_eq(logs.error, 0)
	end)

	package.loaded["infra.logger"] = original_logger
	package.loaded["infra.notifications"] = original_notifications
	package.loaded["modules.gestures.actions"] = original_actions
	package.loaded["modules.gestures.engine"] = original_engine
	package.loaded["modules.gestures.conflicts"] = original_conflicts
	package.loaded["modules.gestures"] = original_gestures
	for _, name in ipairs(touchdevice_candidates) do
		package.loaded[name] = original_touchdevice[name]
		package.preload[name] = original_touchdevice_preload[name]
	end
end)
