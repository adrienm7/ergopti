--- tests/unit/ui/menu/menu_llm/test_ollama_download_single_slot.lua

--- =============================================================================
--- MODULE: Ollama Download Exact-Owner Regression
--- DESCRIPTION:
--- Proves that the single pull slot retains its exact native task until the
--- completion callback settles cancellation, and that every rejected or failed
--- request receives one terminal callback without publishing stale model state.
--- =============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"infra.i18n",
	"infra.logger",
	"infra.notifications",
	"infra.text_utils",
	"modules.llm.ollama_binary",
	"modules.llm.ollama_server_command",
	"adapters.shell_runner",
	"adapters.task_lifecycle",
	"adapters.timer_scheduler",
	"adapters.http_client",
	"ui.download_window",
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
	local http_callback
	local terminate_mode = options.terminate_mode or "self"

	local noop = function() end
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.logger"] = {
		debug = noop,
		info = noop,
		warn = noop,
		error = noop,
		callback = function(_, _, fn, ...)
			if type(fn) ~= "function" then return false, nil end
			return xpcall(fn, debug.traceback, ...)
		end,
	}
	package.loaded["infra.notifications"] = {
		notify = function() notifications = notifications + 1; return true end,
	}
	package.loaded["infra.text_utils"] = { shell_quote = function(value) return value end }
	package.loaded["modules.llm.ollama_binary"] = {
		resolve = function() return "/fixture/ollama" end,
	}
	package.loaded["modules.llm.ollama_server_command"] = {
		build = function() return "fixture restart" end,
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
		show = function(opts)
			progress.shows = progress.shows + 1
			progress.on_abort = opts.on_abort
			progress.on_cancel = opts.on_cancel
			progress.on_retry_start = opts.on_retry_start
			progress.on_retry = opts.on_retry
			return true
		end,
		update = noop,
		complete = function() progress.completes = progress.completes + 1; return true end,
	}
	package.loaded["adapters.task_lifecycle"] = {
		native = function(label, _, on_done, on_stream)
			if label == "Ollama model pull" and options.construct_result == false then
				return nil
			end
			local task = {
				label = label,
				on_done = on_done,
				on_stream = on_stream,
				terminate_calls = 0,
				running = false,
			}
			function task:start()
				self.running = options.start_result ~= false
				if options.complete_during_start ~= nil then on_done(options.complete_during_start) end
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
			notifications = function() return notifications end,
			http_callback = function() return http_callback end,
			set_terminate_mode = function(mode) terminate_mode = mode end,
		})
	end, debug.traceback)

	_G.hs = saved_hs
	for _, name in ipairs(MODULES) do package.loaded[name] = saved[name] end
	package.loaded["adapters.shell_runner"] = saved["adapters.shell_runner"]
	if not ok then error(err, 0) end
end

local function start_pull(fixture, target)
	local terminal = { success = 0, cancel = 0, reasons = {} }
	local accepted = fixture.manager.pull_model(target or "model-A", target or "model-A",
		function() terminal.success = terminal.success + 1; return true end,
		function(reason)
			terminal.cancel = terminal.cancel + 1
			terminal.reasons[#terminal.reasons + 1] = reason
			return true
		end,
		{ is_current = function() return true end })
	return accepted, terminal
end

local function assert_cancel_refusal(mode)
	with_fixture({ terminate_mode = mode }, function(f)
		local accepted, terminal = start_pull(f)
		helpers.assert_eq(accepted, true)
		local owner = f.active_tasks.ollama_pull
		helpers.assert_eq(f.progress.on_cancel(), false)
		helpers.assert_true(f.active_tasks.ollama_pull == owner)
		helpers.assert_eq(terminal.cancel, 1)
		helpers.assert_eq(terminal.success, 0)

		f.set_terminate_mode("self")
		helpers.assert_eq(f.progress.on_cancel(), true)
		helpers.assert_true(f.active_tasks.ollama_pull == owner)
		owner.on_done(0)
		helpers.assert_nil(f.active_tasks.ollama_pull)
		helpers.assert_eq(terminal.cancel, 1)
		helpers.assert_eq(f.effects.runtime, 0)
		helpers.assert_eq(f.effects.saves, 0)
	end)
end

helpers.describe("HS-010 Ollama download shared slot", function()
	helpers.it("(HS-010-busy-terminal) rejects a successor with one terminal and preserves the first owner", function()
		with_fixture({}, function(f)
			local accepted_a = start_pull(f, "model-A")
			helpers.assert_eq(accepted_a, true)
			local owner = f.active_tasks.ollama_pull
			local accepted_b, terminal_b = start_pull(f, "model-B")
			helpers.assert_eq(accepted_b, false)
			helpers.assert_eq(terminal_b.cancel, 1)
			helpers.assert_eq(terminal_b.reasons[1], "busy")
			helpers.assert_true(f.active_tasks.ollama_pull == owner)
			helpers.assert_eq(#f.pulls, 1)
			helpers.assert_eq(f.progress.shows, 1)
			helpers.assert_type(f.progress.on_abort, "function")
			helpers.assert_type(f.progress.on_retry_start, "function")
			helpers.assert_eq(f.progress.on_abort(), true)
			helpers.assert_eq(f.progress.on_retry_start(), true)
			helpers.assert_eq(f.progress.aborts, 1)
			helpers.assert_eq(f.progress.retry_starts, 1)
		end)
	end)

	helpers.it("(HS-010-native-self) retains an accepted cancellation until exact completion", function()
		with_fixture({ terminate_mode = "self" }, function(f)
			local accepted, terminal = start_pull(f)
			helpers.assert_eq(accepted, true)
			local owner = f.active_tasks.ollama_pull
			helpers.assert_eq(f.progress.on_cancel(), true)
			helpers.assert_true(f.active_tasks.ollama_pull == owner)
			helpers.assert_eq(owner.terminate_calls, 1)
			helpers.assert_eq(terminal.cancel, 0)

			owner.on_done(0)
			owner.on_done(0)
			helpers.assert_nil(f.active_tasks.ollama_pull)
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_eq(terminal.cancel, 1)
			helpers.assert_eq(f.effects.runtime, 0)
			helpers.assert_eq(f.effects.display, 0)
			helpers.assert_eq(f.effects.saves, 0)
		end)
	end)

	helpers.it("(HS-010-cancel-refusal-false) retains cleanup ownership after false", function()
		assert_cancel_refusal("false")
	end)

	helpers.it("(HS-010-cancel-refusal-nil) retains cleanup ownership after nil", function()
		assert_cancel_refusal("nil")
	end)

	helpers.it("(HS-010-cancel-refusal-throw) retains cleanup ownership after throw", function()
		assert_cancel_refusal("throw")
	end)

	helpers.it("(HS-010-sync-cancel-completion) latches cancellation before native completion", function()
		with_fixture({
			terminate_mode = function(task)
				task.on_done(0)
				return "self"
			end,
		}, function(f)
			local accepted, terminal = start_pull(f)
			helpers.assert_eq(accepted, true)
			local owner = f.active_tasks.ollama_pull
			helpers.assert_eq(f.progress.on_cancel(), true)
			helpers.assert_nil(f.active_tasks.ollama_pull)
			helpers.assert_eq(owner.terminate_calls, 1)
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_eq(terminal.cancel, 1)
			helpers.assert_eq(terminal.reasons[1], "user_cancelled")
			helpers.assert_eq(f.effects.runtime, 0)
			helpers.assert_eq(f.effects.saves, 0)
		end)
	end)

	helpers.it("(HS-010-construction-refusal) reports task construction refusal exactly once", function()
		with_fixture({ construct_result = false }, function(f)
			local accepted, terminal = start_pull(f)
			helpers.assert_eq(accepted, false)
			helpers.assert_nil(f.active_tasks.ollama_pull)
			helpers.assert_eq(#f.pulls, 0)
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_eq(terminal.cancel, 1)
			helpers.assert_eq(terminal.reasons[1], "task_construction_failed")
		end)
	end)

	helpers.it("(HS-010-start-refusal) reports task start refusal exactly once", function()
		with_fixture({ start_result = false }, function(f)
			local accepted, terminal = start_pull(f)
			helpers.assert_eq(accepted, false)
			helpers.assert_nil(f.active_tasks.ollama_pull)
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_eq(terminal.cancel, 1)
			helpers.assert_eq(terminal.reasons[1], "task_start_refused")
		end)
	end)

	helpers.it("(HS-010-sync-completion-refused-start) never publishes a callback delivered before start refusal", function()
		with_fixture({ start_result = false, complete_during_start = 0 }, function(f)
			local accepted, terminal = start_pull(f)
			helpers.assert_eq(accepted, false)
			helpers.assert_nil(f.active_tasks.ollama_pull)
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_eq(terminal.cancel, 1)
			helpers.assert_eq(terminal.reasons[1], "task_start_refused")
			helpers.assert_eq(f.effects.runtime, 0)
			helpers.assert_eq(f.effects.display, 0)
			helpers.assert_eq(f.effects.saves, 0)
			helpers.assert_nil(f.http_callback())
		end)
	end)

	helpers.it("(HS-010-sync-completion-accepted-start) settles a buffered failure exactly once", function()
		with_fixture({ complete_during_start = 2 }, function(f)
			local accepted, terminal = start_pull(f)
			helpers.assert_eq(accepted, false)
			helpers.assert_nil(f.active_tasks.ollama_pull)
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_eq(terminal.cancel, 1)
			helpers.assert_eq(terminal.reasons[1], "process_failed")
			helpers.assert_eq(f.effects.runtime, 0)
			helpers.assert_eq(f.effects.saves, 0)
		end)
	end)

	helpers.it("(HS-010-process-failure) reports a native pull failure exactly once", function()
		with_fixture({}, function(f)
			local accepted, terminal = start_pull(f)
			helpers.assert_eq(accepted, true)
			local owner = f.active_tasks.ollama_pull
			owner.on_done(2)
			owner.on_done(2)
			helpers.assert_nil(f.active_tasks.ollama_pull)
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_eq(terminal.cancel, 1)
			helpers.assert_eq(terminal.reasons[1], "process_failed")
		end)
	end)

	helpers.it("(HS-010-success-control) commits one model only after loadability succeeds", function()
		with_fixture({}, function(f)
			local accepted, terminal = start_pull(f)
			helpers.assert_eq(accepted, true)
			local owner = f.active_tasks.ollama_pull
			owner.on_done(0)
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_type(f.http_callback(), "function")
			f.http_callback()(200, "{}", {})
			helpers.assert_eq(terminal.success, 1)
			helpers.assert_eq(terminal.cancel, 0)
		end)
	end)
end)

return true
