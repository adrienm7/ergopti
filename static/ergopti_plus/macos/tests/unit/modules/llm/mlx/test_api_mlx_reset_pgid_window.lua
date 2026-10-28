--- tests/unit/modules/llm/mlx/test_api_mlx_reset_pgid_window.lua

--- ==============================================================================
--- MODULE: api_mlx — PGID window opens only for a cold launch
--- DESCRIPTION:
--- Every field-run MLX stop (2026-10-27 22:36, 22:59, 23:37) logged "Endpoint
--- discovery state reset." at WARNING, then "PGID pending timeout (15s) —
--- unblocking zombie kills." 15 s later, and every launch logged "Killing zombie
--- mlx_lm Python process(es)" and "Zombie kill completed; stdout: none" at
--- WARNING although nothing was killed.
---
--- ROOT CAUSE ENCODED:
--- 1. reset_endpoints always opened the "PGID pending" window, which only a
---    cold launch's bash wrapper closes by printing its PGID. The stop
---    settlement and the adoption of a previous session's server reset too, no
---    launch followed, and the safety timeout was the only way out.
--- 2. The precautionary sweep after each PGID report, and a sweep that found
---    nothing, were logged as warnings: only a killed process is news.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED = {
	"infra.logger", "infra.notifications", "infra.i18n", "infra.config_paths",
	"infra.text_utils", "infra.timings", "infra.paths", "adapters.storage",
	"adapters.http_client", "adapters.json_codec", "adapters.shell_runner",
	"adapters.timer_scheduler", "modules.llm.profiles",
	"modules.llm.api_common", "modules.llm.api_mlx_inference", "modules.llm.api_mlx_fetch",
	"modules.llm.api_mlx_discovery", "modules.llm.mlx_stream_retirement",
	"modules.llm.api_mlx",
}





-- ===================================
-- ===================================
-- ======= 1/ Isolated Fixture =======
-- ===================================
-- ===================================

--- Runs one scenario against a fresh api_mlx with recorded timers, sweeps and logs.
--- @param scenario function Receives (api, runtime).
local function with_api(scenario)
	helpers.with_fresh_modules(OWNED, function()
		local noop = function() end
		local runtime = { lines = {}, timers = {}, sweeps = {} }
		local function capture(level)
			return function(_, message, ...)
				local text = select("#", ...) > 0 and string.format(message, ...) or tostring(message)
				runtime.lines[#runtime.lines + 1] = { level = level, text = text }
			end
		end
		package.loaded["infra.logger"] = setmetatable({
			debug = capture("debug"), info = capture("info"), warn = capture("warn"),
			error = capture("error"),
			callback = function(_, _, fn, ...) return pcall(fn, ...) end,
		}, { __index = function() return noop end })
		package.loaded["infra.notifications"] = { notify = noop }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.config_paths"] = { get = function() return "/fixture/model.txt" end }
		package.loaded["infra.text_utils"] = { shell_quote = function(value) return value end }
		package.loaded["infra.timings"] = { sec = function() return 1 end }
		package.loaded["infra.paths"] = { shared = function() return nil end }
		package.loaded["adapters.storage"] = { get = function() return nil end }
		package.loaded["adapters.http_client"] = {
			new = function() return { cancel = function() return true end } end,
		}
		package.loaded["adapters.json_codec"] = { decode = function() return nil end }
		package.loaded["adapters.shell_runner"] = {
			spawn = function(_, args, callback)
				local sweep = { script = args[2], callback = callback }
				runtime.sweeps[#runtime.sweeps + 1] = sweep
				return { start = function() return true end }
			end,
		}
		package.loaded["adapters.timer_scheduler"] = {
			awake_time = function() return 100 end,
			after = function(delay, callback)
				local handle = { timer = {}, delay = delay, callback = callback }
				runtime.timers[#runtime.timers + 1] = handle
				return handle, true
			end,
			cancel = function(handle)
				handle.timer = nil
				handle.cancelled = true
				return true
			end,
		}
		package.loaded["modules.llm.profiles"] = {}
		package.loaded["modules.llm.api_common"] = {
			protected_call = function(fn, _, ...) return pcall(fn, ...) end,
		}
		package.loaded["modules.llm.mlx_stream_retirement"] = {}
		package.loaded["modules.llm.api_mlx_inference"] = { init = noop }
		package.loaded["modules.llm.api_mlx_fetch"] = { init = noop }
		package.loaded["modules.llm.api_mlx_discovery"] = {
			init = noop,
			reset = function() return true end,
			resume = function() return true end,
		}
		scenario(require("modules.llm.api_mlx"), runtime)
	end)
end

--- Counts captured lines at `level` whose text contains `needle`.
--- @param runtime table
--- @param level string
--- @param needle string
--- @return number
local function count(runtime, level, needle)
	local total = 0
	for _, line in ipairs(runtime.lines) do
		if line.level == level and line.text:find(needle, 1, true) then total = total + 1 end
	end
	return total
end

--- Returns the timers that are still armed.
--- @param runtime table
--- @return table armed
local function armed(runtime)
	local list = {}
	for _, handle in ipairs(runtime.timers) do
		if handle.timer ~= nil then list[#list + 1] = handle end
	end
	return list
end





-- ==================================
-- ==================================
-- ======= 2/ The PGID Window =======
-- ==================================
-- ==================================

helpers.describe("api_mlx reset opens the PGID window only for a cold launch (mlx-stop-no-pgid-wait)", function()
	helpers.it("a stop reset arms no PGID timeout and warns nothing", function()
		with_api(function(api, runtime)
			helpers.assert_eq(api.reset_endpoints(), true, "a stop reset must settle")
			helpers.assert_eq(#armed(runtime), 0,
				"no launch follows a stop, so no PGID timeout may be armed")
			helpers.assert_eq(count(runtime, "warn", ""), 0, "an ordinary stop must not warn")
			helpers.assert_eq(count(runtime, "info", "Endpoint discovery state reset"), 1,
				"the reset itself is still recorded once at INFO")
		end)
	end)

	helpers.it("a cold launch arms the timeout and its PGID report disarms it", function()
		with_api(function(api, runtime)
			helpers.assert_eq(api.reset_endpoints({ awaiting_pgid = true }), true)
			local pending = armed(runtime)
			helpers.assert_eq(#pending, 1, "a cold launch must arm the 15 s PGID safety timeout")
			helpers.assert_eq(pending[1].delay, 15, "the canonical timeout is 15 s")
			api.set_active_server_pgid(4242)
			helpers.assert_eq(#armed(runtime), 0, "the PGID report must disarm the timeout")
			helpers.assert_eq(count(runtime, "warn", ""), 0, "a healthy launch must not warn")
		end)
	end)

	helpers.it("a launch that never reports its PGID still warns once the timeout fires", function()
		with_api(function(api, runtime)
			helpers.assert_eq(api.reset_endpoints({ awaiting_pgid = true }), true)
			local pending = armed(runtime)[1]
			pending.timer = nil
			pending.callback()
			helpers.assert_eq(count(runtime, "warn", "PGID pending timeout"), 1,
				"a launch that crashed before its PGID line is a real anomaly")
		end)
	end)

	helpers.it("rejects options that are not a table", function()
		with_api(function(api)
			local ok = pcall(api.reset_endpoints, true)
			helpers.assert_eq(ok, false, "a malformed option must fail fast")
		end)
	end)
end)





-- ======================================
-- ======================================
-- ======= 3/ Zombie Sweep Levels =======
-- ======================================
-- ======================================

helpers.describe("api_mlx zombie sweep warns only when it kills", function()
	helpers.it("the precautionary sweep and an empty result stay below WARNING", function()
		with_api(function(api, runtime)
			helpers.assert_eq(api.reset_endpoints({ awaiting_pgid = true }), true)
			runtime.lines = {}
			api.set_active_server_pgid(4242)
			helpers.assert_eq(#runtime.sweeps, 1, "fixture: the PGID report runs one guarded sweep")
			runtime.sweeps[1].callback(0, "none\n", "")
			helpers.assert_eq(count(runtime, "warn", ""), 0,
				"a sweep that found no stray process must not warn")
		end)
	end)

	helpers.it("a sweep that kills a stray process warns with its PIDs", function()
		with_api(function(api, runtime)
			helpers.assert_eq(api.reset_endpoints({ awaiting_pgid = true }), true)
			api.set_active_server_pgid(4242)
			runtime.sweeps[1].callback(0, "killed: 917\n", "")
			helpers.assert_eq(count(runtime, "warn", "killed: 917"), 1,
				"a killed stray process is the news and must warn")
		end)
	end)
end)
