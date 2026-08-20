--- tests/unit/adapters/test_shell_runner_on_chunk_visible.lua

--- ==============================================================================
--- MODULE: Regression — ShellRunner on_chunk throws are visible (F-HIGH-21)
--- DESCRIPTION:
--- wrapped_on_done wraps on_done in xpcall + Logger.error + crash-report
--- forwarding, but the parallel streaming callback on_chunk was passed
--- raw/unwrapped into hs.task.new. A throw inside SSE-chunk handling (e.g. the
--- streaming JSON-line parsers in modules/llm/api_ollama.lua and
--- modules/llm/api_mlx_inference.lua) was swallowed to the HS Console only —
--- reintroducing the "vert mais aucune prédiction" silent-failure class
--- specifically for the streaming path (also covers F-LOW-2, same gap).
---
--- Fix: on_chunk is now wrapped the same way wrapped_on_done wraps on_done —
--- xpcall + Logger.error + deferred crash-report forwarding — while still
--- honouring hs.task's streaming-callback contract (return true to keep
--- streaming, false to stop); a caught throw defaults to true so one bad
--- chunk does not also kill the rest of the stream.
---
--- Mirrors test_shell_runner_on_done_visible.lua's structure:
---   1. Source check: on_chunk is wrapped in xpcall, not passed raw.
---   2. Behaviour: driving on_chunk via a stub hs.task confirms the ERROR is
---      logged and the stream is NOT killed by the caught throw.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_shell_runner_src()
	-- Selected by a declaration unique to adapters/shell_runner.lua rather than by
	-- path, so moving or splitting the module cannot turn this invariant
	-- into a path error.
	local src = helpers.read_driver_source("local function invoke_guarded")
	helpers.assert_true(src ~= nil, "adapters/shell_runner.lua source must be locatable")
	return src
end




-- ======================================================================
-- =====================================================================
-- ======= 1/ Source invariant: on_chunk is wrapped, not passed raw ===
-- =====================================================================
-- ======================================================================

helpers.describe("ShellRunner: on_chunk throws are visible (F-HIGH-21 source)", function()

	helpers.it("spawn() does NOT pass the raw on_chunk directly into hs.task.new", function()
		local src = read_shell_runner_src()
		-- The old unwrapped pattern: hs.task.new(executable, wrapped_on_done, on_chunk, args)
		local bad_pos = src:find("wrapped_on_done, on_chunk,", 1, true)
		helpers.assert_true(bad_pos == nil,
			"spawn() must NOT pass raw on_chunk into hs.task.new — wrap it the same way on_done is wrapped")
	end)

	helpers.it("a wrapped_on_chunk function exists and is used as the streaming callback", function()
		local src = read_shell_runner_src()
		helpers.assert_true(src:find("wrapped_on_chunk", 1, true) ~= nil,
			"shell_runner.lua must define wrapped_on_chunk")
		helpers.assert_true(src:find("wrapped_on_done, wrapped_on_chunk, args", 1, true) ~= nil,
			"hs.task.new must be called with wrapped_on_chunk, not the raw on_chunk")
	end)

	helpers.it("wrapped_on_chunk uses xpcall so a throw is surfaced (not swallowed)", function()
		local src = read_shell_runner_src()
		local fn_start = src:find("local function wrapped_on_chunk", 1, true)
		helpers.assert_true(fn_start ~= nil, "wrapped_on_chunk must be defined")
		local fn_body = src:sub(fn_start, src:find("\n\t--", fn_start + 1) or #src)
		helpers.assert_true(fn_body:find("xpcall", 1, true) ~= nil,
			"wrapped_on_chunk must use xpcall so a throw inside on_chunk is surfaced")
	end)

	helpers.it("wrapped_on_chunk logs an ERROR when the callback throws", function()
		local src = read_shell_runner_src()
		local fn_start   = src:find("local function wrapped_on_chunk", 1, true)
		helpers.assert_true(fn_start ~= nil, "wrapped_on_chunk must be defined")
		local log_pos = src:find("report_callback_throw", fn_start, true)
		helpers.assert_true(log_pos ~= nil and log_pos > fn_start,
			"wrapped_on_chunk must report the throw (Logger.error + crash forwarding) on failure")
	end)
end)




-- ============================================================================
-- ===========================================================================
-- ======= 2/ Behaviour: ERROR is captured when on_chunk throws (F-HIGH-21) =
-- ===========================================================================
-- ============================================================================

helpers.describe("ShellRunner: ERROR logged when on_chunk throws (F-HIGH-21 behaviour)", function()

	helpers.it("captures Logger.error when on_chunk throws 'boom' and keeps streaming", function()
		-- Capture log output via Logger.set_sink — the real contract (infra/logger.lua
		-- M.set_sink) invokes _test_sink(console_line, sink_variant) with the variant
		-- as a lowercase string (see test_shell_runner_on_done_visible.lua).
		local errors_logged = {}
		local logger = helpers.load_with_stubs("infra.logger")
		if type(logger.set_sink) == "function" then
			logger.set_sink(function(console_line, sink_variant)
				if sink_variant == "error" then errors_logged[#errors_logged + 1] = console_line end
			end)
		end

		-- Stub hs.task with the 4-arg streaming form: new(executable, on_done_cb, on_chunk_cb, args).
		-- start() invokes the chunk callback once (simulating one SSE chunk arriving),
		-- capturing its return value so the test can assert the stream was not killed.
		local captured_chunk_cb = nil
		local chunk_return_value = nil
		local hs_overrides = {
			task = {
				new = function(_executable, _on_done_cb, on_chunk_cb, _args)
					captured_chunk_cb = on_chunk_cb
					return {
						start = function()
							if captured_chunk_cb then
								chunk_return_value = captured_chunk_cb(nil, "some chunk", "")
							end
						end,
						isRunning = function() return false end,
						terminate = function() end,
					}
				end,
			},
		}

		-- Reload shell_runner under the stub hs
		package.loaded["adapters.shell_runner"] = nil
		local sr = helpers.load_with_stubs("adapters.shell_runner", hs_overrides)
		local hs_stub = _G.hs

		local crash_called = false
		_G.ergopti_report_crash = function() crash_called = true end

		-- Spawn with an on_chunk that throws
		local handle = sr.spawn("/usr/bin/curl", {}, function() end, function()
			error("boom from on_chunk")
		end)
		handle.start()

		-- The crash-report forwarding call is deferred via hs.timer.doAfter(0, ...),
		-- mirroring wrapped_on_done — fire every pending stub timer to exercise it.
		if hs_stub and hs_stub.timer and hs_stub.timer.__fire_all then
			hs_stub.timer.__fire_all()
		end

		-- At least one ERROR mentioning the throw must have been logged
		-- (If Logger.set_sink is not available we fall back to the source check above)
		if type(logger.set_sink) == "function" then
			local found_error = false
			for _, msg in ipairs(errors_logged) do
				if msg:find("boom", 1, true) or msg:find("on_chunk", 1, true) then
					found_error = true; break
				end
			end
			helpers.assert_true(found_error or crash_called,
				"an ERROR mentioning the throw must be logged (or crash reporter called) when on_chunk throws")
		end

		-- A caught throw inside on_chunk must default to "keep streaming" (true) —
		-- a single bad chunk must not also silently kill the rest of the stream.
		helpers.assert_eq(chunk_return_value, true,
			"wrapped_on_chunk must return true (continue streaming) after catching a throw")

		_G.ergopti_report_crash = nil
	end)

	helpers.it("passes through on_chunk's real return value when it does not throw", function()
		local captured_chunk_cb = nil
		local hs_overrides = {
			task = {
				new = function(_executable, _on_done_cb, on_chunk_cb, _args)
					captured_chunk_cb = on_chunk_cb
					return {
						start     = function() end,
						isRunning = function() return false end,
						terminate = function() end,
					}
				end,
			},
		}

		package.loaded["adapters.shell_runner"] = nil
		local sr = helpers.load_with_stubs("adapters.shell_runner", hs_overrides)

		local handle = sr.spawn("/usr/bin/curl", {}, function() end, function(_task, chunk, _stderr)
			-- Mirrors api_ollama.lua's on_chunk: stop streaming on an empty chunk
			return chunk ~= ""
		end)
		handle.start()

		helpers.assert_true(captured_chunk_cb ~= nil, "on_chunk must be captured via hs.task.new's 3rd argument")
		helpers.assert_eq(captured_chunk_cb(nil, "data", ""), true,
			"wrapped_on_chunk must forward a truthy return from the real on_chunk")
		helpers.assert_eq(captured_chunk_cb(nil, "", ""), false,
			"wrapped_on_chunk must forward a falsy return from the real on_chunk")
	end)
end)
