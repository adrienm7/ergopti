--- tests/unit/modules/llm/test_ollama_foreground_caller.lua
--- Exercises the actual API caller and shared lifecycle over controlled original
--- transport objects. These observations do not qualify native serving.
local helpers = require("tests.helpers")
local nonce, nonce_counter = nil, 28672
local function frame(role) return "ERGOPTI_MANAGED_DAEMON_V1 " .. nonce .. " " .. role .. "\n" end

local function with_api(kind, callback)
	nonce_counter = nonce_counter + 1
	nonce = string.format("%032x", nonce_counter)
	helpers.with_stub_scope({ "modules.llm.api_ollama", "adapters.managed_ollama_daemon",
		"adapters.shell_runner", "modules.llm.ollama_binary", "modules.llm.ollama_server_command",
		"adapters.http_client", "adapters.timer_scheduler", "adapters.json_codec",
		"modules.llm.api_common", "modules.llm.parser", "modules.llm.profiles",
		"modules.llm.progressive_reveal", "infra.logger", "infra.notifications", "infra.i18n",
		"modules.shortcuts.script_control" }, function()
		local shell = { tasks = {}, mode = "true", clients = {} }
		function shell.spawn(executable, args, done, chunk, environment, private, owned)
			local task = { settled = false, attempted = false, cancel_calls = 0, observers = {},
				executable = executable, args = args, chunk = chunk, private = private, owned = owned }
			function task.isSettled() return task.settled end
			function task.wasStartAttempted() return task.attempted end
			function task.onSettled(observer)
				if task.settled then observer() else task.observers[#task.observers + 1] = observer end
				return true
			end
			function task.start() task.attempted = true; return shell.mode == "true" end
			function task.terminate()
				task.cancel_calls = task.cancel_calls + 1
				if not task.attempted then task.settled = true; return true, "settled" end
				return true, "pending"
			end
			function task.emit(value) if chunk then chunk(task, value, "") end end
			function task.complete(status, remainder)
				task.settled = true
				done(status, remainder or "", "")
				local pending = task.observers; task.observers = {}
				for _, observer in ipairs(pending) do observer() end
			end
			shell.tasks[#shell.tasks + 1] = task
			return task
		end
		package.loaded["adapters.shell_runner"] = shell
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.notifications"] = { notify = function() return true end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["adapters.http_client"] = { new = function()
			local client = { settled = true, cancel_calls = 0 }
			function client.cancel() client.cancel_calls = client.cancel_calls + 1; return true end
			function client.isActive() return false end
			function client.isSettled() return client.settled end
			function client.get() return true end
			function client.post() return true end
			function client.onSettled(observer) observer(); return true end
			shell.clients[#shell.clients + 1] = client
			return client
		end }
		package.loaded["adapters.timer_scheduler"] = {
			after = function() error("no launch delay or readiness timer is admitted") end,
			cancel = function() return true end,
		}
		package.loaded["adapters.json_codec"] = { encode = function() return "{}" end, decode = function() return {} end }
		package.loaded["modules.llm.ollama_binary"] = { resolve = function() return "/fixture/ollama", nil, kind end }
		package.loaded["modules.llm.ollama_server_command"] = { build = function(_, _, _, _, caller_nonce)
			helpers.assert_eq(caller_nonce, nonce)
			return "exec /fixture/native-owner --caller-nonce '" .. nonce .. "' --owned-stdin"
		end }
		package.loaded["modules.llm.parser"] = {}
		package.loaded["modules.llm.profiles"] = {}
		package.loaded["modules.llm.progressive_reveal"] = {}
		package.loaded["modules.llm.api_common"] = { DEFAULT_DEDUPLICATION_ENABLED = true,
			OLLAMA_KEEP_ALIVE = "5m", get_retry_policy = function() return 1, 0, 0 end }
		package.loaded["modules.shortcuts.script_control"] = nil
		callback(helpers.load_with_stubs("modules.llm.api_ollama", {
			host = { uuid = function() return nonce:sub(1, 8) .. "-" .. nonce:sub(9, 12) .. "-"
				.. nonce:sub(13, 16) .. "-" .. nonce:sub(17, 20) .. "-" .. nonce:sub(21, 32) end },
		}), shell)
	end)
end

helpers.describe("Owned Ollama foreground API caller", function()
	for _, kind in ipairs({ "app", "user_app", "homebrew", "managed", "path", "unknown" }) do
		helpers.it("(daemon-caller-foreign) never kills or launches source " .. kind, function()
			with_api(kind, function(api, shell)
				local settled
				helpers.assert_eq(api.ensure_running({ is_authorized = function() return true end,
					on_settled = function(value) settled = value end }), false)
				helpers.assert_eq(#shell.tasks, 0)
				helpers.assert_eq(settled, false)
				helpers.assert_true(api.startup_idle())
			end)
		end)
	end

	helpers.it("(daemon-caller-ready) publishes only complete READY on its original foreground task", function()
		with_api("native_managed", function(api, shell)
			local verdicts = {}
			helpers.assert_true(api.ensure_running({ is_authorized = function() return true end,
				on_settled = function(value) verdicts[#verdicts + 1] = value end }))
			helpers.assert_eq(#shell.tasks, 1)
			local task = shell.tasks[1]
			helpers.assert_eq(task.executable, "/bin/sh")
			helpers.assert_eq(task.args[2]:find("pkill", 1, true), nil)
			helpers.assert_eq(task.args[2]:find("nohup", 1, true), nil)
			helpers.assert_eq(type(task.chunk), "function")
			helpers.assert_eq(task.private, true)
			helpers.assert_eq(task.owned, true)
			helpers.assert_eq(#verdicts, 0)
			helpers.assert_eq(api.startup_idle(), false)
			task.emit(frame("ACTIVE") .. frame("READY"):sub(1, 18))
			helpers.assert_eq(#verdicts, 0)
			task.emit(frame("READY"):sub(19))
			helpers.assert_eq(#verdicts, 1)
			helpers.assert_eq(verdicts[1], true)
			helpers.assert_true(api.startup_idle())
			task.complete(0, frame("RETIRED 0"))
		end)
	end)

	helpers.it("(daemon-caller-debt) cannot free a physically closed task missing its RETIRED frame", function()
		with_api("native_managed", function(api, shell)
			helpers.assert_true(api.ensure_running())
			local task = shell.tasks[1]
			task.complete(78, "")
			helpers.assert_eq(api.startup_idle(), false)
			helpers.assert_eq(api.ensure_running(), false)
			helpers.assert_eq(#shell.tasks, 1)
		end)
	end)

	helpers.it("(daemon-caller-guard) settles native refusal without ever publishing READY", function()
		with_api("native_managed", function(api, shell)
			local verdicts = {}
			helpers.assert_true(api.ensure_running({ is_authorized = function() return true end,
				on_settled = function(value) verdicts[#verdicts + 1] = value end }))
			shell.tasks[1].complete(78, frame("RETIRED 78"))
			helpers.assert_eq(#verdicts, 1)
			helpers.assert_eq(verdicts[1], false)
			helpers.assert_true(api.startup_idle())
		end)
	end)
end)

helpers.describe("Read-only Ollama migration owner admission", function()
	helpers.it("(ollama-migration-http-debt) rejects inactive HTTP cleanup debt without cancelling it", function()
		with_api("homebrew", function(api, shell)
			helpers.assert_true(api.migration_idle())
			helpers.assert_eq(#shell.clients, 5)
			for _, client in ipairs(shell.clients) do
				client.settled = false
				helpers.assert_eq(client.isActive(), false)
				helpers.assert_eq(api.migration_idle(), false)
				helpers.assert_eq(client.cancel_calls, 0)
				client.settled = true
				helpers.assert_true(api.migration_idle())
			end
		end)
	end)
end)

helpers.describe("Original retained API slots fence migration", function()
	local function set_slot(callback, wanted, value)
		for index = 1, 80 do
			local name = debug.getupvalue(callback, index)
			if name == nil then break end
			if name == wanted then debug.setupvalue(callback, index, value); return true end
		end
		return false
	end

	helpers.it("(ollama-migration-stream-debt) observes the original stream slot without calling its cancellation", function()
		with_api("homebrew", function(api)
			local signals = 0
			local original = { terminate = function() signals = signals + 1; return true, "pending" end }
			helpers.assert_true(set_slot(api.cancel_streaming, "_active_stream_task", original))
			helpers.assert_eq(api.migration_idle(), false)
			helpers.assert_eq(signals, 0)
			helpers.assert_true(set_slot(api.cancel_streaming, "_active_stream_task", nil))
			helpers.assert_true(api.migration_idle())
		end)
	end)

	helpers.it("(ollama-migration-warmup-debt) refuses a live warmup before every HTTP result is reported settled", function()
		with_api("homebrew", function(api)
			helpers.assert_true(set_slot(api.warmup, "_warmup_active", true))
			helpers.assert_eq(api.migration_idle(), false)
			helpers.assert_true(set_slot(api.warmup, "_warmup_active", false))
			helpers.assert_true(api.migration_idle())
		end)
	end)
end)

helpers.describe("Published native daemon custody fences migration", function()
	helpers.it("(ollama-migration-live-daemon) READY is stable startup ownership but never retired migration custody", function()
		with_api("native_managed", function(api, shell)
			helpers.assert_true(api.ensure_running())
			local original = shell.tasks[1]
			original.emit(frame("ACTIVE") .. frame("READY"))
			helpers.assert_true(api.startup_idle(), "published daemon ownership stays valid for ordinary clients")
			helpers.assert_eq(api.migration_idle(), false)
			helpers.assert_eq(original.cancel_calls, 0, "migration query has no signal authority")
			original.complete(0, frame("RETIRED 0"))
			helpers.assert_true(api.migration_idle())
		end)
	end)
end)
