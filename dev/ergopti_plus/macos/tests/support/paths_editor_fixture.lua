--- tests/support/paths_editor_fixture.lua

--- ==============================================================================
--- MODULE: Paths Editor Native Fixture
--- DESCRIPTION:
--- Creates isolated resolver and native observations without writing configuration.
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
			calls.options = opts
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

return load_fixture
