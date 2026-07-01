--- tests/unit/ui/menu/test_builder_tail_isolation.lua

--- ==============================================================================
--- MODULE: Regression — Builder.generate's tail calls run with no pcall isolation (F-MED-11)
--- DESCRIPTION:
--- ctx.llm_handler.build_download_item() and CanvasBadge.prepend_to() ran as bare,
--- unguarded calls at the very tail of Builder.generate — after every other
--- component (hotstrings, AI, metrics, shortcuts, karabiner, gestures, apps, the
--- global-actions tail) had already been built and inserted into `items`. Both
--- calls are the single highest-blast-radius spot in the whole menu-build
--- pipeline: an exception in either one unwinds straight out of M.generate and
--- converts one broken component (a bad download-item builder, or a canvas
--- rendering failure) into a TOTAL menu-rebuild failure — every already-built
--- component is lost, not just the badge or the download item.
---
--- Fix: wrap both calls in pcall + Logger.error, matching the isolation pattern
--- already used for the other component builders earlier in the same function
--- (e.g. the AI zone's `pcall(ctx.llm_handler.build_item)`).
---
--- This test stubs ctx.llm_handler.build_download_item to throw, and separately
--- stubs CanvasBadge.prepend_to to throw, and asserts M.generate still returns
--- the rest of the menu (with Logger.error firing) instead of raising — it
--- fails before the fix (M.generate itself raises) and passes after.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds a logger spy that wraps the REAL lib.logger (builder.lua needs its
--- real M.LEVELS / M.current_level for the log-level submenu, so a fully
--- synthetic make_logger_stub() is too minimal here) and records every
--- Logger.error call's already-formatted message.
--- @return table logger_spy Injectable package.loaded["lib.logger"] replacement.
--- @return table error_messages Array of formatted strings passed to Logger.error (grows live).
local function make_error_capturing_logger()
	local error_messages = {}
	-- Real logger module, loaded fresh so it is unaffected by any stub a
	-- previous test file may have left in package.loaded.
	package.loaded["lib.logger"] = nil
	local real_logger = require("lib.logger")
	local logger_spy = setmetatable({}, { __index = real_logger })
	logger_spy.error = function(module_name, fmt, ...)
		local ok, formatted = pcall(string.format, fmt, ...)
		error_messages[#error_messages + 1] = ok and formatted or tostring(fmt)
		real_logger.error(module_name, fmt, ...)
	end
	return logger_spy, error_messages
end

--- Minimal actions table satisfying builder.generate's top-level-tail loop.
local function make_actions()
	return {
		set_log_level     = function() end,
		open_logs         = function() end,
		open_today_log    = function() end,
		open_error_log    = function() end,
		open_console      = function() end,
		show_setup_wizard = function() end,
		open_paths        = function() end,
		reload            = function() end,
		quit              = function() end,
		enable_all        = function() end,
		disable_all       = function() end,
		reset_defaults    = function() end,
	}
end

helpers.describe("Builder.generate: tail calls (download item, canvas badge) are pcall-isolated (F-MED-11)", function()
	helpers.it("a throwing build_download_item does not prevent M.generate from returning the rest of the menu", function()
		local logger_stub, error_messages = make_error_capturing_logger()
		package.loaded["lib.logger"] = logger_stub

		local builder = helpers.load_with_stubs("ui.menu.builder")
		local i18n = require("lib.i18n")
		i18n.get = function(k) return k end
		i18n.build_language_menu_items = function() return {} end

		local ctx = {
			config = { log_level = 2 },
			llm_handler = {
				build_download_item = function()
					error("boom — simulated download-item builder crash")
				end,
			},
		}

		local ok_call, menu = pcall(builder.generate, ctx, {}, make_actions())

		helpers.assert_true(ok_call,
			"M.generate itself must never raise — a throwing build_download_item must be isolated by pcall (F-MED-11)")
		helpers.assert_true(type(menu) == "table" and #menu > 0,
			"the rest of the menu must still be returned when the download-item builder throws")

		local logged = false
		for _, msg in ipairs(error_messages) do
			if msg:find("download item", 1, true) then logged = true end
		end
		helpers.assert_true(logged, "Logger.error must fire naming the download-item builder failure")
	end)

	helpers.it("a throwing CanvasBadge.prepend_to does not prevent M.generate from returning the rest of the menu", function()
		local logger_stub, error_messages = make_error_capturing_logger()
		package.loaded["lib.logger"] = logger_stub

		-- load_with_stubs unconditionally wipes every cached "ui.menu.*" module
		-- (so a leaked i18n stub can never survive between test files — see its
		-- own comment), which would also erase a canvas_badge stub installed
		-- beforehand. Call it first to get past that wipe, THEN install the
		-- throwing stub and force ui.menu.builder to re-require it fresh.
		local builder = helpers.load_with_stubs("ui.menu.builder")
		package.loaded["ui.menu.canvas_badge"] = {
			prepend_to = function(_items, _ctx, _on_click)
				error("boom — simulated canvas badge crash")
			end,
		}
		package.loaded["ui.menu.builder"] = nil
		builder = require("ui.menu.builder")

		local i18n = require("lib.i18n")
		i18n.get = function(k) return k end
		i18n.build_language_menu_items = function() return {} end

		local ctx = { config = { log_level = 2 } }

		local ok_call, menu = pcall(builder.generate, ctx, {}, make_actions())

		helpers.assert_true(ok_call,
			"M.generate itself must never raise — a throwing CanvasBadge.prepend_to must be isolated by pcall (F-MED-11)")
		helpers.assert_true(type(menu) == "table" and #menu > 0,
			"the rest of the menu must still be returned when the canvas badge builder throws")

		local logged = false
		for _, msg in ipairs(error_messages) do
			if msg:find("canvas badge", 1, true) then logged = true end
		end
		helpers.assert_true(logged, "Logger.error must fire naming the canvas badge failure")
	end)
end)
