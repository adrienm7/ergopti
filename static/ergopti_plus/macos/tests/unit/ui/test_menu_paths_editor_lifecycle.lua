--- tests/unit/ui/test_menu_paths_editor_lifecycle.lua

--- ==============================================================================
--- MODULE: Paths Editor Lifecycle Regression Tests
--- DESCRIPTION:
--- Proves that the GUI owns an initialization state distinct from the already-
--- initialized path resolver. The extraction to infra.config_paths left
--- MenuPaths.is_initialized() delegated to the resolver while open_editor()
--- checked a deleted local. Normal boot therefore skipped MenuPaths.init() and
--- every menu or gesture action silently opened zero windows.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Loads a pristine paths editor behind an already-initialized resolver and
--- records native bridge/webview creation.
--- @param show_result table|false|string|nil Optional ui_builder result or `"throw"`.
--- @return table module
--- @return table calls
local function load_fixture(show_result)
	local calls = {
		bridge_callback = nil,
		config_init = 0,
		bridges = 0,
		delete_throws = false,
		deletes = 0,
		webviews = 0,
		focuses = 0,
		errors = {},
	}
	local logger = helpers.make_logger_stub()
	logger.error = function(_, fmt, ...)
		calls.errors[#calls.errors + 1] = string.format(fmt, ...)
	end
	package.loaded["infra.logger"] = logger
	package.loaded["infra.config_paths"] = {
		is_initialized = function() return true end,
		init = function()
			calls.config_init = calls.config_init + 1
			return true
		end,
		get = function(key) return "/tmp/ergopti/" .. tostring(key) end,
		get_config_dir = function() return "/tmp/ergopti/" end,
		get_default_config_dir = function() return "/Users/test/.config/ergopti_plus/" end,
		set_config_dir = function() return true end,
	}
	local default_webview = {
		id = "paths-editor",
		delete = function()
			calls.deletes = calls.deletes + 1
			if calls.delete_throws then error("synthetic paths editor delete refusal") end
		end,
	}
	package.loaded["ui.ui_builder"] = {
		get_app_geometry = function() return { width = 620, height = 480 } end,
		get_centered_frame = function(w, h) return { x = 0, y = 0, w = w, h = h } end,
		show_webview = function(opts)
			calls.webviews = calls.webviews + 1
			if show_result == "throw" then error("native webview exploded") end
			if show_result == false then return false end
			local candidate = type(show_result) == "table" and show_result or default_webview
			if type(opts.on_webview_created) == "function"
				and opts.on_webview_created(candidate) ~= true then return nil end
			if show_result == "close_once" and calls.webviews == 1 then opts.on_close() end
			return candidate
		end,
		force_focus = function()
			calls.focuses = calls.focuses + 1
			return true
		end,
	}

	_G._base_dir = nil
	local module = helpers.load_with_stubs("ui.menu.menu_paths", {
		webview = {
			usercontent = {
				new = function()
					calls.bridges = calls.bridges + 1
					return { setCallback = function(_, callback)
						calls.bridge_callback = callback
						return true
					end }
				end,
			},
			windowMasks = { titled = 1, closable = 2 },
		},
		screen = {
			mainScreen = function()
				return { frame = function() return { w = 1920, h = 1080 } end }
			end,
		},
	})
	return module, calls
end


helpers.describe("paths editor owns its boot lifecycle", function()
	helpers.it("opens after normal boot even though the resolver was initialized first", function()
		local MenuPaths, calls = load_fixture()

		-- This is the exact gate in ui/menu/init.lua. Delegating is_initialized()
		-- to ConfigPaths used to skip the editor's own dependency injection.
		if not MenuPaths.is_initialized() then
			helpers.assert_true(MenuPaths.init("/Applications/ErgoptiPlus.app/", function() end))
		end

		helpers.assert_true(MenuPaths.open_editor())
		helpers.assert_eq(calls.config_init, 0,
			"an already-initialized resolver must not be initialized twice")
		helpers.assert_eq(calls.bridges, 1,
			"the user action must create one native usercontent bridge")
		helpers.assert_eq(calls.webviews, 1,
			"the user action must create one visible editor webview")
	end)

	helpers.it("fails visibly before editor init instead of consulting a stray global", function()
		local MenuPaths, calls = load_fixture()

		helpers.assert_eq(MenuPaths.open_editor(), false)
		helpers.assert_eq(calls.bridges, 0)
		helpers.assert_eq(calls.webviews, 0)
		helpers.assert_true(#calls.errors >= 1,
			"a pre-init user action must reach the file logger")
	end)

	helpers.it("reports a refused webview creation and stays retryable", function()
		local MenuPaths, calls = load_fixture(false)
		helpers.assert_true(MenuPaths.init("/Applications/ErgoptiPlus.app/", function() end))

		helpers.assert_eq(MenuPaths.open_editor(), false)
		helpers.assert_eq(MenuPaths.open_editor(), false)
		helpers.assert_eq(calls.bridges, 2,
			"failed native ownership must not publish a stale singleton")
		helpers.assert_eq(calls.webviews, 2)
		helpers.assert_true(#calls.errors >= 2)
	end)

	helpers.it("file-logs a native construction throw instead of escaping the callback", function()
		local MenuPaths, calls = load_fixture("throw")
		helpers.assert_true(MenuPaths.init("/Applications/ErgoptiPlus.app/", function() end))

		helpers.assert_eq(MenuPaths.open_editor(), false)
		helpers.assert_eq(calls.webviews, 1)
		helpers.assert_true(#calls.errors >= 1)
		helpers.assert_true(calls.errors[#calls.errors]:find("native webview exploded", 1, true) ~= nil,
			"the async boundary must preserve the native traceback in the file log")
	end)

	helpers.it("does not publish an editor closed synchronously during construction", function()
		local MenuPaths, calls = load_fixture("close_once")
		helpers.assert_true(MenuPaths.init("/Applications/ErgoptiPlus.app/", function() end))

		helpers.assert_eq(MenuPaths.open_editor(), false,
			"a synchronously closed construction candidate must not report success")
		helpers.assert_eq(MenuPaths.open_editor(), true,
			"the closed candidate must not block a fresh editor")
		helpers.assert_eq(calls.webviews, 2,
			"the retry must construct a new native editor instead of reusing a ghost")
	end)

	helpers.it("blocks paths editor reuse until an ambiguous delete settles", function()
		local MenuPaths, calls = load_fixture()
		helpers.assert_true(MenuPaths.init("/Applications/ErgoptiPlus.app/", function() end))
		helpers.assert_true(MenuPaths.open_editor())
		helpers.assert_type(calls.bridge_callback, "function")
		calls.delete_throws = true

		calls.bridge_callback({body = {action = "cancel"}})
		helpers.assert_eq(MenuPaths.open_editor(), false,
			"an ambiguously deleted editor must not report reusable open success")
		helpers.assert_eq(calls.webviews, 1,
			"a failed cleanup retry must not allocate a second paths editor")
		helpers.assert_eq(calls.focuses, 0,
			"cleanup-only ownership must never focus an ambiguous native window")
		helpers.assert_eq(calls.deletes, 2,
			"open must retry deletion of the exact retained editor")
		calls.bridge_callback({body = {action = "cancel"}})
		helpers.assert_eq(calls.deletes, 2,
			"late bridge business must be fenced while cleanup remains ambiguous")

		calls.delete_throws = false
		helpers.assert_true(MenuPaths.open_editor())
		helpers.assert_eq(calls.deletes, 3,
			"the same exact editor must settle before its successor opens")
		helpers.assert_eq(calls.webviews, 2,
			"a successor may open only after exact native deletion")
	end)
end)
