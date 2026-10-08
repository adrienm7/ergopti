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
--- @return table logger_spy Injectable package.loaded["infra.logger"] replacement.
--- @return table error_messages Array of formatted strings passed to Logger.error (grows live).
local function make_error_capturing_logger()
	local error_messages = {}
	-- Real logger module, loaded fresh so it is unaffected by any stub a
	-- previous test file may have left in package.loaded.
	package.loaded["infra.logger"] = nil
	local real_logger = require("infra.logger")
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
		package.loaded["infra.logger"] = logger_stub

		local builder = helpers.load_with_stubs("ui.menu.builder")
		local i18n = require("infra.i18n")
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
		package.loaded["infra.logger"] = logger_stub

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

		local i18n = require("infra.i18n")
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


--- Exercises the actual two lifecycle builders through canonical source rows.
--- @param body function Receives a genuine build closure, root, i18n and actions.
local function with_lifecycle_root(body)
	return helpers.with_stub_scope({ "ui.menu.builder", "ui.menu.canvas_badge", "infra.manifest_menu",
		"menu.renderer", "infra.i18n", "infra.paths", "infra.logger" }, function()
		local logger = make_error_capturing_logger()
		package.loaded["infra.logger"] = logger
		helpers.load_with_stubs("ui.menu.builder")
		local renderer = require("infra.manifest_menu")
		local root = renderer.get_root()
		local commands = {}
		for _, row in ipairs(root.top_level) do
			if row.id == "reload" or row.id == "quit" then commands[#commands + 1] = row end
		end
		root.top_level = commands
		-- Canvas allocation has its own native owner/tests. This fixture observes
		-- only the actual completed command rows handed to that native boundary.
		package.loaded["ui.menu.canvas_badge"] = { prepend_to = function() end }
		package.loaded["ui.menu.builder"] = nil
		local builder = require("ui.menu.builder")
		local actions = make_actions()
		local context = { config = { log_level = 2 } }
		body(function() return builder.generate(context, {}, actions) end, root, require("infra.i18n"), actions)
	end)
end

--- Reads independent source locale/caption data without regenerating expectations.
--- @param relative string Exact shared resource.
--- @return table
local function lifecycle_json(relative)
	local file = assert(io.open(helpers.shared(relative), "rb"))
	local raw = file:read("*a")
	file:close()
	return require("json").decode(raw)
end

helpers.describe("root lifecycle commands own declared Mac captions and retained native delivery", function()
	for _, locale in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja",
		"ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
		helpers.it("preserves independently frozen Reload/Quit captions and native acknowledgments: " .. locale, function()
			with_lifecycle_root(function(build, _, i18n, actions)
				local prior = lifecycle_json("tests/corpus/menus/macos_lifecycle_command_captions.json").captions[locale]
				local strings = lifecycle_json("data/locales/" .. locale .. ".json")
				i18n.get = function(key) return strings[key] or key end
				local calls = {}
				actions.reload = function(value) calls[#calls + 1] = { "reload", value }; return false end
				actions.quit = function(value) calls[#calls + 1] = { "quit", value }; return true end
				local rows = build()
				helpers.assert_eq(#rows, 2, "exactly one native-visible row per command")
				helpers.assert_eq(rows[1].title, prior.reload.macos)
				helpers.assert_eq(rows[2].title, prior.quit.macos)
				helpers.assert_true(rows[1].disabled ~= true and rows[2].disabled ~= true)
				helpers.assert_eq(rows[1].fn("reload-arg"), false)
				helpers.assert_eq(rows[2].fn("quit-arg"), true)
				helpers.assert_eq(calls, { { "reload", "reload-arg" }, { "quit", "quit-arg" } })
			end)
		end)
	end
		helpers.it("a changed declared caption survives without native prefixing or token stripping", function()
		with_lifecycle_root(function(build, root, i18n)
			for _, row in ipairs(root.top_level) do
				for _, platform in ipairs(row.platforms or {}) do
					if platform == "hs" then row.i18n = "button.cancel" end
				end
			end
			local rows = build()
			helpers.assert_eq(#rows, 2)
			helpers.assert_eq(rows[1].title, i18n.get("button.cancel"))
			helpers.assert_eq(rows[2].title, i18n.get("button.cancel"))
		end)
	end)
		helpers.it("withdrawing the visible declaration blocks an already rendered callback", function()
		with_lifecycle_root(function(build, root, _, actions)
			local called = 0
			actions.reload = function() called = called + 1; return true end
			local rows = build()
			helpers.assert_eq(#rows, 2)
			helpers.assert_true(rows[1].disabled ~= true)
			for _, row in ipairs(root.top_level) do
				if row.id == "reload" and row.i18n == "menu.global.reload_macos" then row.platforms = { "linux" } end
			end
			helpers.assert_eq(rows[1].fn(), false)
			helpers.assert_eq(called, 0)
		end)
	end)
		helpers.it("visible ambiguity refuses a command while its hidden sibling remains harmless", function()
		with_lifecycle_root(function(build, root, _, actions)
			local called = 0
			actions.reload = function() called = called + 1; return true end
			local initial = build()
			helpers.assert_eq(#initial, 2)
			for _, row in ipairs(root.top_level) do
				if row.id == "reload" and row.i18n == "menu.global.reload" then row.platforms = { "hs" } end
			end
			helpers.assert_eq(initial[1].fn(), false)
			helpers.assert_eq(called, 0)
		end)
	end)
		helpers.it("missing native Reload owner never creates a clickable row", function()
		with_lifecycle_root(function(build, _, _, actions)
			actions.reload = nil
			local rows = build()
			helpers.assert_eq(#rows, 1)
			helpers.assert_type(rows[1].fn, "function", "the native Quit owner survives")
		end)
	end)
end)
