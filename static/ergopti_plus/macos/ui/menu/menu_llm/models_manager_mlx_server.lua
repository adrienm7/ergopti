--- ui/menu/menu_llm/models_manager_mlx_server.lua

--- =============================================================================
--- MODULE: MLX Models Manager — Server Lifecycle
--- DESCRIPTION:
--- Attaches the MLX server-launch lifecycle (obj.start_server) onto the shared
--- MLX models-manager object. Owns everything between "user picked a model" and
--- "a healthy mlx_lm.server is answering on the configured port": cross-session
--- adoption, the detached bash launcher's serialized cleanup, readiness probing,
--- and crash auto-recovery.
---
--- FEATURES & RATIONALE:
--- 1. Shared-context mixin: install(ctx) attaches start_server onto ctx.obj, so the
---    factory's other methods (check_requirements, pull_model) keep calling
---    obj.start_server unchanged while this 570-line lifecycle lives on its own.
--- 2. Single canonical GC root: hs.task handles are pinned in ctx.active_tasks_gc_root
---    (the parent manager's M._active_tasks) so the same table roots every spawned
---    task and the GC cannot SIGTERM a readiness probe mid-run.
--- 3. Port-late binding: MLX_PORT is re-resolved from api_mlx at launch time, not
---    module load, so a menu-driven port change is honoured by every command string.
--- =============================================================================

local M = {}

local hs            = hs
local notifications = require("infra.notifications")
local Logger        = require("infra.logger")
local i18n          = require("infra.i18n")
local ApiCommon     = require("modules.llm.api_common")
local TaskLifecycle = require("adapters.task_lifecycle")

-- Required to inform the discovery poller of the active server PID so it can
-- exclude it from zombie kills; safe to require here because api_mlx holds no
-- circular dependency on this file. A plain require (not pcall) because api_mlx is
-- the MLX backend's core module — if it cannot load, MLX predictions are dead
-- anyway, so failing fast is correct (and lets the port come straight from it).
local ApiMlx = require("modules.llm.api_mlx")

-- Same LOG tag as the parent manager so server-lifecycle log lines stay grouped
-- under "menu_llm.mlx" exactly as before the split.
local LOG = "menu_llm.mlx"





-- ===================================
-- ===================================
-- ======= 1/ Server Lifecycle =======
-- ===================================
-- ===================================

--- Attaches obj.start_server onto the manager object.
--- @param ctx table Shared context: {
---   obj = manager object, deps = injected deps,
---   project_venv_python_escaped = pinned interpreter path (shell-escaped),
---   active_tasks_gc_root = the parent manager's M._active_tasks GC-root table }.
function M.install(ctx)
	local obj                         = ctx.obj
	local deps                        = ctx.deps
	local project_venv_python_escaped = ctx.project_venv_python_escaped
	-- Single canonical GC root, shared with the parent manager: probe tasks
	-- are pinned here so the collector cannot SIGTERM them before their callbacks fire.
	local _active_tasks = ctx.active_tasks_gc_root or {}

	-- Single source of truth for the MLX server port: api_mlx, backed by the per-user
	-- override and _shared/modules/llm/mlx_server.json. Re-resolved at launch time in
	-- start_server in case the user changed it via the menu (M.set_port).
	local MLX_PORT = ApiMlx.get_port()

	local function take_server_waiters()
		local waiters = obj._server_waiters or {}
		obj._server_waiters = {}
		return waiters
	end

	local function cancel_server_waiters()
		for _, waiter in ipairs(take_server_waiters()) do
			local callback = type(waiter) == "table" and waiter.on_cancel or nil
			ApiCommon.protected_call(callback, "MLX server waiter on_cancel")
		end
	end

	--- Runs a native Hammerspoon async callback behind a logged boundary.
	--- Errors escaping an hs.task/hs.timer callback otherwise go only to the
	--- Hammerspoon console, leaving the file log and the caller's lock silent.
	--- @param name string Callback name used in the diagnostic.
	--- @param callback function Callback body.
	--- @return boolean ok
	--- @return any result
	local function run_async_callback(name, callback)
		local ok, result = xpcall(callback, debug.traceback)
		if not ok then
			Logger.error(LOG, "Async callback '%s' raised: %s.", tostring(name), tostring(result))
			return false, nil
		end
		return true, result
	end

	function obj.start_server(target_model, on_success, on_cancel, opts)
		local is_current = type(opts) == "table" and opts.is_current or function() return true end
		local terminal_sent = false
		local function settle(callback, label, ...)
			if terminal_sent then return false end
			terminal_sent = true
			if type(callback) ~= "function" then return true end
			local ok, result = ApiCommon.protected_call(callback, label, ...)
			return ok and result ~= false
		end
		local function settle_cancel(...)
			return settle(on_cancel, "MLX server on_cancel", ...)
		end
		local function still_current()
			local ok, current = ApiCommon.protected_call(
				is_current, "MLX server freshness check")
			return ok == true and current == true
		end
		local function current_or_cancel()
			if still_current() then return true end
			settle_cancel("stale")
			return false
		end
		local function settle_success(...)
			if not current_or_cancel() then return false end
			return settle(on_success, "MLX server on_success", ...)
		end
		if not current_or_cancel() then return false end
		local repo = obj.get_mlx_repo(target_model)
		if not repo then
			Logger.warn(LOG, "Cannot start MLX server: no repository found for model %s.", tostring(target_model))
			-- Fire on_cancel so the caller's prediction lock is released; otherwise
			-- predictions stay silently disabled for the rest of the session
			settle_cancel("repository_unavailable")
			return false
		end
		Logger.info(LOG, "Ensuring MLX server for model %s…", tostring(target_model))
		local silent_notifications = type(opts) == "table" and opts.silent_notifications == true

		-- Re-resolve the port from api_mlx at launch time, not module load time: the
		-- user may have changed it via the menu (M.set_port) since this module loaded.
		-- Every command string below (launcher and adoption probe) reads MLX_PORT,
		-- so refreshing this upvalue makes them all target the current port.
		if ApiMlx and type(ApiMlx.get_port) == "function" then
			MLX_PORT = ApiMlx.get_port()
		end

		local function probe_matches_target(body)
			if type(body) ~= "string" or body == "" then return false end
			local ok, parsed = pcall(hs.json.decode, body)
			if not ok or type(parsed) ~= "table" then return false end

			local target_l = (target_model or ""):lower()
			local repo_l = (repo or ""):lower()

			local models = parsed.data
			if type(models) ~= "table" then return false end
			for _, item in ipairs(models) do
				if type(item) == "table" and type(item.id) == "string" then
					local id_l = item.id:lower()
					if id_l:find(target_l, 1, true) or id_l:find(repo_l, 1, true) then
						return true
					end
				end
			end
			return false
		end

		if deps.active_tasks and deps.active_tasks["mlx_server"] then
			local existing = deps.active_tasks["mlx_server"]
			local running = type(existing.isRunning) == "function" and existing:isRunning()
			Logger.debug(LOG, "Existing MLX task found — running=%s, server_target='%s', target_model='%s'.",
				tostring(running), tostring(obj._server_target), tostring(target_model))
			if running and obj._server_target == target_model then
				-- isRunning() means the PROCESS is alive, not that the model is loaded.
				-- Resolving on it fired the second caller's on_success while the first
				-- caller's readiness probe was still running, so a duplicate request was
				-- told the server was ready 60-90 s before it was.
				if obj._server_ready then
					Logger.info(LOG, "MLX server already ready for '%s' — reusing.",
						tostring(target_model))
					settle_success()
				elseif on_success or on_cancel then
					-- Join the startup already in flight. The waiter is drained by
					-- mark_server_ready below, so nobody is told "ready" early and nobody
					-- has their callback dropped either.
					obj._server_waiters = obj._server_waiters or {}
					table.insert(obj._server_waiters, {
						on_success = settle_success,
						on_cancel = settle_cancel,
						is_current = still_current,
					})
					Logger.info(LOG, "MLX server for '%s' still starting — joined as waiter #%d.",
						tostring(target_model), #obj._server_waiters)
				end
				return true
			end
			if running then
				if not current_or_cancel() then return false end
				Logger.info(LOG, "MLX server running for different model — terminating.")
				cancel_server_waiters()
				local ok_terminate, terminated = xpcall(function()
					return existing:terminate()
				end, debug.traceback)
				if not ok_terminate or terminated ~= true then
					Logger.error(LOG, "MLX server replacement refused: predecessor termination did not commit (%s).",
						tostring(ok_terminate and terminated or terminated))
					settle_cancel("replacement_termination_refused")
					return false
				end
			end
			if deps.active_tasks["mlx_server"] == existing then
				deps.active_tasks["mlx_server"] = nil
			end
			if obj._server_owner == existing then obj._server_owner = nil end
		end
		if not current_or_cancel() then return false end

		-- Cross-session adoption — after a Hammerspoon reload the in-memory hs.task
		-- handle checked above is gone, but the detached Python server launched in
		-- the previous session is still listening on 8080 with the model already
		-- mapped into GPU memory. Replacing it and cold-reloading costs
		-- 45-90 s on every reload — the "rond rouge / jaune trop longtemps au
		-- démarrage" regression. A single /v1/models probe lets us adopt the live
		-- server instead: if it already serves the target model, skip the relaunch
		-- entirely and let the normal warmup path re-discover + prime it
		-- (a few seconds, weights already resident). This restores the behaviour of
		-- the old async pre-probe but synchronously with a hard 1 s curl timeout, so
		-- it can never stall the boot path the way the async callback could.
		if not (deps.active_tasks and deps.active_tasks["mlx_server"]) then
			local ok_probe, body = pcall(hs.execute,
				"/usr/bin/curl --silent --max-time 1 --no-keepalive " ..
				"-H 'Connection: close' http://127.0.0.1:" .. MLX_PORT .. "/v1/models")
			if not current_or_cancel() then return false end
			if ok_probe and probe_matches_target(body) then
				Logger.info(LOG, "Adopting MLX server from a previous session (already serving '%s' on :%d) — skipping cold restart.",
					tostring(target_model), MLX_PORT)
				obj._server_target = target_model
				-- Adopted from a previous session with the weights already resident, so
				-- this one really is ready — a later duplicate request must resolve
				-- immediately rather than queue behind a startup that will never run.
				obj._server_ready = true
				cancel_server_waiters()
				if type(ApiMlx) == "table" and type(ApiMlx.reset_endpoints) == "function" then
					ApiMlx.reset_endpoints()
				end
				if type(ApiMlx) == "table" and type(ApiMlx.set_model_hf_path) == "function" then
					ApiMlx.set_model_hf_path(repo)
				end
				settle_success()
				return true
			end
		end

		-- Skip the async pre-probe: if a server is already listening, probe_server_ready
		-- will detect it on the first 0.5 s tick. The asyncGet pre-probe was introduced
		-- to short-circuit task creation for an already-running server, but it blocked
		-- all subsequent server-start logic when the HTTP callback was delayed (e.g.
		-- connection refused on macOS can take several seconds to resolve asynchronously),
		-- causing the task to never be created and predictions to stay locked indefinitely.
		do
			if not current_or_cancel() then return false end
			obj._server_target = target_model
			-- The new server process may run a different mlx-lm version or be
			-- configured for different routes than the previous one; clear the
			-- cached discovery result so the first warmup re-probes rather than
			-- reusing stale endpoint paths that return 404 for this new server
			if type(ApiMlx) == "table" and type(ApiMlx.reset_endpoints) == "function" then
				ApiMlx.reset_endpoints()
			end
			-- Store the authoritative HF path used to launch the server so the
			-- discovery bypass can fall back to it when /v1/models returns a stale
			-- model ID. Without this, warmup sends the wrong model name and every
			-- request returns 404, creating an infinite discovery-reset loop.
			if type(ApiMlx) == "table" and type(ApiMlx.set_model_hf_path) == "function" then
				ApiMlx.set_model_hf_path(repo)
			end
			-- All MLX server output is funneled into the unified Ergopti log so
			-- the user has a single tail target. Each line is prefixed
			-- [MLX-SERVER] downstream so it stands out from Hammerspoon's own
			-- log entries.
			local unified_log_file = Logger.UNIFIED_LOG_FILE
			Logger.info(LOG, "Starting MLX server process for model %s — output prefixed [MLX-SERVER] in %s",
				tostring(target_model), unified_log_file)
			local startup_confirmed = false
			local startup_closed = false
			-- A fresh server is not ready, and any waiter queued against the PREVIOUS
			-- one must not be resolved by this launch's probe: they asked about a
			-- process that has since been terminated.
			obj._server_ready = false
			cancel_server_waiters()

			-- Declared before every retry/error closure. A declaration beside the
			-- later constructor would bind those closures to a global `task` instead.
			local task
			local probe_server_ready
			local fail_server_start

			local function waiter_is_current(waiter)
				if type(waiter) ~= "table" or type(waiter.is_current) ~= "function" then
					return true
				end
				local ok, current = ApiCommon.protected_call(
					waiter.is_current, "MLX server waiter freshness check")
				return ok == true and current == true
			end

			local function has_live_demand()
				if still_current() then return true end
				settle_cancel("stale")
				for _, waiter in ipairs(obj._server_waiters or {}) do
					if waiter_is_current(waiter) then return true end
				end
				return false
			end

			local function mark_server_ready()
				if startup_confirmed or startup_closed then return end
				if not has_live_demand() then
					fail_server_start()
					if task and type(task.terminate) == "function" then
						pcall(function() task:terminate() end)
					end
					return
				end
				if obj._server_owner ~= task then
					fail_server_start()
					return
				end
				startup_confirmed = true
				-- Promoted to obj state: a start_server call arriving after this point
				-- must be able to see that the server is ready, and one arriving BEFORE
				-- it must be able to queue. A per-invocation local could do neither.
				obj._server_ready = true
				settle_success()
				local waiters = obj._server_waiters or {}
				obj._server_waiters = {}
				for _, waiter in ipairs(waiters) do
					local callback = type(waiter) == "table" and waiter.on_success or waiter
					ApiCommon.protected_call(callback, "MLX server waiter on_success")
				end
			end

			fail_server_start = function()
				if startup_confirmed or startup_closed then return false end
				startup_closed = true
				local owns_server_state = obj._server_owner == nil or obj._server_owner == task
				if owns_server_state then
					obj._server_ready = false
					obj._server_owner = nil
					if obj._server_target == target_model then obj._server_target = nil end
				end
				settle_cancel("server_start_failed")
				if owns_server_state then
					for _, waiter in ipairs(take_server_waiters()) do
						local callback = type(waiter) == "table" and waiter.on_cancel or nil
						ApiCommon.protected_call(callback, "MLX server waiter on_cancel")
					end
				end
				return true
			end

			local function close_after_async_error()
				if not fail_server_start() then
					startup_closed = true
					if obj._server_owner == task then
						obj._server_ready = false
						obj._server_owner = nil
						if obj._server_target == target_model then obj._server_target = nil end
					end
				end
				-- A failed scheduler leaves no readiness owner. Stop the exact server
				-- task rather than allowing an unobservable process to keep serving a
				-- model whose callers were already released as failed.
				if task then
					local ok_terminate, terminated = xpcall(function()
						return task:terminate()
					end, debug.traceback)
					if not ok_terminate or terminated == false then
						Logger.error(LOG, "MLX server termination after async failure was refused: %s.",
							tostring(terminated))
					end
				end
			end

			local function demand_or_close()
				if has_live_demand() then return true end
				close_after_async_error()
				return false
			end

			local function schedule_probe_retry(retries)
				if not demand_or_close() then return false end
				local installing = true
				local callback_ran = false
				local ok_timer, timer_or_error = xpcall(function()
					return hs.timer.doAfter(0.5, function()
						callback_ran = true
						if installing then return end
						local ok = run_async_callback("MLX readiness retry timer", function()
							if not demand_or_close() then return end
							probe_server_ready(retries)
						end)
						if not ok then close_after_async_error() end
					end)
				end, debug.traceback)
				installing = false
				if not ok_timer or not timer_or_error or callback_ran then
					Logger.error(LOG, "MLX readiness retry timer was not committed: %s.",
						tostring(ok_timer and (callback_ran and "callback ran before handle publication"
							or timer_or_error) or timer_or_error))
					close_after_async_error()
					return false
				end
				return true
			end

			probe_server_ready = function(retries)
				if startup_closed or startup_confirmed then return end
				if not demand_or_close() then return end
				if retries <= 0 then
					-- 60 s elapsed without the server answering — release the prediction
					-- lock so the user is not silently stuck; log for diagnosis
					Logger.error(LOG, "MLX server for model '%s' did not become ready within 60s — releasing prediction lock.",
						tostring(target_model))
					fail_server_start()
					return
				end
				-- Use curl --no-keepalive so each probe opens a fresh TCP connection.
				-- hs.http pools connections and reuses a keep-alive socket to a zombie
				-- server, making this probe see the zombie's stale model ID indefinitely.
				local probe_task
				probe_task = TaskLifecycle.native("MLX readiness probe", "/usr/bin/curl", function(exit_code, stdout)
					if probe_task then _active_tasks[probe_task] = nil end  -- probe_task captured by closure
					local ok = run_async_callback("MLX readiness probe completion", function()
						if startup_closed or startup_confirmed then return end
						if not demand_or_close() then return end
						if exit_code == 0 and probe_matches_target(stdout or "") then
							mark_server_ready()
						else
							schedule_probe_retry(retries - 1)
						end
					end)
					if not ok then close_after_async_error() end
				end, {
					"--silent", "--max-time", "5", "--no-keepalive",
					"-H", "Connection: close",
					"http://127.0.0.1:" .. MLX_PORT .. "/v1/models",
				})
				if probe_task then
					if not demand_or_close() then return end
					_active_tasks[probe_task] = true
					if not TaskLifecycle.start(probe_task, "MLX readiness probe") then
						_active_tasks[probe_task] = nil
						schedule_probe_retry(retries - 1)
					end
				else
					schedule_probe_retry(retries - 1)
				end
			end

			-- Every line of MLX stdout/stderr gets:
			--   1. timestamped + prefixed [MLX-SERVER] by a small bash
			--      `while read` loop. The previous awk-based version used
			--      `strftime()` and `fflush(file)` which are gawk extensions
			--      not supported by macOS' default BWK awk — the awk crashed
			--      on the first line, the pipe closed, and the whole MLX
			--      server died on SIGPIPE before producing any output.
			--   2. appended to the unified Ergopti log via `tee -a`
			--   3. ALSO emitted on the bash task's stdout (tee writes both)
			--      so the existing stream callback (server_log_buffer /
			--      crash detector / ready probe) keeps working unchanged.
			local bash_cmd =
				"export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; " ..
				"export SSL_CERT_FILE=/etc/ssl/cert.pem; " ..
				"export REQUESTS_CA_BUNDLE=/etc/ssl/cert.pem; " ..
				"export HF_HUB_DISABLE_XET=1; " ..
				-- HF_HUB_OFFLINE=1 forces huggingface_hub to use ONLY the local cache
				-- and skip every HTTPS call to huggingface.co. Required behind a
				-- corporate proxy with a self-signed root CA, because the httpx
				-- client used by huggingface_hub>=1.x ignores SSL_CERT_FILE /
				-- REQUESTS_CA_BUNDLE and uses its own SSL context — a single
				-- snapshot-validation call on first inference would fail with
				-- CERTIFICATE_VERIFY_FAILED and crash mlx_lm's _generate thread.
				-- TRANSFORMERS_OFFLINE=1 mirrors the policy for transformers.
				"export HF_HUB_OFFLINE=1; " ..
				"export TRANSFORMERS_OFFLINE=1; " ..
				"export PYTHONUNBUFFERED=1; " ..
				-- Fail fast if the pinned project venv is missing — any other Python
				-- would bypass the pinned mlx-lm version
				"PYTHON_BIN=\"" .. project_venv_python_escaped .. "\"; " ..
				"if [ ! -x \"$PYTHON_BIN\" ]; then echo \"[MLX] ❌ venv introuvable : $PYTHON_BIN\"; exit 1; fi; " ..
				"echo \"[MLX] Python utilisé: $PYTHON_BIN\"; " ..
				-- Kill strategy: setsid launches Python in its own process group so we
				-- can kill the entire tree (Python + any fork()+exec() children whose
				-- argv no longer contains 'mlx_lm') with a single `kill -PGID`. This
				-- is the only reliable approach: pgrep misses exec-replaced argv,
				-- lsof misses processes between accept() calls, and PID-only kill
				-- leaves orphaned children alive. Three steps, each increasingly broad:
				--   1. PGID file: kill the whole process group of the previous server.
				--   2. pgrep fallback: catch any surviving mlx_lm process by argv.
				--   3. lsof fallback: last resort for anything still holding port 8080.
				"MLX_PID_FILE=/tmp/mlx_server.pid; " ..
				"MLX_PGID_FILE=/tmp/mlx_server.pgid; " ..
				-- IMPORTANT: we used to also kill by saved PGID (kill -9 -<PGID>) here.
				-- That turned out to be unsafe on macOS: PIDs/PGIDs are aggressively
				-- recycled, and after a Hammerspoon reload the recorded PGID could
				-- legitimately belong to the new Hammerspoon process (or any other
				-- innocent app), making `kill -9 -<PGID>` a roulette that tore down
				-- the menubar mid-switch. We now rely exclusively on the PID-based
				-- kill below — targeted, safe, and sufficient for cleaning up the
				-- previous mlx_lm.server. The PGID file is still written by the
				-- launcher (kept for future debugging) but ignored on shutdown.
				"if [ -f \"$MLX_PGID_FILE\" ]; then " ..
				"OLD_PGID=$(cat \"$MLX_PGID_FILE\" 2>/dev/null | tr -d '[:space:]'); " ..
				"echo \"[MLX] Skipping PGID-kill of $OLD_PGID — PID-based kill is safer on macOS.\"; " ..
				"rm -f \"$MLX_PGID_FILE\"; " ..
				"fi; " ..
				-- Step 1: kill by PID (the recorded mlx_lm.server pid). Targeted
				-- and safe — no risk of hitting an unrelated process via PGID
				-- recycling.
				"if [ -f \"$MLX_PID_FILE\" ]; then " ..
				"OLD_PID=$(cat \"$MLX_PID_FILE\" 2>/dev/null | tr -d '[:space:]'); " ..
				"if [ -n \"$OLD_PID\" ] && kill -0 \"$OLD_PID\" 2>/dev/null; then " ..
				-- macOS aggressively recycles PIDs after a Hammerspoon reload, so the
				-- PID we wrote at launch may now belong to ANY process — including
				-- Hammerspoon itself. Verify the process is still a python interpreter
				-- running mlx_lm before issuing kill -9; otherwise we risk taking
				-- down the menubar app on every model switch.
				"OLD_COMM=$(ps -o comm= -p \"$OLD_PID\" 2>/dev/null | tr -d '[:space:]'); " ..
				"OLD_ARGS=$(ps -o args= -p \"$OLD_PID\" 2>/dev/null); " ..
				"if echo \"$OLD_COMM\" | grep -qi python && echo \"$OLD_ARGS\" | grep -q mlx_lm; then " ..
				"echo \"[MLX] Killing previous server PID $OLD_PID (verified python+mlx_lm)…\"; " ..
				"kill -9 \"$OLD_PID\" 2>/dev/null || true; " ..
				"else " ..
				"echo \"[MLX] ⚠️  PID $OLD_PID is alive but not a python+mlx_lm process (comm='$OLD_COMM') — refusing to kill (PID was recycled, likely Hammerspoon).\"; " ..
				"fi; " ..
				"else " ..
				"echo \"[MLX] PID file stale (PID $OLD_PID not running).\"; " ..
				"fi; " ..
				"rm -f \"$MLX_PID_FILE\"; " ..
				"fi; " ..
				-- Step 2: argv fallback — filter on COMM (executable basename), not on the
				-- full argv. A bare pgrep -f 'python.*mlx_lm' also matches THIS bash wrapper:
				-- its argv is "/bin/bash -c <SCRIPT>", and the script text literally contains
				-- the substring 'python… -m mlx_lm', so the regex hits it. Killing that PID
				-- is suicide on the Hammerspoon-watched task. Using $2 (comm) instead skips
				-- bash cleanly: only processes whose executable starts with python qualify.
				"PGREP_PIDS=$(ps -axo pid=,comm=,args= | awk '$2 ~ /^[Pp]ython/ && /mlx_lm/ {print $1}' || true); " ..
				"if [ -n \"$PGREP_PIDS\" ]; then " ..
				"echo \"[MLX] mlx_lm process(es) still alive (PIDs: $PGREP_PIDS) — killing…\"; " ..
				"echo \"$PGREP_PIDS\" | xargs kill -9 2>/dev/null || true; " ..
				"sleep 1; " ..
				"fi; " ..
				-- Step 3: lsof retry loop — port 8080 must be free before we start.
				-- The initial sleep gives the kernel time to finish releasing the socket
				-- after kill -9 AND lets any SO_REUSEPORT zombie re-bind so that lsof
				-- can see it. Without this pause, lsof catches the port "free" during
				-- the brief window between kill -9 and the zombie re-binding, allowing
				-- both processes to co-exist. 3 s is long enough for the zombie to
				-- re-bind while short enough to not frustrate the user.
				"sleep 3; " ..
				"LSOF_ATTEMPTS=0; " ..
				"while true; do " ..
				"STALE_PIDS=$(lsof -ti TCP:" .. MLX_PORT .. " 2>/dev/null || true); " ..
				"if [ -z \"$STALE_PIDS\" ]; then " ..
				"echo \"[MLX] Port " .. MLX_PORT .. " free — starting server.\"; " ..
				"break; " ..
				"fi; " ..
				"LSOF_ATTEMPTS=$((LSOF_ATTEMPTS + 1)); " ..
				"echo \"[MLX] Port " .. MLX_PORT .. " still occupied attempt $LSOF_ATTEMPTS (PIDs: $STALE_PIDS) — killing…\"; " ..
				"echo \"$STALE_PIDS\" | xargs kill -9 2>/dev/null || true; " ..
				"if [ \"$LSOF_ATTEMPTS\" -ge 10 ]; then " ..
				"echo \"[MLX] ❌ Port " .. MLX_PORT .. " still occupied after 10 attempts — giving up.\"; " ..
				"exit 1; " ..
				"fi; " ..
				"sleep 0.5; " ..
				"done; " ..
				-- Launch Python in background, capture PID, write PID file, then attach
				-- the output loop to the background process via wait + fd redirect.
				-- Using a named FIFO lets us attach the streaming pipeline to a backgrounded
				-- process without /proc (Linux-only). The FIFO is created once per start,
				-- the Python server writes into it (via exec redirect), and the while-read
				-- loop drains it for as long as the server lives.
				"MLX_FIFO=$(mktemp -u /tmp/mlx_out.XXXXXX); " ..
				"mkfifo \"$MLX_FIFO\"; " ..
				-- set -m (job control) makes bash assign a fresh PGID to every
				-- backgrounded job — the macOS-compatible replacement for Linux setsid.
				-- set +m immediately after so the rest of the script is unaffected.
				"set -m; " ..
				-- Resolve the local snapshot path BEFORE invoking mlx_lm. Passing
				-- the HF repo id (e.g. mlx-community/Qwen3.5-2B-4bit) makes mlx_lm
				-- call huggingface_hub.snapshot_download which, even in offline
				-- mode (HF_HUB_OFFLINE=1), insists on resolving a refs/main entry
				-- and a specific revision and crashes with "Cannot find an
				-- appropriate cached snapshot folder for the specified revision"
				-- when those metadata files are missing — common in caches built
				-- by alternative downloaders. By passing the snapshot directory
				-- directly as --model, mlx_lm treats it as a local path and
				-- bypasses huggingface_hub entirely.
				"REPO_ID=\"" .. repo .. "\"; " ..
				"CACHE_NAME=\"models--$(echo \"$REPO_ID\" | sed 's|/|--|g')\"; " ..
				"CACHE_ROOT=\"$HOME/.cache/huggingface/hub/$CACHE_NAME\"; " ..
				"SNAPSHOT_DIR=$(ls -dt \"$CACHE_ROOT/snapshots/\"*/ 2>/dev/null | head -1); " ..
				"if [ -n \"$SNAPSHOT_DIR\" ] && [ -d \"$SNAPSHOT_DIR\" ]; then " ..
				"MODEL_ARG=\"${SNAPSHOT_DIR%/}\"; " ..
				"echo \"[MLX] Using local snapshot path: $MODEL_ARG\"; " ..
				-- Persist the resolved snapshot path so api_mlx can use the SAME
				-- value in the "model" field of every POST payload. mlx_lm.server
				-- routes each request through model_provider.load() keyed by the
				-- payload’s "model" string; if we send the repo id instead of the
				-- local path, the server tries snapshot_download on the repo and
				-- fails with the offline error. Identical strings → cache hit on
				-- the model loaded at boot, no HF call.
				"echo \"$MODEL_ARG\" > /tmp/mlx_active_model.txt; " ..
				-- mlx-lm 0.31.x's _download() always calls huggingface_hub
				-- snapshot_download even when the --model argument is an
				-- absolute local path. With HF_HUB_OFFLINE=1, snapshot_download
				-- still needs refs/<revision> on disk to resolve the snapshot
				-- hash; if that file is missing (caches built by uv, partial
				-- downloads, or pre-1.x hf-xet leave it out), the call fails
				-- with "Cannot find an appropriate cached snapshot folder for
				-- the specified revision" and every inference returns 404 with
				-- that error body. Synthesize refs/main from the snapshot dir
				-- name (which IS the commit hash) so the resolver succeeds.
				"REVISION=$(basename \"$MODEL_ARG\"); " ..
				"mkdir -p \"$CACHE_ROOT/refs\"; " ..
				"if [ ! -f \"$CACHE_ROOT/refs/main\" ]; then " ..
				"echo \"$REVISION\" > \"$CACHE_ROOT/refs/main\"; " ..
				"echo \"[MLX] Wrote refs/main = $REVISION (was missing — required by HF offline mode).\"; " ..
				"fi; " ..
				"else " ..
				"MODEL_ARG=\"$REPO_ID\"; " ..
				"echo \"[MLX] No local snapshot found for $REPO_ID — falling back to repo id.\"; " ..
				"echo \"$REPO_ID\" > /tmp/mlx_active_model.txt; " ..
				"fi; " ..
				-- --decode-concurrency 1 --prompt-concurrency 1 disables mlx-lm's
				-- BatchGenerator which is broken in 0.31.x: filtering across worker
				-- threads triggers `RuntimeError: There is no Stream(gpu, 0) in
				-- current thread` and the generate thread dies before sending the
				-- response body, leaving the client hanging on a 200 with empty body.
				-- Forcing serial execution sidesteps the bug entirely; for our
				-- single-user prediction use case batching brought no benefit anyway.
				-- --port pins the bind port to our resolved value. mlx_lm.server
				-- otherwise binds its own 8080 default, which would silently ignore
				-- the shared-config / user-override port and make every client probe
				-- the wrong address (the centralized port var would be a lie).
				"\"$PYTHON_BIN\" -m mlx_lm server --model \"$MODEL_ARG\" --port " .. MLX_PORT .. " --decode-concurrency 1 --prompt-concurrency 1 > \"$MLX_FIFO\" 2>&1 & " ..
				"MLX_PID=$!; " ..
				"set +m; " ..
				"MLX_PGID=$(ps -o pgid= -p $MLX_PID 2>/dev/null | tr -d ' ' || echo ''); " ..
				"echo \"[MLX] Server started with PID $MLX_PID PGID $MLX_PGID.\"; " ..
				"echo \"$MLX_PID\" > \"$MLX_PID_FILE\"; " ..
				-- Persist the PGID only if `set -m` actually isolated python into its
				-- own process group. If MLX_PGID equals our own bash PGID or our
				-- parent's (Hammerspoon's), saving it would arm a fratricidal
				-- `kill -9 -<PGID>` on the next switch that wipes the menubar app.
				"OWN_PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d '[:space:]'); " ..
				"PARENT_PGID=$(ps -o pgid= -p $PPID 2>/dev/null | tr -d '[:space:]'); " ..
				"if [ -n \"$MLX_PGID\" ] && [ \"$MLX_PGID\" != \"$OWN_PGID\" ] && [ \"$MLX_PGID\" != \"$PARENT_PGID\" ]; then " ..
				"echo \"$MLX_PGID\" > \"$MLX_PGID_FILE\"; " ..
				"echo \"[MLX] Persisted PGID $MLX_PGID (isolated from Hammerspoon group $PARENT_PGID).\"; " ..
				"else " ..
				"echo \"[MLX] ⚠️  set -m did not isolate python (MLX_PGID=$MLX_PGID, own=$OWN_PGID, parent=$PARENT_PGID) — NOT persisting PGID. Will rely on PID-only kill on next switch.\"; " ..
				"rm -f \"$MLX_PGID_FILE\"; " ..
				"fi; " ..
				"while IFS= read -r LINE; do " ..
				"OUT=\"$(date +%H:%M:%S) [MLX-SERVER] $LINE\"; " ..
				"printf '%s\\n' \"$OUT\"; " ..
				"printf '%s\\n' \"$OUT\" >> " .. unified_log_file .. "; " ..
				"done < \"$MLX_FIFO\"; " ..
				"rm -f \"$MLX_FIFO\""

			local server_last_line = ""
			local server_log_buffer = {}
			local crash_recovery_triggered = false

			-- Auto-recovery: when mlx_lm.server crashes loading the model (most often
			-- because HuggingFace shipped a new architecture / quantization format
			-- the local mlx-lm wheel does not yet understand), we get a Python
			-- traceback in the server stdout but the HTTP listener stays up and
			-- every request hangs forever. Detect those signature errors, kill the
			-- server, force-upgrade the MLX stack, and restart — once per model
			-- per Hammerspoon session to avoid loops.
			local function looks_like_arch_mismatch(text)
				if type(text) ~= "string" or text == "" then return false end
				-- Only match patterns that PROVE a model-loading failure. Earlier we
				-- also matched the bare 'Exception in thread Thread-1 (_generate)'
				-- header, which turned out to be a false positive: mlx-lm prints
				-- that line whenever its background generation thread sees an
				-- unexpected request (e.g. a 404 due to an endpoint route mismatch),
				-- and our recovery would then needlessly tear down a perfectly
				-- healthy server that just had a routing problem we should fix
				-- elsewhere.
				return text:find("Received %d+ parameters not in model")  ~= nil
				    or text:find("Missing %d+ parameters")                 ~= nil
				    or text:find("Unsupported model type",      1, true)   ~= nil
				    or text:find("ModuleNotFoundError",         1, true)   ~= nil
				    or text:find("ImportError",                 1, true)   ~= nil
			end

			--- Dumps the in-memory ring buffer (last ~15 lines captured live from
			--- the MLX server stdout) into the Hammerspoon log so the Python
			--- traceback header that triggered the crash detection lands in the
			--- same log file as everything else. The full server output is
			--- separately mirrored line-by-line into the unified rotating log via the
			--- awk prefixer, so the user can grep for [MLX-SERVER] there to see
			--- the complete trace if they need more than the last 15 lines.
			local function dump_mlx_server_log(prefix)
				if #server_log_buffer == 0 then
					Logger.warn(LOG, "%s — no buffered server lines to dump (tail %s).",
						prefix, unified_log_file)
					return
				end
				-- Only the summary line fires a notification (via Logger.error);
			-- individual trace lines use Logger.warn to avoid spamming the user
			-- with 15 separate macOS notifications for one crash event
			Logger.error(LOG, "%s — last %d line(s) from MLX server stdout (full trace in %s):",
					prefix, #server_log_buffer, unified_log_file)
				for _, line in ipairs(server_log_buffer) do
					if line:match("%S") then Logger.warn(LOG, "  | %s", line) end
				end
			end

			local function trigger_auto_recovery(reason_line)
				if crash_recovery_triggered then return end
				crash_recovery_triggered = true

				Logger.error(LOG, "MLX server for ‘%s’ crashed — giving up. Reason: %s",
					tostring(target_model), tostring(reason_line))
				dump_mlx_server_log("MLX crash for ‘" .. tostring(target_model) .. "’")
				if not silent_notifications then
					pcall(notifications.notify, "MLX incompatible",
						string.format(i18n.get("mlx.model_incompatible"), tostring(target_model)), "error")
				end
				-- Flip api_mlx into the failed state so the status dot turns RED at once
				-- and the warmup retry loop stops — otherwise the HTTP server stays up,
				-- warmup keeps retrying, and the dot is stuck orange despite this crash.
				-- notify=false: the user-facing notification (if any) was just fired above.
				if ApiMlx and type(ApiMlx.mark_load_failed) == "function" then
					pcall(ApiMlx.mark_load_failed, target_model, false)
				end
				-- Release the caller’s prediction lock so the user can switch to a working
				-- model without having to reload Hammerspoon
				fail_server_start()
			end

			task = TaskLifecycle.native("MLX server launch", "/bin/bash", function(code)
				if deps.active_tasks and deps.active_tasks["mlx_server"] == task then
					deps.active_tasks["mlx_server"] = nil
				end
				local ok = run_async_callback("MLX server completion", function()
					if startup_confirmed then
						startup_closed = true
						if obj._server_owner == task then
							obj._server_ready = false
							obj._server_owner = nil
							if obj._server_target == target_model then obj._server_target = nil end
						end
						Logger.info(LOG, "MLX server process exited with code %d.", code)
						return
					end
					if not demand_or_close() then return end
					if code == 15 then
						Logger.info(LOG, "MLX server process was terminated before readiness.")
						fail_server_start()
						return
					end

					if code == 0 and not startup_confirmed then
						-- Process exited cleanly before signalling readiness — this is unexpected
						Logger.error(LOG, "MLX server for model ‘%s’ exited before readiness (code 0).", tostring(target_model))
						-- Release prediction lock so future predictions are not silently disabled
						fail_server_start()
						return
					end

					if code ~= 0 then
						-- Look for the most informative line in the in-memory ring buffer
						-- (last ~15 lines captured live). The full server output is in
						-- The unified rotating log behind the [MLX-SERVER] prefix if needed.
						local error_msg = ""
						for _, line in ipairs(server_log_buffer) do
							if line:lower():match("error") or line:match("Traceback") or line:match("Exception") or
							   line:match("CUDA") or line:match("RuntimeError") or line:match("ModuleNotFoundError") then
								error_msg = line
								break
							end
						end
						if error_msg == "" and #server_log_buffer > 0 then
							error_msg = server_log_buffer[#server_log_buffer]
						end

						if error_msg ~= "" then
							Logger.error(LOG, "MLX server for model ‘%s’ crashed (code %d): %s", tostring(target_model), code, error_msg)
						else
							Logger.error(LOG, "MLX server for model ‘%s’ crashed (code %d).", tostring(target_model), code)
						end
						-- Release prediction lock so the session is not silently broken
						-- after an architecture-mismatch crash or any other startup failure
						fail_server_start()
					end
					Logger.info(LOG, "MLX server process exited with code %d.", code)
				end)
				if not ok then close_after_async_error() end
			end, function(_, stdout, stderr)
				local ok, continue_streaming = run_async_callback("MLX server stream", function()
					if startup_closed then return false end
					if not demand_or_close() then return false end
					if obj._server_owner ~= task then
						fail_server_start()
						return false
					end
					local out = (stdout or "") .. (stderr or "")
					if out ~= "" then
						Logger.debug(LOG, "MLX server stream chunk (%d bytes).", #out)
					end
					for line in out:gmatch("([^\n\r]+)") do
						server_last_line = line
						table.insert(server_log_buffer, line)
						while #server_log_buffer > 15 do table.remove(server_log_buffer, 1) end
						Logger.debug(LOG, "MLX server: %s", line)
						-- Inform api_mlx of the active server PGID as soon as bash reports it.
						-- The zombie-kill logic excludes the entire process group (bash wrapper
						-- + Python mlx_lm child) so it never terminates the server we just
						-- launched. PGID is used instead of PID because SO_REUSEPORT makes
						-- lsof only see the bash wrapper, not the Python child on the socket.
						local pgid_str = line:match("%[MLX%] Server started with PID %d+ PGID (%d+)")
						if pgid_str and type(ApiMlx) == "table" and type(ApiMlx.set_active_server_pgid) == "function" then
							ApiMlx.set_active_server_pgid(tonumber(pgid_str))
						end
					end
					if out:find("Starting httpd at") or out:find("Uvicorn running on") or out:find("Application startup complete") then
						mark_server_ready()
					end
					-- Lazy-loaded model crashes happen *after* the HTTP listener is up,
					-- so this detection must run on every stream chunk — not only on
					-- process exit (the process never exits when this happens)
					if not crash_recovery_triggered and looks_like_arch_mismatch(out) then
						trigger_auto_recovery(server_last_line)
					end
					return true
				end)
				if not ok then
					close_after_async_error()
					return false
				end
				return continue_streaming
			end, { "-c", bash_cmd })

			Logger.debug(LOG, "MLX server bash_cmd: %s", bash_cmd)
			if task then
				if not has_live_demand() then
					fail_server_start()
					return false
				end
				obj._server_owner = task
				deps.active_tasks["mlx_server"] = task
				if TaskLifecycle.start(task, "MLX server launch") then
					Logger.info(LOG, "MLX server task started for model ‘%s’.", tostring(target_model))
				else
					if deps.active_tasks["mlx_server"] == task then
						deps.active_tasks["mlx_server"] = nil
					end
					fail_server_start()
					return false
				end
				if not demand_or_close() then return false end
				-- 120 retries × 0.5 s = 60 s total; large models can take >30 s to load weights
				probe_server_ready(120)
			else
				fail_server_start()
				return false
			end
			return true
		end
	end
end

return M
