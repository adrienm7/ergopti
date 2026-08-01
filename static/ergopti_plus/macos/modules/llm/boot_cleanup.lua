--- modules/llm/boot_cleanup.lua

--- ==============================================================================
--- MODULE: MLX Boot Cleanup
--- DESCRIPTION:
--- Selective, synchronous cleanup of leftover mlx_lm.server processes at boot.
--- Hammerspoon does not always reap children on quit/reload, so a fresh boot can
--- find servers from a previous session still bound to the MLX port.
---
--- FEATURES & RATIONALE:
--- 1. Spare-all-or-nuke-all: a SINGLE healthy survivor (one LISTEN socket + a
---    valid /v1/models id) is spared so start_server can adopt it (weights stay
---    GPU-resident, no 45-90 s cold restart). SEVERAL listeners on the same port
---    load-balance via SO_REUSEPORT and break endpoint discovery — those are nuked.
--- 2. Synchronous on purpose: the port state must settle before the warmup retry
---    loop fires its first probe. Extracted from init.lua so the boot orchestrator
---    stays readable; the call site still gates it on the early LLM-enabled check.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")
local LOG    = "llm.boot_cleanup"





-- =========================================
-- =========================================
-- ======= 1/ Selective Boot Cleanup =======
-- =========================================
-- =========================================

--- Runs the selective port cleanup once. Resolves the MLX port from api_mlx,
--- spares a single healthy server, nukes leftovers, and logs the outcome.
function M.run_selective_cleanup()
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
		"  PIDS=$(pgrep -f 'mlx_lm' 2>/dev/null); " ..
		"  if [ -n \"$PIDS\" ]; then echo \"[BOOT] no single healthy server on :" .. P .. " (listeners=$NLISTEN, model_id='$MODEL_ID') — nuking leftover mlx_lm: $PIDS\"; echo \"$PIDS\" | xargs kill -9 2>/dev/null; sleep 0.3; else echo \"[BOOT] no mlx_lm processes and no server on :" .. P .. " — clean slate.\"; fi; " ..
		"fi; " ..
		"echo \"[BOOT-DIAG] port " .. P .. " state:\"; lsof -nP -iTCP:" .. P .. " 2>/dev/null || echo \"  (port " .. P .. " is FREE)\""
	local out, ok = hs.execute(kill_cmd, true)
	Logger.info(LOG, "[BOOT-NUKE] mlx_lm selective cleanup ok=%s output=%s",
		tostring(ok), (out or ""):gsub("\n", " | "))
end

return M
