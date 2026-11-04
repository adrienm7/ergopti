--- tests/support/onboarding_delivery_fixture.lua

--- ==============================================================================
--- MODULE: Onboarding Delivery Native Fixture
--- DESCRIPTION:
--- Provides isolated wizard callbacks and virtual file access for boundary tests.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_window = require("tests.support.dashboard_window_fixture")

local function with_delivery(callback, native_timers)
	helpers.with_fresh_modules({ "ui.menu.menu_paths", "infra.toml.codec", "infra.toml.writer",
		"adapters.file_system", "infra.config_paths", "platform.remap", "json" }, function()
		-- Distinctive rule: a wizard that derived the path itself cannot match it.
		package.loaded["infra.config_paths"] = {
			get_config_dir = function() return "/virtual/current/" end,
			metrics_dir = function(dir) return "<metrics of " .. dir .. ">" end,
			get = function(key)
				assert(key == "KarabinerConfigPath", "unexpected path key " .. tostring(key))
				return "/virtual/current/hammerspoon/config_karabiner.toml"
			end,
		}
		-- The remap owner reports the tap-hold keys beside each config.toml read:
		-- none here, so the pages start from config.toml's values alone.
		package.loaded["platform.remap"] = {
			recommended_key_report = function() return { enabled = false, keys = {} } end,
		}
		local picker = {}
		package.loaded["ui.menu.menu_paths"] = {
			get_config_dir = function() return "/virtual/current" end,
			get_default_config_dir = function() return "/virtual/default" end,
			pick_config_dir = function(current, prompt)
				picker.current, picker.prompt = current, prompt
				return "/virtual/chosen/"
			end,
		}
		package.loaded["infra.toml.codec"] = { decode = function() return {} end }
		with_window("ui.onboarding", function(onboarding, state)
			require("tests.support.onboarding_shared_data").install()
			local pending, errors, evaluations = {}, {}, {}
			local i18n = package.loaded["infra.i18n"]
			i18n.get_locale = function() return "en" end
			i18n.format = function(key) return key end
			i18n.get_sorted_locales = function() return {} end
			state.picker = picker
			state.titles = {}
			package.loaded["ui.ui_builder"].set_window_title = function(view, title)
				state.titles[#state.titles + 1] = { view = view, title = title }
				return true
			end
			local Json = require("json")
			local shared_encode, native_encode = Json.encode, hs.json.encode
			Json.encode = function(value)
				if state.encode then return state.encode(value) end
				return shared_encode(value)
			end
			-- Retain the native port so causal controls can model LuaSkin's empty
			-- table-to-array conversion independently of the production encoder.
			hs.json.encode = function(value)
				if type(value) ~= "table" then error("hs.json.encode requires a table", 2) end
				if state.encode then return state.encode(value) end
				if state.native_encode then return state.native_encode(value, shared_encode) end
				return native_encode(value)
			end
			hs.fs.attributes = function() return {} end
			hs.fs.symlinkAttributes = function(path)
				if path:match("/config%.toml$") then
					return { mode = "file", dev = 1, ino = 2, size = #"fixture", modification = 1, change = 1 }
				end
				return { mode = "directory", dev = 1, ino = 1 }
			end
			hs.fs.pathToAbsolute = function(path) return path end
			local native_timer_new, owned_timers, scheduler
			if native_timers then
				owned_timers, state.timer_attempts, state.read_paths = {}, 0, {}
				native_timer_new = hs.timer.new
				hs.timer.new = function(_, callback)
					state.timer_attempts = state.timer_attempts + 1
					if state.timer_refusal == "new" then return false end
					local timer = { callback = callback, active = false, stops = 0 }
					function timer:start()
						if state.timer_refusal == "start" then return false end
						self.active = true
						if state.on_timer_start then state.on_timer_start() end
						if state.timer_synchronous then self.callback() end
						return self
					end
					function timer:running() return self.active end
					function timer:stop()
						self.stops = self.stops + 1
						self.active = false
						return self
					end
					owned_timers[#owned_timers + 1] = timer
					return timer
				end
				package.loaded["adapters.timer_scheduler"] = nil
				scheduler = require("adapters.timer_scheduler")
				package.loaded["infra.deferred_work"] = nil
				require("infra.deferred_work")
				package.loaded["ui.onboarding"] = nil
				onboarding = require("ui.onboarding")
				state.focus_attempts = 0
				package.loaded["ui.ui_builder"].force_focus = function(view, _, options)
					state.focus_attempts = state.focus_attempts + 1
					return options.is_current() == true and state.view == view
				end
				state.native_timers, state.scheduler = owned_timers, scheduler
				state.fire_timer = function(index) owned_timers[index].callback() end
			else
				package.loaded["infra.deferred_work"].after = function(_, fn)
					pending[#pending + 1] = fn
					return true
				end
			end
			package.loaded["infra.logger"].error = function(_, message, ...)
				errors[#errors + 1] = string.format(message, ...)
				if state.on_error then state.on_error() end
			end
			local original_open = io.open
			local ok, err = xpcall(function()
				io.open = function(path, mode)
					if native_timers then state.read_paths[#state.read_paths + 1] = path end
					helpers.assert_eq(mode, "r", "fixture must never authorize config writes")
					return { read = function() return "fixture" end, close = function() return true end }
				end
				local function open(config_path)
					helpers.assert_true(onboarding.run(config_path or "/virtual/config.toml"))
					state.view.evaluateJavaScript = function(self, code, done)
						local arguments = code:match("^window%.[%w_]+%((.*)%)$")
						if arguments then state.payload = Json.decode(arguments) end
						evaluations[#evaluations + 1] = { code = code, done = done, view = self }
						if state.submit then return state.submit(self, code, done) end
						return self
					end
				end
				open()
				callback(onboarding, state, pending, errors, evaluations, open)
			end, debug.traceback)
			local cleanup_errors = {}
			if native_timers then
				state.refused, state.on_error = false, nil
				local function cleanup(operation)
					local cleaned, detail = pcall(operation)
					if not cleaned then cleanup_errors[#cleanup_errors + 1] = tostring(detail) end
				end
				local owned_view = state.view
				-- Native close retires page authority before exact fixture disposal.
				cleanup(function() owned_view.options.on_close() end)
				cleanup(function() owned_view:delete() end)
				for _, timer in ipairs(owned_timers) do
					cleanup(function() timer.callback() end)
					cleanup(function() timer:stop() end)
				end
				cleanup(function() helpers.assert_eq(scheduler.activeCount(), 0, "owned native timers retire") end)
				hs.timer.new = native_timer_new
			end
			io.open = original_open
			if not ok then
				if #cleanup_errors > 0 then pcall(function() io.stderr:write(table.concat(cleanup_errors, "\n") .. "\n") end) end
				error(err, 0)
			end
			if #cleanup_errors > 0 then error(table.concat(cleanup_errors, "\n"), 0) end
		end)
	end)
end

local function dispatch(route, state, pending)
	local body = {
		previewLocale = { action = "previewLocale", locale = "fr" },
		ready = { action = "ready" },
		pickConfigDir = { action = "pickConfigDir", current = "/virtual/current" },
		loadExistingConfig = { action = "loadExistingConfig", config_dir = "/virtual/chosen", request = 1 },
	}
	state.receiver({ body = body[route] })
	if route == "ready" then pending[#pending]() end
end

return { with_delivery = with_delivery, dispatch = dispatch }
