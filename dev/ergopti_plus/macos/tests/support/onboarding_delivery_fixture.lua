--- tests/support/onboarding_delivery_fixture.lua

--- ==============================================================================
--- MODULE: Onboarding Delivery Native Fixture
--- DESCRIPTION:
--- Provides isolated wizard callbacks and virtual file access for boundary tests.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_window = require("tests.support.dashboard_window_fixture")

local function with_delivery(callback)
	helpers.with_fresh_modules({ "ui.menu.menu_paths", "infra.toml.codec", "infra.toml.writer",
		"adapters.file_system" }, function()
		package.loaded["ui.menu.menu_paths"] = {
			get_config_dir = function() return "/virtual/current" end,
			get_default_config_dir = function() return "/virtual/default" end,
		}
		package.loaded["infra.toml.codec"] = { decode = function() return {} end }
		with_window("ui.onboarding", function(onboarding, state)
			local pending, errors, evaluations = {}, {}, {}
			local i18n = package.loaded["infra.i18n"]
			i18n.get_locale = function() return "en" end
			i18n.format = function(key) return key end
			i18n.get_sorted_locales = function() return {} end
			hs.json.encode = function(payload)
				state.payload = payload
				if state.encode then return state.encode(payload) end
				return "{}"
			end
			hs.fs.attributes = function() return {} end
			hs.fs.symlinkAttributes = function(path)
				if path:match("/config%.toml$") then
					return { mode = "file", dev = 1, ino = 2, size = #"fixture", modification = 1, change = 1 }
				end
				return { mode = "directory", dev = 1, ino = 1 }
			end
			hs.fs.pathToAbsolute = function(path) return path end
			hs.osascript.applescript = function() return true, "/virtual/chosen", "/virtual/chosen" end
			package.loaded["infra.deferred_work"].after = function(_, fn)
				pending[#pending + 1] = fn
				return true
			end
			package.loaded["infra.logger"].error = function(_, message, ...)
				errors[#errors + 1] = string.format(message, ...)
				if state.on_error then state.on_error() end
			end
			local original_open = io.open
			local ok, err = xpcall(function()
				io.open = function(_, mode)
					helpers.assert_eq(mode, "r", "fixture must never authorize config writes")
					return { read = function() return "fixture" end, close = function() return true end }
				end
				local function open()
					helpers.assert_true(onboarding.run("/virtual/config.toml"))
					state.view.evaluateJavaScript = function(self, code, done)
						evaluations[#evaluations + 1] = { code = code, done = done, view = self }
						if state.submit then return state.submit(self, code, done) end
						return self
					end
				end
				open()
				callback(onboarding, state, pending, errors, evaluations, open)
			end, debug.traceback)
			io.open = original_open
			if not ok then error(err, 0) end
		end)
	end)
end

local function dispatch(route, state, pending)
	local body = {
		previewLocale = { action = "previewLocale", locale = "fr" },
		ready = { action = "ready" },
		pickConfigDir = { action = "pickConfigDir", current = "/virtual/current" },
		loadExistingConfig = { action = "loadExistingConfig", config_dir = "/virtual/chosen" },
	}
	state.receiver({ body = body[route] })
	if route == "ready" then pending[#pending]() end
end

return { with_delivery = with_delivery, dispatch = dispatch }
