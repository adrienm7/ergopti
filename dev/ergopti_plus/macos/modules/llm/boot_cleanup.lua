--- modules/llm/boot_cleanup.lua

--- ==============================================================================
--- MODULE: MLX Boot Cleanup
--- DESCRIPTION:
--- Selective, asynchronous cleanup of leftover mlx_lm.server processes at boot.
--- Hammerspoon does not always reap children on quit/reload, so a fresh boot can
--- find servers from a previous session still bound to the MLX port.
---
--- FEATURES & RATIONALE:
--- 1. Spare-all-or-nuke-all: a SINGLE healthy survivor (one LISTEN socket + a
---    valid /v1/models id) is spared so start_server can adopt it (weights stay
---    GPU-resident, no 45-90 s cold restart). SEVERAL listeners on the same port
---    load-balance via SO_REUSEPORT and break endpoint discovery — those are nuked.
--- 2. Asynchronous but ordered: ShellRunner keeps curl and sleep off the main run
---    loop, while the terminal callback gates the first backend bootstrap probe.
--- ==============================================================================

local M = {}

local Logger      = require("infra.logger")
local ShellRunner = require("adapters.shell_runner")
local LOG         = "llm.boot_cleanup"





-- =========================================
-- =========================================
-- ======= 1/ Selective Boot Cleanup =======
-- =========================================
-- =========================================

--- Runs the selective port cleanup once. Resolves the MLX port from api_mlx,
--- spares a single healthy server, nukes leftovers, and publishes settlement.
--- @param on_done function Completion callback: fn(success).
--- @return boolean True only when the asynchronous task start commits.
function M.run_selective_cleanup(on_done)
	assert(type(on_done) == "function", "on_done must be a function")
	local ok_mlx, ApiMlx = pcall(require, "modules.llm.api_mlx")
	-- The MLX port is owned by api_mlx (_shared/modules/llm/mlx_server.json = 3460). Prefer
	-- the resolved port, then api_mlx's exposed canonical default; the trailing
	-- literal is only ever reached if api_mlx itself failed to load, and it is the
	-- canonical 3460 — NEVER mlx_lm.server's 8080 default, which is explicitly
	-- forbidden (commonly taken by other local servers; see mlx_server.json).
	local P = tostring((ok_mlx and type(ApiMlx.get_port) == "function" and ApiMlx.get_port())
		or (ok_mlx and ApiMlx.DEFAULT_PORT) or 3460)
	local kill_cmd =
		-- Count distinct LISTEN sockets on the MLX port. -sTCP:LISTEN enumerates
		-- each SO_REUSEPORT socket separately, so this is the reliable "how many
		-- servers are bound" signal (a bare lsof would also count transient
		-- ESTABLISHED connections and the probe below).
		"LISTEN_PIDS=$(lsof -nP -iTCP:" .. P .. " -sTCP:LISTEN -t 2>/dev/null | sort -u); " ..
		"NLISTEN=$(printf '%s\\n' \"$LISTEN_PIDS\" | grep -c . || true); " ..
		-- Probe /v1/models on a fresh connection (no keep-alive to a dead socket)
		-- and extract the served model id.
		"MODEL_ID=$(curl -s --max-time 1 --no-keepalive -H 'Connection: close' http://127.0.0.1:" .. P .. "/v1/models 2>/dev/null | sed -n 's/.*\"id\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p' | head -1); " ..
		"if [ \"$NLISTEN\" = \"1\" ] && [ -n \"$MODEL_ID\" ]; then " ..
		"  echo \"[BOOT] single healthy MLX server on :" .. P .. " (pid $LISTEN_PIDS) serving '$MODEL_ID' — sparing it so start_server can adopt it (no cold restart).\"; " ..
		"else " ..
		-- Match the executable identity before inspecting argv. A pgrep -f pattern
		-- also sees this entire /bin/sh -c script and can therefore select the shell
		-- that is running the cleanup, killing it before the diagnostics below.
		"  PIDS=$(ps -axo pid=,comm=,args= 2>/dev/null | awk '$2 ~ /^[Pp]ython/ && /mlx_lm/ {print $1}'); " ..
		"  if [ -n \"$PIDS\" ]; then echo \"[BOOT] no single healthy server on :" .. P .. " (listeners=$NLISTEN, model_id='$MODEL_ID') — terminating leftover MLX Python process(es): $PIDS\"; echo \"$PIDS\" | xargs kill -9 2>/dev/null; sleep 0.3; else echo \"[BOOT] no MLX Python processes and no server on :" .. P .. " — clean slate.\"; fi; " ..
		"fi; " ..
		"echo \"[BOOT-DIAG] port " .. P .. " state:\"; lsof -nP -iTCP:" .. P .. " 2>/dev/null || echo \"  (port " .. P .. " is FREE)\""
	local settled = false
	local function settle(success)
		if settled then
			Logger.warn(LOG, "Ignoring duplicate MLX boot cleanup terminal.")
			return
		end
		settled = true
		Logger.callback(LOG, "MLX boot cleanup completion", on_done, success == true)
	end

	local spawn_ok, handle = xpcall(function()
		return ShellRunner.spawn("/bin/sh", { "-c", kill_cmd }, function(exit_code, stdout, stderr)
			local success = exit_code == 0
			local output = (stdout or ""):gsub("\n", " | ")
			if success then
				Logger.info(LOG, "[BOOT-NUKE] mlx_lm selective cleanup completed: %s", output)
			else
				Logger.error(LOG, "[BOOT-NUKE] mlx_lm selective cleanup failed (exit=%s): %s | %s",
					tostring(exit_code), output, (stderr or ""):gsub("\n", " | "))
			end
			settle(success)
		end)
	end, debug.traceback)
	if not spawn_ok or type(handle) ~= "table" or type(handle.start) ~= "function" then
		Logger.error(LOG, "Could not construct the asynchronous MLX boot cleanup: %s",
			tostring(handle))
		settle(false)
		return false
	end

	local start_ok, started = xpcall(handle.start, debug.traceback)
	if not start_ok or started ~= true then
		Logger.error(LOG, "Could not start the asynchronous MLX boot cleanup: %s",
			tostring(started))
		settle(false)
		return false
	end
	return true
end

return M
