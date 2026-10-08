--- tests/support/ollama_pull_fixture.lua

--- ==============================================================================
--- MODULE: Original Ollama Pull Owner Fixture
--- DESCRIPTION:
--- Owns the original single-slot fixture once, shared by unchanged regression
--- cases and actual emitted-wrapper receiving. Network and binary ports retain
--- their original defaults unless a receiver supplies its independent values.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"infra.i18n",
	"infra.logger",
	"infra.notifications",
	"infra.text_utils",
	"modules.llm.ollama_binary",
	"modules.llm.ollama_server_command",
	"modules.llm.network_env",
	"modules.llm.opaque_network_admission",
	"adapters.shell_runner",
	"adapters.task_lifecycle",
	"adapters.timer_scheduler",
	"adapters.http_client",
	"ui.download_window",
	"ui.ui_builder",
	"infra.paths",
	"infra.deferred_work",
	"ui.download_window.javascript",
	"ui.menu.menu_llm.requirement_operation_registry",
	"ui.menu.menu_llm.models_manager_ollama",
}

local function with_fixture(options, callback)
	options = options or {}
	local saved_hs = _G.hs
	local saved = {}
	for _, name in ipairs(MODULES) do saved[name] = package.loaded[name] end

	local pulls = {}
	local progress = { shows = 0, completes = 0, aborts = 0, retry_starts = 0 }
	local notifications = 0
	local notification_records = {}
	local http_callback
	local terminate_mode = options.terminate_mode or "self"

	local noop = function() end
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.logger"] = {
		debug = noop,
		start = noop,
		success = noop,
		done = noop,
		info = noop,
		warn = noop,
		error = noop,
		callback = function(_, _, fn, ...)
			if type(fn) ~= "function" then return false, nil end
			return xpcall(fn, debug.traceback, ...)
		end,
	}
	package.loaded["infra.notifications"] = {
		notify = function(...)
			notifications = notifications + 1
			notification_records[#notification_records + 1] = table.pack(...)
			return true
		end,
	}
	package.loaded["infra.text_utils"] = nil
	package.loaded["modules.llm.ollama_binary"] = {
		resolve = function() return options.binary_path or "/fixture/ollama" end,
	}
	package.loaded["modules.llm.ollama_server_command"] = {
		build = function() return "fixture restart" end,
	}
	if options.network_admission then package.loaded["modules.llm.opaque_network_admission"] = options.network_admission end
	package.loaded["modules.llm.network_env"] = options.network_env or {
		prelude = function() return "", nil end,
		opaque_prelude = function() return "", nil end,
	}
	package.loaded["adapters.shell_runner"] = { spawn = function() return nil end }
	package.loaded["adapters.timer_scheduler"] = {
		after = function(_, fn)
			return { callback = fn, timer = {}, observers = {} }, true
		end,
		cancel = function(handle)
			handle.timer = nil
			local observers = handle.observers or {}
			handle.observers = {}
			for _, observer in ipairs(observers) do observer() end
			return true
		end,
		onSettled = function(handle, observer)
			if handle.timer == nil then observer() else
				handle.observers[#handle.observers + 1] = observer
			end
			return true
		end,
	}
	package.loaded["adapters.http_client"] = {
		new = function()
			local client = { settled = false, observers = {} }
			function client.post(_, _, _, done)
				http_callback = function(status, body, headers)
					local result = done({ status = status, body = body, headers = headers })
					if not client.settled then
						client.settled = true
						local observers = client.observers
						client.observers = {}
						for _, observer in ipairs(observers) do observer() end
					end
					return result
				end
				return true
			end
			function client.cancel()
				client.settled = true
				local observers = client.observers
				client.observers = {}
				for _, observer in ipairs(observers) do observer() end
				return true
			end
			function client.onSettled(observer)
				if client.settled then observer() else
					client.observers[#client.observers + 1] = observer
				end
				return true
			end
			return client
		end,
	}
	package.loaded["ui.download_window"] = {
		session_id = function() return progress.shows end,
		is_active = function() return progress.shows > 0 end,
		show = function(opts)
			progress.shows = progress.shows + 1
			progress.terminal_cmd = opts.terminal_cmd
			progress.on_abort = opts.on_abort
			progress.on_cancel = opts.on_cancel
			progress.on_retry_start = opts.on_retry_start
			progress.on_retry = opts.on_retry
			if options.show_replaced then progress.shows = progress.shows + 1 end
			return options.show_result ~= false
		end,
		update = function() progress.updates = (progress.updates or 0) + 1 end,
		complete = function() progress.completes = progress.completes + 1; return true end,
	}
	package.loaded["adapters.task_lifecycle"] = {
		native = function(label, executable, on_done, on_stream, args)
			if label == "Ollama model pull" and options.construct_result == false then
				return nil
			end
			local task = {
				label = label,
				executable = executable,
				args = args,
				on_done = on_done,
				on_stream = on_stream,
				terminate_calls = 0,
				running = false,
			}
			function task:start()
				self.running = options.start_result ~= false
				if options.complete_during_start ~= nil then on_done(options.complete_during_start, "", options.complete_stderr or "") end
				return options.start_result ~= false
			end
			function task:terminate()
				self.terminate_calls = self.terminate_calls + 1
				local mode = type(terminate_mode) == "function" and terminate_mode(self) or terminate_mode
				if mode == "throw" then error("fixture terminate refusal") end
				if mode == "false" then return false end
				if mode == "nil" then return nil end
				return self
			end
			function task:isRunning() return self.running end
			if label == "Ollama model pull" then pulls[#pulls + 1] = task end
			return task
		end,
		start = function(task) return task:start() == true end,
	}

	_G.hs = {
		execute = function() return "", true end,
		http = {
			asyncPost = function(_, _, _, cb) http_callback = cb; return true end,
		},
		json = { encode = function() return "{}" end },
		timer = {
			doAfter = function(_, fn) return { callback = fn } end,
			secondsSinceEpoch = function() return 0 end,
		},
		urlevent = { openURL = noop },
	}
	package.loaded["ui.menu.menu_llm.models_manager_ollama"] = nil
	local real_window, native_window
	if options.real_window then
		package.loaded["infra.paths"] = { shared = function()
			return helpers.driver_root() .. "../_shared"
		end }
		package.loaded["infra.deferred_work"] = { after = function() return true end }
		package.loaded["ui.download_window.javascript"] = nil
		package.loaded["ui.ui_builder"] = {
			get_app_geometry = function() return { width = 460, height = 380 } end,
			show_webview = function(opts)
				native_window = { codes = {}, opts = opts }
				function native_window:evaluateJavaScript(code)
					self.codes[#self.codes + 1] = code
					return self
				end
				function native_window:delete() end
				opts.on_webview_created(native_window)
				return native_window
			end,
		}
		_G.hs.webview = { usercontent = { new = function()
			return { setCallback = function() end }
		end } }
		_G.hs.screen = { mainScreen = function()
			return { frame = function() return { x = 0, y = 0, w = 1440, h = 900 } end }
		end }
		_G.hs.drawing = { windowLevels = { normal = 0, floating = 1 } }
		package.loaded["ui.download_window"] = nil
		real_window = require("ui.download_window")
	end

	local active_tasks = {}
	local state = { llm_model = "old-model" }
	local effects = { runtime = 0, display = 0, saves = 0 }
	local manager = require("ui.menu.menu_llm.models_manager_ollama").new({
		active_tasks = active_tasks,
		state = state,
		keymap = {
			set_llm_model = function() effects.runtime = effects.runtime + 1; return true end,
			set_llm_display_model_name = function() effects.display = effects.display + 1; return true end,
		},
		mark_download_aborted = function()
			progress.aborts = progress.aborts + 1
			return true
		end,
		clear_download_abort = function()
			progress.retry_starts = progress.retry_starts + 1
			return true
		end,
		save_prefs = function() effects.saves = effects.saves + 1; return true end,
	}, {}, function() return 8 end)

	local ok, err = xpcall(function()
		callback({
			manager = manager,
			active_tasks = active_tasks,
			state = state,
			effects = effects,
			pulls = pulls,
			progress = progress,
			window = real_window,
			native_window = function() return native_window end,
			notifications = function() return notifications end,
			notification_records = notification_records,
			http_callback = function() return http_callback end,
			set_terminate_mode = function(mode) terminate_mode = mode end,
		})
	end, debug.traceback)

	_G.hs = saved_hs
	for _, name in ipairs(MODULES) do package.loaded[name] = saved[name] end
	package.loaded["adapters.shell_runner"] = saved["adapters.shell_runner"]
	if not ok then error(err, 0) end
end

return { with_fixture = with_fixture }
