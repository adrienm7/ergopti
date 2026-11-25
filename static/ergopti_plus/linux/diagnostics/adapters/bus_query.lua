--- diagnostics/adapters/bus_query.lua

--- ==============================================================================
--- MODULE: Session Bus Query (Linux field checks)
--- DESCRIPTION:
--- One session-bus request of a field check, run as `busctl --user
--- --json=short -- …` through the daemon's asynchronous runner and decoded from
--- busctl's JSON. The tray and session checks read the daemon's own exported
--- menu and the notification server this way.
---
--- FEATURES & RATIONALE:
--- 1. A child process, never a call from this process: the tray menu is served
---    by this daemon's GTK loop, so a synchronous call from it would wait on
---    the loop that has to answer (tests/hardware/run_tray_icon.lua says why).
--- 2. busctl prints typed JSON (`{"type":"…","data":…}`), which the shared JSON
---    codec reads; gdbus prints GVariant text, which no module here parses.
--- 3. Every request is bounded and answers once: the decoded reply (`{ data =
---    {} }` for a method that returns nothing), or nil and
---    "not_found" (no busctl), "exit" (the bus refused), "timeout", "bad_reply"
---    or "error".
--- ==============================================================================

local M = {}

-- A menu with every branch filled is a few hundred kilobytes of JSON
-- (constants.toml [limits]).
M.MAX_OUTPUT_BYTES = require("core.timing.engine.timings").count("limits", "field_check_output_bytes")

--- Builds the request function.
--- @param timeout_ms number The bound of one request.
--- @return function request(args, done) -> handle|nil, why
function M.new(timeout_ms)
	assert(type(timeout_ms) == "number" and timeout_ms > 0, "a bus query needs its bound")
	local Shell = require("core.process.adapters.shell_runner")
	local Json = require("core.text.engine.json")
	return function(args, done)
		if not Shell.has_command("busctl", true) then return nil, "not_found" end
		-- « -- » ends the options: GetLayout's recursion depth is the argument -1.
		local argv = { "--user", "--json=short", "--" }
		for _, value in ipairs(args) do argv[#argv + 1] = value end
		return Shell.run_async("busctl", argv, { timeout_ms = timeout_ms, max_output_bytes = M.MAX_OUTPUT_BYTES },
			function(result)
				if result.timed_out then return done(nil, "timeout") end
				if type(result.code) ~= "number" then return done(nil, "error") end
				if result.code ~= 0 then return done(nil, "exit") end
				-- A method with no reply value (Event) prints nothing.
				if not tostring(result.stdout or ""):find("%S") then return done({ data = {} }) end
				local ok, decoded = pcall(Json.decode, result.stdout)
				if not ok or type(decoded) ~= "table" then return done(nil, "bad_reply") end
				done(decoded)
			end)
	end
end

return M
