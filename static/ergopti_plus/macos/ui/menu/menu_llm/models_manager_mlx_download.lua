--- ui/menu/menu_llm/models_manager_mlx_download.lua

--- ==============================================================================
--- MODULE: MLX Models Manager — Model Download & Reattach
--- DESCRIPTION:
--- Attaches the HuggingFace model-download flow (obj.pull_model) and its
--- post-reload reattach path (obj.reattach_download) onto the shared MLX
--- models-manager object. Owns the detached Python downloader, its live
--- progress streaming, stall detection, gated-model handling, and the session
--- handoff that survives a Hammerspoon reload.
---
--- FEATURES & RATIONALE:
--- 1. Shared-context mixin: install(ctx) attaches pull_model/reattach_download
---    onto ctx.obj, so check_requirements keeps calling obj.pull_model unchanged
---    while this ~600-line download machinery lives on its own.
--- 2. Detached subprocess: the downloader escapes Hammerspoon's process group
---    (os.setpgrp) and persists a session JSON so a reload can reattach the tail
---    instead of restarting the download.
--- 3. Single source of truth: the installed-models cache invalidation and the
---    pinned interpreter are injected via ctx, never re-derived here.
--- ==============================================================================

local M = {}

local hs            = hs
local notifications = require("infra.notifications")
local Logger        = require("infra.logger")
local i18n          = require("infra.i18n")
local TaskLifecycle = require("adapters.task_lifecycle")
local TimerScheduler = require("adapters.timer_scheduler")

-- Optional download-progress webview; absent in headless/unusual layouts.
local ok_dw, download_window = pcall(require, "ui.download_window")
if not ok_dw then download_window = nil end

-- Same LOG tag as the parent manager so download log lines stay grouped under
-- "menu_llm.mlx" exactly as before the split.
local LOG = "menu_llm.mlx"





-- ============================================
-- ============================================
-- ======= 1/ Model Download & Reattach =======
-- ============================================
-- ============================================

--- Attaches obj.pull_model and obj.reattach_download onto the manager object.
--- @param ctx table Shared context: {
---   obj = manager object, deps = injected deps, presets = model catalogue,
---   project_venv_python_escaped = pinned interpreter path (shell-escaped),
---   invalidate_installed_cache = parent's installed-models cache invalidator }.
function M.install(ctx)
	local obj                         = ctx.obj
	local deps                        = ctx.deps
	local presets                     = ctx.presets
	local project_venv_python_escaped = ctx.project_venv_python_escaped
	local invalidate_installed_cache  = ctx.invalidate_installed_cache

	local function update_icon(label, ...)
		return Logger.callback(LOG, label, deps.update_icon, ...)
	end

	-- A download crosses several native handles (launcher, detached Python,
	-- tail) but is still one logical operation.  Keep that operation outside the
	-- individual callbacks so no stage transition can accidentally make the slot
	-- look idle while work from the previous generation is still live.
	local download_generation = 0
	local download_owner = nil

	local function timer_handle_live(handle)
		return type(handle) == "table" and handle.timer ~= nil
	end

	local function cancel_owner_timer(owner, slot)
		local handle = owner.timers and owner.timers[slot]
		if handle == nil then return true end
		if not timer_handle_live(handle) then
			owner.timers[slot] = nil
			return true
		end
		local ok, settled = Logger.callback(LOG,
			"MLX download " .. tostring(slot) .. " timer cancellation",
			TimerScheduler.cancel, handle)
		if ok == true and settled == true then
			owner.timers[slot] = nil
			return true
		end
		return false
	end

	local function cancel_owner_timers(owner, except_slot)
		local settled = true
		for slot in pairs(owner.timers or {}) do
			if slot ~= except_slot and cancel_owner_timer(owner, slot) ~= true then
				settled = false
			end
		end
		return settled
	end

	local function schedule_owner_timer(owner, slot, delay, callback)
		if owner.timers[slot] ~= nil and cancel_owner_timer(owner, slot) ~= true then
			Logger.error(LOG, "MLX download '%s' timer replacement was refused.",
				tostring(slot))
			return false
		end
		local handle
		local function deliver()
			if owner.timers[slot] ~= handle then return false end
			owner.timers[slot] = nil
			return callback()
		end
		local ok, candidate, committed = Logger.callback(LOG,
			"MLX download " .. tostring(slot) .. " timer acquisition",
			TimerScheduler.after, delay, deliver)
		if type(candidate) == "table" and timer_handle_live(candidate) then
			owner.timers[slot] = candidate
		end
		if ok ~= true or type(candidate) ~= "table" or committed ~= true then
			Logger.error(LOG, "MLX download '%s' timer acquisition was refused.",
				tostring(slot))
			return false
		end
		handle = candidate
		owner.timers[slot] = candidate
		return true
	end

	local function owner_has_native_work(owner)
		for slot, handle in pairs(owner.timers or {}) do
			if timer_handle_live(handle) then return true end
			owner.timers[slot] = nil
		end
		return owner.tasks.launcher ~= nil
			or owner.tasks.tail ~= nil
			or owner.partial.pid ~= nil
			or owner.server_pending == true
	end

	local function release_download_owner(owner)
		if download_owner ~= owner or owner.keep_registered
			or owner_has_native_work(owner) then return false end
		if type(owner.remove_session) == "function"
			and owner.remove_session() ~= true then return false end
		if type(owner.on_release) == "function" then owner.on_release() end
		owner.active = false
		download_owner = nil
		return true
	end

	local function open_owned_file(path, mode, label)
		local ok, handle, detail = Logger.callback(LOG, label .. " open", io.open, path, mode)
		if ok ~= true or handle == nil or handle == false then
			Logger.error(LOG, "%s open was refused: %s.", label, tostring(detail or handle))
			return nil
		end
		return handle
	end

	local function exact_writer(handle, label)
		local writer = { failed = false, closed = false }
		function writer:write(...)
			if self.failed or self.closed then return nil end
			local values = table.pack(...)
			local ok, result = Logger.callback(LOG, label .. " write", function()
				return handle:write(table.unpack(values, 1, values.n))
			end)
			if ok ~= true or result == false or result == nil then
				self.failed = true
				Logger.error(LOG, "%s write was refused: %s.", label, tostring(result))
				return nil
			end
			return self
		end
		function writer:close()
			if self.closed then return self.failed ~= true end
			self.closed = true
			local ok, result = Logger.callback(LOG, label .. " close", function()
				return handle:close()
			end)
			if ok ~= true or result == false or result == nil then
				self.failed = true
				Logger.error(LOG, "%s close was refused: %s.", label, tostring(result))
			end
			return self.failed ~= true
		end
		return writer
	end

	local function write_owned_file(path, payload, label)
		local handle = open_owned_file(path, "w", label)
		if not handle then return false end
		local writer = exact_writer(handle, label)
		writer:write(payload)
		return writer:close() == true
	end

	local function publish_owned_file(path, payload, label)
		local candidate = path .. ".candidate"
		if write_owned_file(candidate, payload, label .. " candidate") ~= true then
			Logger.callback(LOG, label .. " candidate cleanup", os.remove, candidate)
			return false
		end
		local ok, renamed = Logger.callback(LOG, label .. " publication",
			os.rename, candidate, path)
		if ok ~= true or renamed == false or renamed == nil then
			Logger.callback(LOG, label .. " candidate cleanup", os.remove, candidate)
			return false
		end
		return true
	end

	local function execute_exact(command, label)
		local ok, result = Logger.callback(LOG, label, os.execute, command)
		return ok == true and (result == true or result == 0)
	end

	function obj.pull_model(target_model, repo, on_success, on_cancel, opts)
		local is_current = type(opts) == "table" and opts.is_current or function() return true end
		local owner = {
			active = true,
			generation = download_generation + 1,
			attempt_generation = 0,
			tasks = { launcher = nil, tail = nil },
			timers = {},
			partial = { pid = nil },
			on_success = on_success,
			on_cancel = on_cancel,
			terminal_sent = false,
			revoked = false,
		}
		download_generation = owner.generation
		local function settle(callback, label, ...)
			if owner.terminal_sent then return false end
			owner.terminal_sent = true
			if type(callback) ~= "function" then return true end
			local ok, result = Logger.callback(LOG, label, callback, ...)
			return ok and result ~= false
		end
		local function settle_cancel(...)
			return settle(on_cancel, "MLX download cancellation", ...)
		end
		local function logical_current()
			if owner.revoked then return false end
			if owner.registered and download_owner ~= owner then return false end
			local ok, current = Logger.callback(LOG,
				"MLX download freshness check", is_current)
			return ok == true and current == true
		end
		local function logical_or_cancel()
			if logical_current() then return true end
			if type(owner.cancel) == "function" then
				owner.cancel(true, "stale")
			else
				owner.revoked = true
				settle_cancel("stale")
				release_download_owner(owner)
			end
			return false
		end

		if not logical_or_cancel() then return false end
		-- Refuse re-entry while a download owns the shared slots.
		--
		-- Every piece of download state is a SINGLE global slot: the two task
		-- entries, the menubar icon, /tmp/hs_mlx_active_download.json and the one
		-- shared progress window. A second pull_model overwrote all of them, so
		-- the first download became unstoppable (its cancel and timeout paths now
		-- addressed the second one's slots) while the window narrated whichever
		-- had written last. The timeout path is the sharpest edge: a stall in the
		-- first called complete(false) and do_cancel(true) against the second
		-- one's tasks and session file.
		if download_owner ~= nil
			and (download_owner.revoked == true or download_owner.terminal_sent == true)
			and type(download_owner.retry_cleanup) == "function" then
			local prior_owner = download_owner
			Logger.callback(LOG, "MLX prior download cleanup retry",
				prior_owner.retry_cleanup)
			release_download_owner(prior_owner)
		end
		if download_owner ~= nil or (deps.active_tasks
			and (deps.active_tasks["download"] or deps.active_tasks["download_tail"])) then
			Logger.warn(LOG, "A model download is already running — ignoring the request for '%s'.",
				tostring(target_model))
			-- Surface the download already in progress rather than failing silently:
			-- from the user's side the click simply did nothing otherwise.
			if download_window and type(download_window.show) == "function" then
				pcall(download_window.show)
			end
			settle_cancel("busy")
			return false
		end
		download_owner = owner
		owner.registered = true

		local _internal_pull
		_internal_pull = function()
			if not logical_or_cancel() then return false end
			owner.attempt_generation = owner.attempt_generation + 1
			owner.download_completion_seen = false
			local attempt_generation = owner.attempt_generation
			-- The logical owner stays stable while these stage handles rotate.
			-- Locals may coordinate one attempt, but the owner table is the
			-- authoritative cross-stage lease used by entry, cancellation and late
			-- callbacks.
			local launcher_task
			local operation_closed = false
			local do_cancel
			local function still_current()
				return owner.attempt_generation == attempt_generation
					and operation_closed ~= true
					and logical_current()
			end
			local function current_or_cancel()
				if owner.attempt_generation ~= attempt_generation then return false end
				if still_current() then return true end
				if type(do_cancel) == "function" then
					do_cancel(true, "stale")
				else
					owner.revoked = true
					settle_cancel("stale")
					release_download_owner(owner)
				end
				return false
			end
			local function settle_success(...)
				if owner.attempt_generation ~= attempt_generation then return false end
				if not logical_current() then
					if type(do_cancel) == "function" then do_cancel(true, "stale") end
					return false
				end
				return settle(on_success, "MLX download success", ...)
			end
			local _rand_id   = tostring(math.random(1000, 9999))
			local _log_path  = "/tmp/hs_mlx_dl_" .. _rand_id .. ".log"
			local _exit_path = _log_path .. ".exit"
			owner.partial.log_path = _log_path
			owner.partial.exit_path = _exit_path

			local session_file = "/tmp/hs_mlx_active_download.json"
			local function remove_owned_session()
				if owner.session_published ~= true then return true end
				local handle = open_owned_file(session_file, "r", "MLX download session")
				if not handle then return false end
				local ok_read, raw = Logger.callback(LOG, "MLX download session read", function()
					return handle:read("*a")
				end)
				local ok_close, closed = Logger.callback(LOG, "MLX download session close", function()
					return handle:close()
				end)
				if ok_read ~= true or type(raw) ~= "string"
					or ok_close ~= true or closed == false or closed == nil then
					return false
				end
				local ok, session = pcall(hs.json.decode, raw)
				if ok and type(session) == "table" and session.log_path == _log_path then
					local remove_ok, removed = Logger.callback(LOG,
						"MLX download session removal", os.remove, session_file)
					if remove_ok ~= true or removed == false or removed == nil then return false end
				end
				owner.session_published = false
				return true
			end
			owner.remove_session = remove_owned_session

			local function signal_task(task, label)
				if task == nil then return true end
				if type(task.terminate) ~= "function" then
					Logger.error(LOG, "%s cancellation refused: terminate() is unavailable.", label)
					return false
				end
				local ok, result = Logger.callback(LOG, label .. " cancellation", function()
					return task:terminate()
				end)
				if not ok or result == false or result == nil then
					Logger.error(LOG, "%s cancellation was refused: %s.", label, tostring(result))
					return false
				end
				return true
			end

			local function task_proven_stopped(task, label)
				if task == nil then return true end
				local method_ok, method = pcall(function() return task.isRunning end)
				if not method_ok or type(method) ~= "function" then return false end
				local ok, running = Logger.callback(LOG, label .. " running-state probe", method, task)
				return ok == true and running == false
			end

			local poll_pid_cleanup
			local function schedule_pid_cleanup()
				if owner.partial.pid == nil then return true end
				if owner.timers.cleanup ~= nil then return true end
				return schedule_owner_timer(owner, "cleanup", 0.25, poll_pid_cleanup)
			end

			poll_pid_cleanup = function()
				local pid = owner.partial.pid
				if pid == nil then
					release_download_owner(owner)
					return true
				end
				local ok_probe, alive = Logger.callback(LOG,
					"MLX detached-download cleanup probe", os.execute,
					"kill -0 " .. tostring(pid) .. " 2>/dev/null")
				if not ok_probe then
					Logger.error(LOG, "MLX detached-download cleanup probe raised: %s.",
						tostring(alive))
					return schedule_pid_cleanup()
				end
				if alive == true or alive == 0 then
					local ok_kill, killed = Logger.callback(LOG,
						"MLX detached-download cleanup signal", os.execute,
						"kill -TERM " .. tostring(pid) .. " 2>/dev/null")
					if not ok_kill or (killed ~= true and killed ~= 0) then
						Logger.error(LOG, "MLX detached-download cleanup signal was refused: %s.",
							tostring(killed))
					end
					return schedule_pid_cleanup()
				end
				owner.partial.pid = nil
				remove_owned_session()
				release_download_owner(owner)
				return true
			end

			-- silent=true suppresses the "Annulé" notification and complete() so callers that
			-- already handle their own UI (do_retry, check_timeout) don't double-notify.
			-- Authority is revoked before any native signal; callbacks may retire their
			-- exact handles afterwards but can never publish success.
			do_cancel = function(silent, reason, keep_terminal_open)
				local retrying = keep_terminal_open == true and reason == "retry"
				if operation_closed then
					if retrying then return false end
					owner.revoked = true
					owner.retry_pending = false
					owner.keep_registered = false
					cancel_owner_timers(owner)
					settle_cancel(reason or "user_cancelled")
					if type(owner.retry_cleanup) == "function" then owner.retry_cleanup() end
					release_download_owner(owner)
					return false
				end
				operation_closed = true
				if not retrying then owner.revoked = true end
				cancel_owner_timers(owner)
				local signalled = true
				if owner.tasks.tail then
					signalled = signal_task(owner.tasks.tail, "MLX download log tail") and signalled
				end
				if owner.tasks.launcher then
					signalled = signal_task(owner.tasks.launcher,
						"MLX detached download launcher") and signalled
				end
				if owner.partial.pid then
					local ok_kill, killed = Logger.callback(LOG,
						"MLX detached-download cancellation signal", os.execute,
						"kill -TERM " .. tostring(owner.partial.pid) .. " 2>/dev/null")
					if not ok_kill or (killed ~= true and killed ~= 0) then
						Logger.error(LOG, "MLX detached-download cancellation signal was refused: %s.",
							tostring(killed))
						signalled = false
					end
					schedule_pid_cleanup()
				end
				-- A stale owner may run after its successor has already published a new
				-- percentage. Clean only the exact native/session owners in that case;
				-- resetting shared UI here would let A overwrite B.
				if reason ~= "stale" then
					update_icon("MLX download cancellation icon reset")
				end
				if not silent then
					pcall(notifications.notify, i18n.get("mlx.download_cancelled"), string.format(i18n.get("mlx.download_cancelled_body"), target_model), "warning")
					if download_window then pcall(download_window.complete, false, target_model) end
				end
				if not retrying then settle_cancel(reason or "user_cancelled") end
				release_download_owner(owner)
				return signalled
			end
			owner.cancel = do_cancel
			owner.retry_cleanup = function()
				if owner.revoked ~= true and owner.retry_pending ~= true
					and owner.terminal_sent ~= true then return false end
				cancel_owner_timers(owner, owner.retry_pending and "retry" or nil)
				if owner.tasks.tail then
					signal_task(owner.tasks.tail, "MLX download log tail")
				end
				if owner.tasks.launcher then
					signal_task(owner.tasks.launcher, "MLX detached download launcher")
				end
				if owner.partial.pid then
					poll_pid_cleanup()
				else
					remove_owned_session()
				end
				release_download_owner(owner)
				return not owner_has_native_work(owner)
			end

			local function cancel_from_ui()
				return do_cancel(false)
			end

			local function do_retry()
				if owner.terminal_sent or owner.retry_pending
					or not current_or_cancel() then return false end
				-- Keep the logical slot across the retry handoff.  No other request can
				-- enter between retiring this attempt and registering its successor.
				owner.keep_registered = true
				owner.retry_pending = true
				do_cancel(true, "retry", true)
				local schedule_retry
				schedule_retry = function()
					local scheduled = schedule_owner_timer(owner, "retry", 0.05, function()
						if owner.revoked or owner.terminal_sent or not owner.retry_pending then
							owner.keep_registered = false
							release_download_owner(owner)
							return false
						end
						if owner_has_native_work(owner) then return schedule_retry() end
						if remove_owned_session() ~= true then return schedule_retry() end
						owner.keep_registered = false
						owner.retry_pending = false
						return _internal_pull()
					end)
					if scheduled ~= true then
						owner.revoked = true
						settle_cancel("retry_timer_refused")
						owner.keep_registered = false
						owner.retry_pending = false
						release_download_owner(owner)
						return false
					end
					return true
				end
				return schedule_retry()
			end

			local function do_resolve_gated()
				if not current_or_cancel() then return false end
				if type(obj.prompt_hf_login) == "function" then
					if not schedule_owner_timer(owner, "resolve", 0.08, function()
						if not current_or_cancel() then return end
						local prompt_ok, accepted = Logger.callback(LOG,
							"MLX gated-model login prompt", obj.prompt_hf_login, function(ok)
							if not current_or_cancel() then return end
							if ok and type(do_retry) == "function" then
								if not schedule_owner_timer(owner, "prompt_retry", 0.3, do_retry) then
									do_cancel(true, "prompt_retry_timer_refused")
								end
							end
						end)
						if not prompt_ok or accepted == false or accepted == nil then
							do_cancel(true, "login_prompt_refused")
						end
					end) then
						do_cancel(true, "login_prompt_timer_refused")
						return false
					end
				end
				return true
			end

			local estimated_bytes_total = 0
			local m_table = nil
			
			for _, provider in ipairs(presets) do
				for _, family in ipairs(provider.families or {}) do
					for _, m in ipairs(family.models or {}) do
						if m.name == target_model then
							m_table = m
							local hw = m.hardware_requirements and m.hardware_requirements.mlx or {}
							if type(hw.download_gb) == "number" then
								estimated_bytes_total = math.floor(hw.download_gb * 1e9)
							elseif type(hw.ram_gb) == "number" then
								estimated_bytes_total = math.floor(hw.ram_gb * 0.14 * 1e9)
							end
							break
						end
					end
				end
			end

			local ui_sizes = nil
			if m_table then
				local hw = m_table.hardware_requirements and m_table.hardware_requirements.mlx or {}
				ui_sizes = {
					dl     = hw.download_gb and (hw.download_gb .. " Go"),
					params = m_table.parameters and m_table.parameters.total
				}
			end

			local clean_repo = repo:gsub("[%c%s]", "")
			local script_path = "/tmp/hs_mlx_dl_" .. _rand_id .. ".sh"
			local py_path     = "/tmp/hs_mlx_dl_" .. _rand_id .. ".py"
			local script_project_venv_python_escaped = project_venv_python_escaped
			local safe_repo_bash = "models--" .. clean_repo:gsub("/", "--")

			-- Write the Python downloader to a real file so it is fully independent of any pipe or
			-- heredoc — a detached process cannot read from stdin after the shell exits anyway
			if not current_or_cancel() then return false end
			local py_handle = open_owned_file(py_path, "w", "MLX Python downloader")
			if not py_handle then
				pcall(notifications.notify, i18n.get("mlx.write_py_failed"), nil, "error")
				do_cancel(true, "python_file_open_failed")
				return false
			end
			local py = exact_writer(py_handle, "MLX Python downloader")
			py:write("import sys, os, threading, atexit\n")
			-- Escape Hammerspoon's NSTask process group so hs.task:terminate() / HS reload
			-- cannot deliver SIGTERM to this process
			py:write("os.setpgrp()\n")
			py:write("_exit_path = " .. string.format("%q", _exit_path) .. "\n")
			py:write("def _write_exit(code):\n")
			py:write("    try:\n")
			py:write("        open(_exit_path, 'w').write(str(code))\n")
			py:write("    except Exception: pass\n")
			py:write("atexit.register(_write_exit, 1)\n")
			py:write("try:\n")
			py:write("    import truststore; truststore.inject_into_ssl()\n")
			py:write("except Exception: pass\n")
			py:write("try:\n")
			py:write("    from huggingface_hub import snapshot_download\n")
			py:write("except Exception:\n")
			py:write("    print('--- ERREUR DEPENDANCES ---', flush=True)\n")
			py:write("    import traceback; traceback.print_exc()\n")
			py:write("    _write_exit(1); sys.exit(1)\n")
			py:write("_hub_dir = os.path.expanduser('~/.cache/huggingface/hub')\n")
			py:write("_model_cache = os.path.join(_hub_dir, " .. string.format("%q", safe_repo_bash) .. ")\n")
			-- Snapshot existing blobs before the download starts so the watcher only counts NEW ones.
			-- This prevents pre-cached or previously-downloaded blobs from inflating the counter.
			py:write("_WEIGHT_EXTS = ('.safetensors', '.bin', '.gguf')\n")
			py:write("_blobs_dir = os.path.join(_model_cache, 'blobs')\n")
			py:write("_initial_blobs = set()\n")
			py:write("if os.path.isdir(_blobs_dir):\n")
			py:write("    for _fn in os.listdir(_blobs_dir):\n")
			py:write("        if not _fn.endswith('.lock'):\n")
			py:write("            _fp = os.path.join(_blobs_dir, _fn)\n")
			py:write("            if not os.path.islink(_fp):\n")
			py:write("                try:\n")
			py:write("                    if os.path.getsize(_fp) > 0: _initial_blobs.add(_fn)\n")
			py:write("                except: pass\n")
			py:write("_stop_evt = threading.Event()\n")
			py:write("def _size_watcher():\n")
			py:write("    while True:\n")
			py:write("        try:\n")
			py:write("            _total = 0\n")
			py:write("            for _dp, _, _fns in os.walk(_model_cache, followlinks=False):\n")
			py:write("                for _fn in _fns:\n")
			py:write("                    _fp = os.path.join(_dp, _fn)\n")
			py:write("                    if not os.path.islink(_fp):\n")
			py:write("                        try: _total += os.path.getsize(_fp)\n")
			py:write("                        except: pass\n")
			py:write("            print('__BYTES__:' + str(_total), flush=True)\n")
			-- Count only NEW blobs (not in _initial_blobs): completed files + in-progress temp files
			-- (size > 0). +1 gives the 1-based index of the file currently being downloaded.
			py:write("            _done_blobs = 0\n")
			py:write("            if os.path.isdir(_blobs_dir):\n")
			py:write("                for _fn in os.listdir(_blobs_dir):\n")
			py:write("                    if not _fn.endswith('.lock') and _fn not in _initial_blobs:\n")
			py:write("                        _fp = os.path.join(_blobs_dir, _fn)\n")
			py:write("                        if not os.path.islink(_fp):\n")
			py:write("                            try:\n")
			py:write("                                if os.path.getsize(_fp) > 0: _done_blobs += 1\n")
			py:write("                            except: pass\n")
			py:write("            print('__FILECOUNT__:' + str(_done_blobs + 1), flush=True)\n")
			py:write("        except Exception as _e:\n")
			py:write("            print('__BYTES__:ERROR:' + str(_e), flush=True)\n")
			py:write("        if _stop_evt.wait(2): break\n")
			py:write("_watcher = threading.Thread(target=_size_watcher, daemon=True)\n")
			py:write("_watcher.start()\n")
			py:write("try:\n")
			py:write("    snapshot_download(" .. string.format("%q", clean_repo) .. ", max_workers=8)\n")
			py:write("except Exception as e:\n")
			py:write("    err_str = str(e).lower()\n")
			py:write("    if '401' in err_str or '403' in err_str or 'gated' in err_str or 'unauthorized' in err_str:\n")
			py:write("        print('\\n\\u274c ERREUR : Ce mod\\u00e8le est PRIV\\u00c9 (Gated) par son cr\\u00e9ateur.', flush=True)\n")
			py:write("        print('Pour le t\\u00e9l\\u00e9charger, vous devez :', flush=True)\n")
			py:write("        print('1. Cr\\u00e9er un compte sur HuggingFace.co et accepter les conditions du mod\\u00e8le.', flush=True)\n")
			py:write("        print('2. Dans le menu LLM, utilisez le bouton : \\U0001f511 Connexion HuggingFace.', flush=True)\n")
			py:write("        print('   Option manuelle: huggingface-cli login', flush=True)\n")
			py:write("    else:\n")
			py:write("        print('\\n--- ERREUR HUGGINGFACE ---', flush=True)\n")
			py:write("        import traceback; traceback.print_exc()\n")
			py:write("    _stop_evt.set()\n")
			py:write("    _write_exit(1); sys.exit(1)\n")
			py:write("_stop_evt.set()\n")
			py:write("print('Termin\\u00e9 !', flush=True)\n")
			py:write("_write_exit(0)\n")
			py:write("atexit.unregister(_write_exit)\n")
			if py:close() ~= true then
				pcall(notifications.notify, i18n.get("mlx.write_py_failed"), nil, "error")
				do_cancel(true, "python_file_write_failed")
				return false
			end

			-- Write the launcher: resolves Python binary, installs deps, cleans stale cache,
			-- then starts Python detached via nohup (shields SIGHUP) and reports its PID
			if not current_or_cancel() then return false end
			local launcher_handle = open_owned_file(script_path, "w", "MLX launcher script")
			if not launcher_handle then
				pcall(notifications.notify, i18n.get("mlx.write_sh_failed"), nil, "error")
				do_cancel(true, "launcher_file_open_failed")
				return false
			end
			local f = exact_writer(launcher_handle, "MLX launcher script")
			f:write("#!/bin/bash\n")
			f:write("export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"\n")
			-- Pin to the project venv: any other interpreter would bypass the
			-- versions pinned in pyproject.toml. Fail fast if it is missing.
			f:write("PYTHON_BIN=\"" .. script_project_venv_python_escaped .. "\"\n")
			f:write("if [ ! -x \"$PYTHON_BIN\" ]; then\n")
			f:write("  echo \"[MLX] ❌ venv introuvable : $PYTHON_BIN — rechargez Hammerspoon (bootstrap auto)\"\n")
			f:write("  exit 1\n")
			f:write("fi\n")
			f:write("echo \"Python utilisé: $PYTHON_BIN\"\n")
			f:write("export HF_HUB_DISABLE_SYMLINKS_WARNING=1\n")
			f:write("export PYTHONUNBUFFERED=1\n")
			f:write("export SSL_CERT_FILE=/etc/ssl/cert.pem\n")
			f:write("export REQUESTS_CA_BUNDLE=/etc/ssl/cert.pem\n")
			f:write("export HF_HUB_DISABLE_XET=1\n")
			-- Dependencies are pinned in pyproject.toml and installed by uv pip
			-- sync — no runtime install/upgrade. Just verify the imports succeed.
			f:write("\"$PYTHON_BIN\" -c 'import huggingface_hub, truststore' >/dev/null 2>&1 || { echo '[MLX] ❌ huggingface_hub/truststore manquants — relancez ensure-mlx-deps.sh'; exit 1; }\n")
			f:write("\"$PYTHON_BIN\" -c 'import hf_transfer' 2>/dev/null && export HF_HUB_ENABLE_HF_TRANSFER=1 || export HF_HUB_ENABLE_HF_TRANSFER=0\n")
			f:write("HUB_DIR=\"$HOME/.cache/huggingface/hub\"\n")
			f:write("SNAP_DIR=\"$HUB_DIR/" .. safe_repo_bash .. "/snapshots\"\n")
			f:write("HAS_WEIGHTS=0\n")
			f:write("if [ -d \"$SNAP_DIR\" ]; then\n")
			f:write("  for commit_dir in \"$SNAP_DIR\"/*/; do\n")
			f:write("    for wf in \"$commit_dir\"*.safetensors \"$commit_dir\"*.bin; do\n")
			f:write("      [ -s \"$wf\" ] && HAS_WEIGHTS=1 && break 2\n")
			f:write("    done\n")
			f:write("  done\n")
			f:write("fi\n")
			f:write("if [ \"$HAS_WEIGHTS\" = '0' ] && [ -d \"$HUB_DIR/" .. safe_repo_bash .. "\" ]; then\n")
			f:write("  echo 'Cache incomplet détecté, nettoyage...'\n")
			f:write("  rm -rf \"$HUB_DIR/" .. safe_repo_bash .. "\"\n")
			f:write("fi\n")
			f:write("echo 'Démarrage du téléchargement de " .. clean_repo .. "...'\n")
			-- nohup shields SIGHUP; Python's os.setpgrp() escapes NSTask process-group kill
			f:write("nohup \"$PYTHON_BIN\" -u " .. py_path .. " >> " .. _log_path .. " 2>&1 &\n")
			f:write("echo \"__DLPID__:$!\"\n")
			-- Redirect stdout/stderr to /dev/null before exit so Python does not inherit the
			-- NSTask pipe fd — prevents the "readDataOfLength: Resource temporarily unavailable" warning
			f:write("exec 1>/dev/null 2>/dev/null\n")
			f:write("exit 0\n")
			if f:close() ~= true then
				pcall(notifications.notify, i18n.get("mlx.write_sh_failed"), nil, "error")
				do_cancel(true, "launcher_file_write_failed")
				return false
			end

			if not execute_exact("chmod +x " .. script_path, "MLX launcher chmod") then
				do_cancel(true, "launcher_chmod_failed")
				return false
			end
			if not current_or_cancel() then return false end

			-- Persist session so a future HS reload can reattach tail -f without restarting the download
			local _session_json = string.format(
				"{\"model\":\"%s\",\"log_path\":\"%s\",\"exit_path\":\"%s\",\"repo\":\"%s\"}",
				target_model, _log_path, _exit_path, clean_repo
			)
			if not publish_owned_file(session_file, _session_json,
				"MLX download session") then
				do_cancel(true, "session_write_failed")
				return false
			end
			owner.session_published = true

			if download_window then
				-- terminal_cmd points to the live log so the "Terminal" button shows real Python output
				pcall(download_window.show, {
					kind = "mlx_model",
					model = target_model,
					terminal_cmd = "tail -f " .. _log_path,
					on_cancel = cancel_from_ui,
					on_resolve = do_resolve_gated,
					on_retry = do_retry,
				})
			end
			if not current_or_cancel() then
				do_cancel(true, "stale")
				return false
			end
			update_icon("MLX download initial icon", "📥 0%")
			
			local _bytes_done, _bytes_total = 0, estimated_bytes_total
			local _current_pct = 0
			local _stream_tail = ""
			local _saw_gated_error = false
			-- Authoritative file count emitted by the Python size-watcher (__FILECOUNT__:N)
			local _python_file_count = nil

			local last_progress_time = os.time()
			local function reset_timeout()
				last_progress_time = os.time()
			end
			local function check_timeout()
				if operation_closed then return end
				if not still_current() then
					do_cancel(true, "stale")
					return
				end
				-- Guard on the operation PID rather than active_tasks: the task slot is
				-- transient for the short-lived launcher, while the detached process is
				-- retained by the stage-independent owner.
				if owner.partial.pid then
					local stall_seconds = os.difftime(os.time(), last_progress_time)
					local stall_limit = (_current_pct >= 99) and 120 or 300
					if stall_seconds >= stall_limit then
						-- The notification title already went through i18n; the body did not, so
						-- twenty of the twenty-one locales showed a French sentence under a
						-- translated heading. The minute count is the stall limit itself, so
						-- the two variants differ only in the number and in whether the
						-- download had already reached 99 %.
						local reason = i18n.format(
							(_current_pct >= 99) and "mlx.download_stalled_near_complete"
								or "mlx.download_stalled_giving_up",
							math.floor(stall_limit / 60)
						)
						pcall(notifications.notify, i18n.get("mlx.download_stalled"), reason, "warning")
						if download_window then pcall(download_window.complete, false, target_model) end
						-- Pass silent=true: notifications and window state already handled above
						do_cancel(true, "timeout")
					else
						if not schedule_owner_timer(owner, "timeout", 30, check_timeout) then
							do_cancel(true, "timeout_timer_refused")
						end
					end
				end
			end

			-- Shared stream processor used by both the launcher stdout and the tail task
			local function process_stream(out)
				if operation_closed then return false end
				if not still_current() then
					do_cancel(true, "stale")
					return false
				end
				if not out or out == "" then return true end
				local found_progress = false
				local out_l = out:lower()
				if out_l:find("gated", 1, true) or out_l:find("privé", 1, true) or out_l:find("401", 1, true) or out_l:find("403", 1, true) then
					_saw_gated_error = true
				end

				local max_bytes = _bytes_done
				for b_str in out:gmatch("__BYTES__:(%d+)") do
					local b = tonumber(b_str)
					if b and b > max_bytes then max_bytes = b end
				end
				if max_bytes > _bytes_done then
					_bytes_done = max_bytes
					found_progress = true
				end

				-- __FILECOUNT__ is emitted directly by the Python size-watcher and is far more
				-- reliable than tqdm log parsing which breaks after the first large file completes
				for fc_str in out:gmatch("__FILECOUNT__:(%d+)") do
					local fc = tonumber(fc_str)
					if fc and fc > 0 then
						_python_file_count = fc
						found_progress = true
					end
				end

				if _bytes_total > 0 then
					-- Continuously expand the total estimate to prevent exceeding 100 % — HuggingFace
					-- downloads metadata, shards, and blobs that often exceed the stated download_gb
					if _bytes_done > _bytes_total then
						local headroom = math.max(_bytes_done * 0.20, 500 * 1024 * 1024)
						_bytes_total = _bytes_done + headroom
					end
					_current_pct = math.floor((_bytes_done / _bytes_total) * 100 + 0.5)
				end
				-- 100 % is reserved exclusively for the completion event
				_current_pct = math.min(math.max(0, _current_pct), 99)

				if out:find("Terminé !", 1, true) then
					_current_pct = 100
					found_progress = true
				end

				if found_progress then reset_timeout() end

				if download_window and out ~= "" then
					local merged = (_stream_tail or "") .. out
					merged = merged:gsub("\r\n", "\n"):gsub("\r", "\n")
					local cut = merged:match(".*()\n")
					if cut then
						local complete = merged:sub(1, cut)
						_stream_tail = merged:sub(cut + 1)
						if complete ~= "" then
							pcall(download_window.update, _current_pct, _bytes_done, _bytes_total, complete, _python_file_count)
						end
					else
						_stream_tail = merged
					end
				end
				local _icon_pct = math.min(_current_pct, 99)
				if _icon_pct > 0 then
					update_icon("MLX download progress icon", "📥 " .. _icon_pct .. "%")
				end
			end

			-- Called once the Python exit file appears — reads exit code and finalises UI
			local function handle_download_done()
				if operation_closed or owner.download_completion_seen then return false end
				owner.download_completion_seen = true
				cancel_owner_timer(owner, "poll")
				cancel_owner_timer(owner, "timeout")
				cancel_owner_timer(owner, "tail_done")
				if owner.tasks.tail then
					signal_task(owner.tasks.tail, "MLX download log tail")
				end
				-- The exit file is written by the detached Python process itself, so it
				-- is the exact proof that the process no longer owns this operation.
				owner.partial.pid = nil

				-- Read exit code written by Python atexit handler
				local ef = open_owned_file(_exit_path, "r", "MLX download exit file")
				if not ef then
					do_cancel(true, "exit_file_read_failed")
					return false
				end
				local read_ok, raw = Logger.callback(LOG, "MLX download exit-code read", function()
					return ef:read("*l")
				end)
				local close_ok, closed = Logger.callback(LOG, "MLX download exit-file close", function()
					return ef:close()
				end)
				if read_ok ~= true or type(raw) ~= "string"
					or close_ok ~= true or closed == false or closed == nil then
					do_cancel(true, "exit_file_read_failed")
					return false
				end
				local exit_code = tonumber(raw) or 1
				Logger.callback(LOG, "MLX download exit-file removal", os.remove, _exit_path)
				if not current_or_cancel() then
					owner.revoked = true
					release_download_owner(owner)
					return false
				end
				operation_closed = true
				remove_owned_session()

				update_icon("MLX download completion icon reset")
				-- Flush any remaining buffered output before showing final status
				if _stream_tail ~= "" and download_window then
					pcall(download_window.update, _current_pct, _bytes_done, _bytes_total, _stream_tail, _python_file_count)
					_stream_tail = ""
				end

				if exit_code == 0 then
					pcall(notifications.notify, i18n.get("mlx.model_installed"), string.format(i18n.get("mlx.model_ready"), target_model), "success")
					if download_window then pcall(download_window.complete, true, target_model) end
					-- Installation owns only the cache and server readiness.  Model
					-- identity/runtime/persistence belong to ModelSwitcher, whose parent
					-- transaction commits only after this success terminal.
					local cache_ok, invalidated = Logger.callback(LOG,
						"MLX downloaded-model cache invalidation", invalidate_installed_cache)
					if not cache_ok or invalidated == false then
						owner.revoked = true
						settle_cancel("cache_invalidation_failed")
						release_download_owner(owner)
						return false
					end
					if owner.attempt_generation ~= attempt_generation
						or not logical_current() then return false end
					owner.server_pending = true
					local server_dispatching = true
					local pending_server_terminal = nil
					local function finish_server(kind, values)
						if owner.server_pending ~= true then return false end
						owner.server_pending = false
						if kind == "success" then
							local result = settle_success(
								table.unpack(values, 1, values.n))
							release_download_owner(owner)
							return result
						end
						owner.revoked = true
						local reason = values[1] or "server_start_failed"
						local result = settle_cancel(reason)
						release_download_owner(owner)
						return result
					end
					local dispatch_ok, accepted = Logger.callback(LOG,
						"MLX downloaded-model server dispatch", obj.start_server, target_model,
						function(...)
							local values = table.pack(...)
							if server_dispatching then
								if pending_server_terminal == nil then
									pending_server_terminal = {"success", values}
								end
								return true
							end
							return finish_server("success", values)
						end,
						function(...)
							local values = table.pack(...)
							if server_dispatching then
								if pending_server_terminal == nil then
									pending_server_terminal = {"failure", values}
								end
								return true
							end
							return finish_server("failure", values)
						end, opts)
					server_dispatching = false
					if not dispatch_ok or accepted ~= true then
						owner.server_pending = false
						owner.revoked = true
						settle_cancel("server_start_refused")
						release_download_owner(owner)
						return false
					end
					if pending_server_terminal ~= nil then
						return finish_server(pending_server_terminal[1],
							pending_server_terminal[2])
					end
					return true
				else
					if download_window then pcall(download_window.complete, false, target_model, _saw_gated_error and "gated" or nil) end
					pcall(notifications.notify, i18n.get("mlx.download_failed"), i18n.get("mlx.download_failed_body"), "error")
					owner.revoked = true
					settle_cancel("process_failed")
					release_download_owner(owner)
					return false
				end
			end

			-- Starts a tail -f task that streams the Python log file back to Lua in real time;
			-- also polls the exit file every 3 s to catch completion reliably
			local function start_tail_monitor()
				if operation_closed then return false end
				if not still_current() then
					do_cancel(true, "stale")
					return false
				end
				local tail_task
				local tail_starting = true
				local pending_tail_completion = false
				local function finish_tail()
					if owner.tasks.tail ~= tail_task then return false end
					owner.tasks.tail = nil
					if deps.active_tasks and deps.active_tasks["download_tail"] == tail_task then
						deps.active_tasks["download_tail"] = nil
					end
					if owner.revoked then
						release_download_owner(owner)
						return false
					end
					if operation_closed then
						release_download_owner(owner)
						return true
					end
					-- Tail exited (or was cancelled) — the detached process' exit file
					-- remains the authority for download completion.
					if not schedule_owner_timer(owner, "tail_done", 0.5, function()
						if operation_closed or owner.revoked or download_owner ~= owner then return end
						if not still_current() then
							do_cancel(true, "stale")
							return
						end
						local open_ok, ef = Logger.callback(LOG,
							"MLX download exit-file probe", io.open, _exit_path, "r")
						if not open_ok then return do_cancel(true, "exit_file_probe_failed") end
						if ef then
							local close_ok, closed = Logger.callback(LOG,
								"MLX download exit-file probe close", function() return ef:close() end)
							if not close_ok or closed == false or closed == nil then
								return do_cancel(true, "exit_file_probe_failed")
							end
							return handle_download_done()
						end
					end) then
						do_cancel(true, "tail_completion_timer_refused")
						return false
					end
					return true
				end

				tail_task = TaskLifecycle.native("MLX download log tail", "/usr/bin/tail", function()
					if tail_starting then
						pending_tail_completion = true
						return true
					end
					return finish_tail()
				end, function(_, stdout, stderr)
					return process_stream((stdout or "") .. (stderr or "")) ~= false
				end, {"-F", "-n", "+1", _log_path})

				if tail_task then
					if not still_current() then
						do_cancel(true, "stale")
						return false
					end
					owner.tasks.tail = tail_task
					if deps.active_tasks then deps.active_tasks["download_tail"] = tail_task end
					local started = TaskLifecycle.start(tail_task, "MLX download log tail")
					tail_starting = false
					if started ~= true then
						signal_task(tail_task, "MLX download log tail")
						local task_settled = pending_tail_completion
							or task_proven_stopped(tail_task, "MLX download log tail")
						if task_settled then
							if deps.active_tasks and deps.active_tasks["download_tail"] == tail_task then
								deps.active_tasks["download_tail"] = nil
							end
							owner.tasks.tail = nil
						end
						do_cancel(true, "tail_task_start_refused")
						return false
					end
					if pending_tail_completion then finish_tail() end
				else
					tail_starting = false
					do_cancel(true, "tail_task_construction_failed")
					return false
				end

				-- Periodic poll: tail can miss the very last flush before Python exits
				local function poll_exit()
					if operation_closed then return end
					if not still_current() then
						do_cancel(true, "stale")
						return
					end
					if not owner.partial.pid then return end
					local open_ok, ef = Logger.callback(LOG,
						"MLX download exit-file poll", io.open, _exit_path, "r")
					if not open_ok then return do_cancel(true, "exit_file_probe_failed") end
					if ef then
						local close_ok, closed = Logger.callback(LOG,
							"MLX download exit-file poll close", function() return ef:close() end)
						if not close_ok or closed == false or closed == nil then
							return do_cancel(true, "exit_file_probe_failed")
						end
						return handle_download_done()
					end
					if not schedule_owner_timer(owner, "poll", 3, poll_exit) then
						return do_cancel(true, "poll_timer_refused")
					end
				end
				if not schedule_owner_timer(owner, "poll", 3, poll_exit) then
					do_cancel(true, "poll_timer_refused")
					return false
				end
				if not schedule_owner_timer(owner, "timeout", 30, check_timeout) then
					do_cancel(true, "timeout_timer_refused")
					return false
				end
				return true
			end

			-- Short-lived launcher: resolves Python, installs deps, cleans stale cache, then
			-- exits after spawning the detached Python process and printing its PID
			if not current_or_cancel() then return false end
			local launcher_starting = true
			local pending_launcher_completion = nil
			local function persist_owned_pid()
				local sf = open_owned_file(session_file, "r", "MLX download session")
				if not sf then return false end
				local read_ok, raw = Logger.callback(LOG, "MLX download session PID read", function()
					return sf:read("*a")
				end)
				local close_ok, closed = Logger.callback(LOG, "MLX download session PID close", function()
					return sf:close()
				end)
				if read_ok ~= true or type(raw) ~= "string"
					or close_ok ~= true or closed == false or closed == nil then return false end
				local decode_ok, sess = Logger.callback(LOG,
					"MLX download session PID decode", hs.json.decode, raw)
				if decode_ok ~= true or type(sess) ~= "table"
					or sess.log_path ~= _log_path then return false end
				sess.pid = owner.partial.pid
				local encode_ok, encoded = Logger.callback(LOG,
					"MLX download session PID encode", hs.json.encode, sess)
				if encode_ok ~= true or type(encoded) ~= "string" then return false end
				return publish_owned_file(session_file, encoded, "MLX download session PID")
			end
			local function finish_launcher(code)
				if owner.tasks.launcher ~= launcher_task then return false end
				owner.tasks.launcher = nil
				if deps.active_tasks and deps.active_tasks["download"] == launcher_task then
					deps.active_tasks["download"] = nil
				end
				if operation_closed or owner.revoked then
					if owner.partial.pid then schedule_pid_cleanup() end
					release_download_owner(owner)
					return false
				end
				if not still_current() then
					do_cancel(true, "stale")
					return false
				end
				-- stdout/stderr are empty when a streaming callback is active — the
				-- owner PID was already set by the __DLPID__ stream sentinel.
				if not owner.partial.pid or code ~= 0 then
					-- Reset icon here: handle_download_done will not run after a launcher failure
					update_icon("MLX launcher-failure icon reset")
					if download_window then pcall(download_window.complete, false, target_model) end
					pcall(notifications.notify, i18n.get("mlx.launcher_failed"), string.format(i18n.get("mlx.launcher_failed_body"), code), "error")
					do_cancel(true, "launcher_failed")
					return false
				end
				return start_tail_monitor()
			end

			launcher_task = TaskLifecycle.native("MLX detached download launcher", script_path, function(code)
				if launcher_starting then
					if pending_launcher_completion == nil then
						pending_launcher_completion = table.pack(code)
					end
					return true
				end
				return finish_launcher(code)
			end, function(_, stdout, stderr)
				local out = (stdout or "") .. (stderr or "")
				-- Resource discovery remains live after logical revocation: a queued PID
				-- sentinel is cleanup evidence, never publication authority.
				if not owner.partial.pid then
					local pid_str = out:match("__DLPID__:(%d+)")
					if pid_str then
						owner.partial.pid = tonumber(pid_str)
						if persist_owned_pid() ~= true then
							if operation_closed or owner.revoked then schedule_pid_cleanup()
							else do_cancel(true, "session_pid_write_failed") end
							return false
						end
					end
				end
				if operation_closed or owner.revoked
					or owner.attempt_generation ~= attempt_generation then
					if owner.partial.pid then schedule_pid_cleanup() end
					return false
				end
				if not still_current() then
					do_cancel(true, "stale")
					return false
				end
				-- Strip the sentinel line before forwarding to the download window log
				local clean = out:gsub("__DLPID__:%d+\n?", "")
				return process_stream(clean) ~= false
			end)

			if launcher_task then
				if not current_or_cancel() then return false end
				owner.tasks.launcher = launcher_task
				if deps.active_tasks then deps.active_tasks["download"] = launcher_task end
				local started = TaskLifecycle.start(launcher_task, "MLX detached download launcher")
				launcher_starting = false
				if started ~= true then
					signal_task(launcher_task, "MLX detached download launcher")
					local task_settled = pending_launcher_completion ~= nil
						or task_proven_stopped(launcher_task,
							"MLX detached download launcher")
					if task_settled then
						if deps.active_tasks and deps.active_tasks["download"] == launcher_task then
							deps.active_tasks["download"] = nil
						end
						owner.tasks.launcher = nil
					end
					update_icon("MLX launcher-refusal icon reset")
					if download_window then pcall(download_window.complete, false, target_model) end
					pcall(notifications.notify, i18n.get("mlx.launcher_failed"),
						string.format(i18n.get("mlx.launcher_failed_body"), -1), "error")
					do_cancel(true, "launcher_start_refused")
					return false
				end
				if pending_launcher_completion ~= nil then
					local completion_result = finish_launcher(
						table.unpack(pending_launcher_completion, 1,
							pending_launcher_completion.n))
					if completion_result == false then return false end
				end
				if not still_current() then
					do_cancel(true, "stale")
					return false
				end
			else
				update_icon("MLX launcher-construction icon reset")
				if download_window then pcall(download_window.complete, false, target_model) end
				pcall(notifications.notify, i18n.get("mlx.launcher_failed"),
					string.format(i18n.get("mlx.launcher_failed_body"), -1), "error")
				launcher_starting = false
				do_cancel(true, "launcher_construction_failed")
				return false
			end
			return true
		end

		-- Dependencies are pinned in pyproject.toml and provisioned by
		-- ensure-mlx-deps.sh on Hammerspoon startup; no runtime upgrade path.
		return _internal_pull()
	end

	--- Reattaches the download UI and log tail to an already-running detached Python download.
	--- Called after a Hammerspoon reload when /tmp/hs_mlx_active_download.json exists.
	--- @param session table Decoded JSON session: { model, log_path, exit_path, pid, repo }.
	function obj.reattach_download(session)
		if type(session) ~= "table" then return false end
		local model     = session.model     or "?"
		local log_path  = session.log_path  or ""
		local exit_path = session.exit_path or ""
		local pid       = tonumber(session.pid)
		local session_file = "/tmp/hs_mlx_active_download.json"

		if download_owner ~= nil then
			Logger.warn(LOG, "Cannot reattach '%s': another MLX download owner is active.",
				tostring(model))
			return false
		end
		download_generation = download_generation + 1
		local owner = {
			active = true,
			generation = download_generation,
			attempt_generation = 1,
			tasks = { launcher = nil, tail = nil },
			timers = {},
			partial = { pid = pid, log_path = log_path, exit_path = exit_path },
			registered = true,
			revoked = false,
			terminal_sent = false,
			session_published = true,
		}
		download_owner = owner
		if deps.active_tasks then deps.active_tasks["download_tail"] = owner end
		owner.on_release = function()
			if deps.active_tasks and (deps.active_tasks["download_tail"] == owner
				or deps.active_tasks["download_tail"] == owner.tasks.tail) then
				deps.active_tasks["download_tail"] = nil
			end
		end

		owner.remove_session = function()
			if owner.session_published ~= true then return true end
			local ok, removed = Logger.callback(LOG,
				"MLX reattached session removal", os.remove, session_file)
			if ok ~= true or removed == false or removed == nil then return false end
			owner.session_published = false
			return true
		end

		Logger.start(LOG, "Reattaching download UI for '%s' (PID %s)…", model, tostring(pid))
		update_icon("MLX reattach initial icon", "📥 …")

		-- Byte accounting, as UPVALUES. These used to be declared inside the
		-- per-chunk handler below, so every chunk reset them: nothing accumulated and
		-- the total stayed 0 for the whole download, which is why a reattached
		-- download showed neither a total nor an ETA. Declared above the closure so it
		-- captures them - a local below would bind the nil global.
		local _bytes_done, _current_pct = 0, 0
		local _python_file_count = nil

		-- The denominator, from the same preset field the launcher path reads. Without
		-- it there is nothing to compute a percentage or an ETA against.
		local _bytes_total = 0
		for _, provider in ipairs(presets) do
			for _, family in ipairs(provider.families or {}) do
				for _, m in ipairs(family.models or {}) do
					if m.name == model then
						local hw = m.hardware_requirements and m.hardware_requirements.mlx or {}
						if type(hw.download_gb) == "number" then
							_bytes_total = math.floor(hw.download_gb * 1e9)
						elseif type(hw.ram_gb) == "number" then
							_bytes_total = math.floor(hw.ram_gb * 0.14 * 1e9)
						end
						break
					end
				end
			end
		end

		local function signal_tail()
			local task = owner.tasks.tail
			if task == nil then return true end
			if type(task.terminate) ~= "function" then return false end
			local ok, result = Logger.callback(LOG,
				"MLX reattached tail cancellation", function() return task:terminate() end)
			return ok == true and result ~= false and result ~= nil
		end

		local function reattached_tail_proven_stopped(task)
			local method_ok, method = pcall(function() return task and task.isRunning end)
			if not method_ok or type(method) ~= "function" then return false end
			local ok, running = Logger.callback(LOG,
				"MLX reattached tail running-state probe", method, task)
			return ok == true and running == false
		end

		local function probe_exit_file(read_code)
			local ok_open, handle = Logger.callback(LOG,
				"MLX reattached exit-file probe", io.open, exit_path, "r")
			if ok_open ~= true then return nil, "probe_failed" end
			if not handle then return false end
			local raw = nil
			local ok_read = true
			if read_code then
				ok_read, raw = Logger.callback(LOG, "MLX reattached exit-code read", function()
					return handle:read("*l")
				end)
			end
			local ok_close, closed = Logger.callback(LOG,
				"MLX reattached exit-file close", function() return handle:close() end)
			if ok_read ~= true or (read_code and type(raw) ~= "string")
				or ok_close ~= true or closed == false or closed == nil then
				return nil, "read_failed"
			end
			return true, read_code and (tonumber(raw) or 1) or nil
		end

		local function settle_reattached(success, reason, silent)
			if owner.terminal_sent then return false end
			owner.terminal_sent = true
			cancel_owner_timer(owner, "poll")
			cancel_owner_timer(owner, "tail_done")
			update_icon("MLX reattach completion icon reset")
			if not silent then
				if success then
					pcall(notifications.notify, i18n.get("mlx.model_installed"),
						string.format(i18n.get("mlx.model_ready"), model), "success")
					if download_window then pcall(download_window.complete, true, model) end
				elseif reason == "user_cancelled" then
					pcall(notifications.notify, i18n.get("mlx.download_cancelled"),
						string.format(i18n.get("mlx.download_cancelled_body"), model), "warning")
					if download_window then pcall(download_window.complete, false, model) end
				elseif reason == "process_missing" then
					pcall(notifications.notify, i18n.get("mlx.download_interrupted"),
						string.format(i18n.get("mlx.download_interrupted_body"), model), "error")
					if download_window then pcall(download_window.complete, false, model) end
				else
					if download_window then pcall(download_window.complete, false, model) end
					pcall(notifications.notify, i18n.get("mlx.download_failed"),
						i18n.get("mlx.download_failed_body"), "error")
				end
			end
			release_download_owner(owner)
			return success == true
		end

		local cleanup_reattached
		local function schedule_reattached_cleanup()
			if owner.timers.cleanup ~= nil then return true end
			return schedule_owner_timer(owner, "cleanup", 0.25, cleanup_reattached)
		end

		cleanup_reattached = function()
			if owner.tasks.tail then signal_tail() end
			local live_pid = owner.partial.pid
			if live_pid then
				local ok_probe, alive = Logger.callback(LOG,
					"MLX reattached PID cleanup probe", os.execute,
					"kill -0 " .. tostring(live_pid) .. " 2>/dev/null")
				if not ok_probe then return schedule_reattached_cleanup() end
				if alive == true or alive == 0 then
					Logger.callback(LOG, "MLX reattached PID cleanup signal", os.execute,
						"kill -TERM " .. tostring(live_pid) .. " 2>/dev/null")
					return schedule_reattached_cleanup()
				end
				owner.partial.pid = nil
			else
				local exists = probe_exit_file(false)
				if exists == nil then return schedule_reattached_cleanup() end
				if exists ~= true then return schedule_reattached_cleanup() end
			end
			if owner.tasks.tail ~= nil then return schedule_reattached_cleanup() end
			if owner.remove_session() ~= true then return schedule_reattached_cleanup() end
			if owner.retry_pending then
				local repo = session.repo or ""
				if repo == "" then
					owner.retry_pending = false
					owner.keep_registered = false
					settle_reattached(false, "retry_unavailable", false)
					return false
				end
				owner.retry_pending = false
				owner.keep_registered = false
				if release_download_owner(owner) ~= true then return schedule_reattached_cleanup() end
				return obj.pull_model(model, repo, nil, nil) ~= false
			end
			release_download_owner(owner)
			return true
		end
		owner.retry_cleanup = cleanup_reattached

		local function do_cancel_reattached(silent, reason)
			local retrying = reason == "retry"
			if owner.revoked then
				if retrying then return false end
				if owner.retry_pending then
					owner.retry_pending = false
					owner.keep_registered = false
					settle_reattached(false, reason or "user_cancelled", silent)
					cleanup_reattached()
					return true
				end
				return false
			end
			owner.revoked = true
			owner.retry_pending = retrying
			owner.keep_registered = retrying
			cancel_owner_timers(owner)
			signal_tail()
			if owner.partial.pid then
				Logger.callback(LOG, "MLX reattached cancellation signal", os.execute,
					"kill -TERM " .. tostring(owner.partial.pid) .. " 2>/dev/null")
			end
			if not retrying then
				settle_reattached(false, reason or "user_cancelled", silent)
			end
			if owner_has_native_work(owner) then schedule_reattached_cleanup()
			else cleanup_reattached() end
			return true
		end
		owner.cancel = do_cancel_reattached

		local function handle_done_reattached()
			if owner.completion_seen or owner.revoked then return false end
			local exists, exit_code = probe_exit_file(true)
			if exists ~= true then
				if exists == nil then do_cancel_reattached(false, "exit_file_read_failed") end
				return false
			end
			owner.completion_seen = true
			owner.partial.pid = nil
			cancel_owner_timer(owner, "poll")
			cancel_owner_timer(owner, "tail_done")
			signal_tail()
			Logger.callback(LOG, "MLX reattached exit-file removal", os.remove, exit_path)
			owner.remove_session()
			local success = exit_code == 0
			settle_reattached(success, success and nil or "process_failed", false)
			Logger.info(LOG, "Reattach: download finished (exit=%d).", exit_code)
			return success
		end

		local function process_stream_reattached(out)
			if owner.revoked or owner.terminal_sent then return false end
			if not out or out == "" then return true end
			local max_bytes = 0
			for b_str in out:gmatch("__BYTES__:(%d+)") do
				local b = tonumber(b_str)
				if b and b > max_bytes then max_bytes = b end
			end
			-- Monotonic: the size watcher reports the total written so far, and a chunk
			-- that happens to carry an older figure must not walk the bar backwards.
			if max_bytes > _bytes_done then _bytes_done = max_bytes end
			for fc_str in out:gmatch("__FILECOUNT__:(%d+)") do
				local fc = tonumber(fc_str)
				if fc and fc > 0 then _python_file_count = fc end
			end

			-- From the accumulated bytes over the estimated total, exactly as the
			-- launcher path does. It used to be scraped out of the tool's own output
			-- with out:match("(%d+)%%"), which is the progress of the file currently
			-- being fetched and not of the download: a model with eight shards showed
			-- the bar climb to 99% and snap back to 0, eight times over.
			if _bytes_total > 0 and _bytes_done > 0 then
				_current_pct = math.floor((_bytes_done / _bytes_total) * 100 + 0.5)
			end
			-- Capped at 99: only the exit code may declare completion.
			_current_pct = math.min(math.max(0, _current_pct), 99)

			if _current_pct > 0 then
				update_icon("MLX reattach progress icon", "📥 " .. _current_pct .. "%")
			end
			if download_window then
				pcall(download_window.update, _current_pct, _bytes_done, _bytes_total, out, _python_file_count)
			end
			return true
		end

		-- Completion may already have happened between startup session discovery and
		-- owner registration. The same terminal path handles that case.
		local finished, finish_detail = probe_exit_file(false)
		if finished == nil then
			do_cancel_reattached(false, finish_detail)
			return false
		end
		if finished == true then return handle_done_reattached() end

		if owner.partial.pid then
			local ok_probe, alive = Logger.callback(LOG,
				"MLX reattached PID liveness probe", os.execute,
				"kill -0 " .. tostring(owner.partial.pid) .. " 2>/dev/null")
			if not ok_probe then
				do_cancel_reattached(false, "pid_probe_failed")
				return false
			end
			if alive ~= true and alive ~= 0 then
				owner.partial.pid = nil
				settle_reattached(false, "process_missing", false)
				owner.remove_session()
				release_download_owner(owner)
				return false
			end
		end

		local function poll_exit_reattached()
			if owner.revoked or owner.terminal_sent then return false end
			local exists = probe_exit_file(false)
			if exists == nil then
				do_cancel_reattached(false, "exit_file_probe_failed")
				return false
			end
			if exists == true then return handle_done_reattached() end
			if not schedule_owner_timer(owner, "poll", 3, poll_exit_reattached) then
				do_cancel_reattached(false, "poll_timer_refused")
				return false
			end
			return true
		end
		if not schedule_owner_timer(owner, "poll", 3, poll_exit_reattached) then
			do_cancel_reattached(false, "poll_timer_refused")
			return false
		end

		-- Open (or re-focus) the download window
		if download_window then
			pcall(download_window.show, {
				kind = "mlx_model",
				model = model,
				terminal_cmd = "tail -f " .. log_path,
				on_cancel = do_cancel_reattached,
				on_retry = function()
					if owner.retry_pending or owner.terminal_sent then return false end
					return do_cancel_reattached(true, "retry")
				end,
			})
		end

		-- Start a new tail -f on the existing log file
		local tail_task
		local tail_starting = true
		local pending_tail_completion = false
		local function finish_tail()
			if owner.tasks.tail ~= tail_task then return false end
			owner.tasks.tail = nil
			if deps.active_tasks and deps.active_tasks["download_tail"] == tail_task then
				deps.active_tasks["download_tail"] = owner
			end
			if owner.revoked then
				cleanup_reattached()
				return false
			end
			-- Completion can settle while terminate() is still retiring the tail.
			-- Once that exact task reports done, release the already-terminal owner;
			-- scheduling another completion probe would only rediscover
			-- completion_seen and leave the shared slot pinned forever.
			if owner.completion_seen or owner.terminal_sent then
				release_download_owner(owner)
				return true
			end
			if not schedule_owner_timer(owner, "tail_done", 0.5, handle_done_reattached) then
				return poll_exit_reattached()
			end
			return true
		end

		tail_task = TaskLifecycle.native("MLX reattached download log tail", "/usr/bin/tail", function()
			if tail_starting then
				pending_tail_completion = true
				return true
			end
			return finish_tail()
		end, function(_, stdout, stderr)
			return process_stream_reattached((stdout or "") .. (stderr or "")) ~= false
		end, {"-F", "-n", "+1", log_path})

		if tail_task then
			owner.tasks.tail = tail_task
			if deps.active_tasks then deps.active_tasks["download_tail"] = tail_task end
			local started = TaskLifecycle.start(tail_task, "MLX reattached download log tail")
			tail_starting = false
			if started ~= true then
				signal_tail()
				if pending_tail_completion or reattached_tail_proven_stopped(tail_task) then
					owner.tasks.tail = nil
				end
				-- Keep the logical monitor sentinel: the exit-file poll remains the
				-- reliable completion backstop even when streaming cannot start.
				if deps.active_tasks and owner.tasks.tail == nil then
					deps.active_tasks["download_tail"] = owner
				end
			elseif pending_tail_completion then
				finish_tail()
			end
		else
			tail_starting = false
		end

		Logger.success(LOG, "Reattached download tail for '%s'.", model)
		return true
	end
end

return M
