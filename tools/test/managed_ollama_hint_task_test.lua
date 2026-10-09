--- tools/test/managed_ollama_hint_task_test.lua
--- Exact asynchronous owner over explicit native lifecycle and filesystem ports.
local root, production = assert(arg[1]), assert(arg[2])
package.path = production .. "/static/ergopti_plus/_shared/lua/?.lua;" .. production .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
local Json = require("json")
local directory, driver = "/private/home/Library/Application Support/Ergopti/ollama-native-http", "/private/source/macos"
local checks, cases = 0, 0
local function check(a, b) assert(a == b, "asynchronous metadata owner assertion failed"); checks = checks + 1 end
local function case(run) cases = cases + 1; run() end
local version, created, current, adapter, configuration = 1, 0
local calls = {}
local now, active_timer = 0, nil
local function result(changes)
	local value = { version = 1, candidate = directory .. "/ollama", budgets = { admission = 30, idle = 60, retirement = 600 } }
	for name, change in pairs(changes or {}) do value[name] = change end
	return Json.encode(value)
end
local function fresh(options)
	version, created, configuration = 1, 0, options or {}
	now = 0
	hs = { processInfo = { arch = "arm64" }, fs = { symlinkAttributes = function(path)
		assert(path == directory, "optional hint observes only its exact native directory")
		if configuration.directory_delay then now = now + configuration.directory_delay end
		if configuration.directory_throw then error("controlled native directory refusal") end
		if configuration.directory_missing then return nil, "native observation unavailable" end
		return { mode = configuration.directory_mode or "directory" }
	end } }
	package.loaded["modules.llm.bootstrap_retry_generated"] = { admission_seconds = 30, source_sha256 = string.rep("a", 64) }
	package.loaded["adapters.timer_scheduler"] = { awake_time = function()
			if configuration.clock_throw then error("controlled native clock refusal") end
			if configuration.clock_missing then return nil end
			return configuration.clock_value or now
		end,
		after = function(delay, fn) active_timer = { callback = fn, delay = delay }; return active_timer, true end,
		cancel = function() return configuration.timer_refuse ~= true end,
	}
	package.loaded["adapters.file_system"] = { classify_no_follow = function()
		return { mode = "file", size = 512, modification = version, permissions = "rw-r--r--" }, "ok"
	end, read_with_status = function() error("GUI synchronous metadata read forbidden") end }
	package.loaded["modules.llm.managed_native_python"] = {
		resolve = function(remaining)
			check(remaining <= 30 and remaining > 0, true)
			if configuration.preflight then return nil, "pending" end
			return "/actual/native/python"
		end,
		cancel = function() return configuration.preflight_retired == true end,
		onSettled = function(fn)
			configuration.observe_preflight = fn
			if configuration.preflight_observer_refuse then return false end
			if configuration.preflight_sync then configuration.preflight = false; fn() end
			if configuration.preflight_inconsistent then fn() end
			return true
		end,
	}
	package.loaded["adapters.task_lifecycle"] = {
		start = function(handle) return handle.start() end,
		terminate = function(handle) return handle.terminate() end,
	}
	package.loaded["adapters.shell_runner"] = { spawn = function(executable, arguments, done, chunk, env, private)
		created = created + 1
		if configuration.construct_delay then now = now + configuration.construct_delay end
		check(executable, "/actual/native/python"); check(arguments[1], "-IB")
		check(arguments[2], driver .. "/modules/llm/managed_ollama_hint.py"); check(chunk, nil); check(env, nil); check(private, true)
		if configuration.construct_throw then error("controlled constructor refusal") end
		local handle = { arguments = arguments, retired = configuration.pre_retired == true, observers = {}, start_count = 0, stops = 0 }
		handle.isSettled = function() return handle.retired end
		handle.onSettled = function(fn)
			if configuration.observer_throw then error("controlled observer failure") end
			handle.observers[#handle.observers + 1] = fn; if handle.retired then fn() end; return true
		end
		handle.start = function()
			handle.start_count = handle.start_count + 1
			if configuration.sync then done(0, result(), ""); handle.retired = true end
			return configuration.start_refuse ~= true
		end
		handle.terminate = function() handle.stops = handle.stops + 1; return false, "refused" end
		handle.finish = function(status, bytes, stderr, retired)
			handle.retired = retired == true; done(status, bytes, stderr)
			if handle.retired then for _, observe in ipairs(handle.observers) do observe() end end
		end
		current = handle; calls[#calls + 1] = handle
		return handle
	end }
	adapter = assert(loadfile(root .. "/static/ergopti_plus/macos/adapters/managed_ollama_hint.lua"))()
end
case(function()
	fresh(); local value, state = adapter.get(directory, driver)
	check(value, nil); check(state, "pending"); check(created, 1)
	for _ = 1, 3 do check(select(2, adapter.get(directory, driver)), "pending") end
	check(created, 1); check(adapter._active_tasks[current], true)
	current.finish(0, result(), "", true)
	check(adapter._active_tasks[current], nil); check(adapter.get(directory, driver).candidate, directory .. "/ollama")
	check(created, 1)
end)
case(function()
	fresh(); adapter.get(directory, driver); current.finish(0, result(), "", false)
	check(select(2, adapter.get(directory, driver)), "pending"); check(adapter._active_tasks[current], true)
	current.retired = true
	check(adapter.get(directory, driver).budgets.admission, 30); check(adapter._active_tasks[current], nil)
end)
case(function()
	fresh({ start_refuse = true }); adapter.get(directory, driver)
	check(current.stops, 1); check(adapter._active_tasks[current], true)
	current.finish(0, result(), "", true)
	check(adapter.get(directory, driver), nil); check(created, 1); check(adapter._active_tasks[current], nil)
end)
case(function()
	fresh({ sync = true }); check(adapter.get(directory, driver).candidate, directory .. "/ollama")
	check(current.start_count, 1); check(adapter._active_tasks[current], nil)
end)
case(function()
	fresh({ sync = true, start_refuse = true }); check(adapter.get(directory, driver), nil)
	check(adapter._active_tasks[current], nil)
end)
case(function()
	fresh({ pre_retired = true }); check(adapter.get(directory, driver), nil)
	check(current.start_count, 0); check(adapter._active_tasks[current], nil)
end)
case(function()
	fresh(); adapter.get(directory, driver); local old = current
	version = 2; old.finish(0, result(), "", true)
	check(select(2, adapter.get(directory, driver)), "pending"); check(created, 2)
	old.finish(0, result(), "", true)
	check(adapter._active_tasks[current], true)
end)
case(function()
	for _, malformed in ipairs({ result({ candidate = "/foreign/ollama" }), result({ extra = true }), result({ budgets = { admission = true, idle = 60, retirement = 600 } }), "[]" }) do
		fresh(); adapter.get(directory, driver); current.finish(0, malformed, "", true)
		check(adapter.get(directory, driver), nil); check(created, 1)
	end
end)
case(function()
	fresh(); adapter.get(directory, driver); local weak = setmetatable({ current }, { __mode = "v" })
	current = nil; calls = {}; collectgarbage("collect")
	check(weak[1] ~= nil, true); check(adapter._active_tasks[weak[1]], true)
	weak[1].finish(78, "", "", true); check(adapter._active_tasks[weak[1]], nil)
end)
case(function()
	fresh({ construct_throw = true }); check(adapter.get(directory, driver), nil)
	check(next(adapter._active_tasks), nil)
end)
case(function()
	fresh({ observer_throw = true }); check(select(2, adapter.get(directory, driver)), "pending")
	check(current.start_count, 0); check(current.stops, 1); check(adapter._active_tasks[current], true)
	current.retired = true; check(adapter.get(directory, driver), nil); check(adapter._active_tasks[current], nil)
end)
case(function()
	fresh({ start_refuse = true }); adapter.get(directory, driver)
	local exact = current
	exact.terminate = function() exact.stops = exact.stops + 1; exact.retired = true; return true end
	check(adapter.get(directory, driver), nil); check(exact.stops, 2)
	check(adapter._active_tasks[exact], nil)
end)
case(function()
	fresh(); adapter.get(directory, driver); now = 30
	active_timer.callback(); check(current.stops, 1); check(adapter._active_tasks[current], true)
	current.finish(0, result(), "", true)
	check(adapter.get(directory, driver), nil); check(adapter._active_tasks[current], nil)
end)
case(function()
	fresh({ timer_refuse = true }); adapter.get(directory, driver); current.finish(0, result(), "", true)
	check(adapter._active_tasks[current], true); check(select(2, adapter.get(directory, driver)), "pending")
	configuration.timer_refuse = false
	check(adapter.get(directory, driver).candidate, directory .. "/ollama"); check(adapter._active_tasks[current], nil)
end)
case(function()
	fresh({ preflight = true }); check(select(2, adapter.get(directory, driver)), "pending"); check(created, 0)
	now = 10; configuration.preflight = false
	check(select(2, adapter.get(directory, driver)), "pending"); check(created, 1); check(active_timer.delay, 30); check(current.arguments[4], "20")
	current.finish(0, result(), "", true); check(adapter.get(directory, driver).candidate, directory .. "/ollama")
end)
case(function()
	fresh({ preflight = true }); adapter.get(directory, driver); now = 30; active_timer.callback()
	check(adapter.cancel(), false); check(created, 0)
	configuration.preflight_retired = true
	check(adapter.cancel(), true); check(created, 0); check(next(adapter._active_tasks), nil)
end)
case(function()
	fresh({ construct_delay = 31 }); check(select(2, adapter.get(directory, driver)), "pending")
	check(current.start_count, 0); check(current.stops, 1); check(adapter._active_tasks[current], true)
	current.finish(74, "", "", true); check(adapter.get(directory, driver), nil)
	check(adapter._active_tasks[current], nil)
end)
case(function()
	fresh({ preflight = true }); check(select(2, adapter.get(directory, driver)), "pending"); check(created, 0)
	check(type(configuration.observe_preflight), "function")
	now = 10; configuration.preflight = false; configuration.observe_preflight()
	check(created, 1); check(current.arguments[4], "20")
	current.finish(0, result(), "", true); check(adapter.get(directory, driver).candidate, directory .. "/ollama")
end)
case(function()
	fresh({ preflight = true, preflight_sync = true }); check(select(2, adapter.get(directory, driver)), "pending")
	check(created, 1); check(current.arguments[4], "30")
	current.finish(0, result(), "", true); check(adapter.get(directory, driver).candidate, directory .. "/ollama")
end)
case(function()
	fresh({ preflight = true, preflight_observer_refuse = true }); check(select(2, adapter.get(directory, driver)), "pending")
	check(created, 0); check(adapter.cancel(), false)
	configuration.preflight_retired = true; check(adapter.cancel(), true); check(next(adapter._active_tasks), nil)
end)
case(function()
	fresh({ preflight = true, preflight_inconsistent = true })
	check(select(2, adapter.get(directory, driver)), "pending"); check(created, 0)
	check(adapter.cancel(), false); configuration.preflight_retired = true; check(adapter.cancel(), true)
end)
case(function()
	for _, options in ipairs({ { directory_missing = true }, { directory_mode = "link" },
		{ directory_mode = "file" }, { directory_throw = true } }) do
		fresh(options)
		local classified = 0
		package.loaded["adapters.file_system"].classify_no_follow = function() classified = classified + 1; error("missing optional parent must never enumerate child metadata") end
		check(adapter.get(directory, driver), nil); check(created, 0); check(next(adapter._active_tasks), nil); check(classified, 0)
	end
end)
case(function()
	fresh({ directory_delay = 31 })
	check(adapter.get(directory, driver), nil); check(created, 0); check(next(adapter._active_tasks), nil)
end)
case(function()
	fresh(); adapter.get(directory, driver); local exact = current
	configuration.directory_missing = true
	check(select(2, adapter.get(directory, driver)), "pending")
	check(exact.stops >= 1, true); check(adapter._active_tasks[exact], true); check(created, 1)
	exact.finish(0, result(), "", true)
	check(adapter.get(directory, driver), nil); check(adapter._active_tasks[exact], nil); check(created, 1)
end)
case(function()
	for _, options in ipairs({ { clock_missing = true }, { clock_throw = true }, { clock_value = false },
		{ clock_value = "invalid" }, { clock_value = -1 }, { clock_value = 0 / 0 }, { clock_value = math.huge } }) do
		fresh(options)
		if options.clock_value == false then package.loaded["adapters.timer_scheduler"].awake_time = false end
		check(adapter.get(directory, driver), nil); check(created, 0); check(next(adapter._active_tasks), nil)
	end
end)
case(function()
	fresh(); adapter.get(directory, driver); local exact = current
	configuration.clock_missing = true
	check(select(2, adapter.get(directory, driver)), "pending"); check(exact.stops, 1); check(adapter._active_tasks[exact], true)
	exact.finish(0, result(), "", true)
	check(adapter.get(directory, driver), nil); check(adapter._active_tasks[exact], nil); check(created, 1)
end)
case(function()
	fresh({ preflight = true }); check(select(2, adapter.get(directory, driver)), "pending")
	configuration.clock_throw = true
	check(select(2, adapter.get(directory, driver)), "pending"); check(next(adapter._active_tasks) ~= nil, true); check(created, 0)
	configuration.preflight_retired = true
	check(adapter.get(directory, driver), nil); check(next(adapter._active_tasks), nil); check(created, 0)
end)
case(function()
	fresh(); adapter.get(directory, driver); current.finish(0, result(), "", true)
	configuration.clock_missing = true
	check(adapter.get(directory, driver), nil); check(created, 1)
end)
case(function()
	fresh()
	local original = package.loaded["modules.llm.managed_native_python"].resolve
	package.loaded["modules.llm.managed_native_python"].resolve = function(budget)
		local python = original(budget)
		configuration.clock_missing = true
		return python
	end
	check(adapter.get(directory, driver), nil); check(created, 0); check(next(adapter._active_tasks), nil)
	fresh()
	local spawn = package.loaded["adapters.shell_runner"].spawn
	package.loaded["adapters.shell_runner"].spawn = function(...)
		local handle = spawn(...)
		configuration.clock_throw = true
		return handle
	end
	check(select(2, adapter.get(directory, driver)), "pending")
	check(current.start_count, 0); check(current.stops, 1); check(adapter._active_tasks[current], true)
	current.finish(0, result(), "", true)
	check(adapter.get(directory, driver), nil); check(next(adapter._active_tasks), nil); check(created, 1)
end)
print(string.format("PASS %d cases / %d assertions", cases, checks))
