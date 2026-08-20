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

	local function save_prefs(label)
		local ok, saved = Logger.callback(LOG, label, deps.save_prefs)
		return ok == true and saved == true
	end

	function obj.pull_model(target_model, repo, on_success)
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
		if deps.active_tasks
			and (deps.active_tasks["download"] or deps.active_tasks["download_tail"]) then
			Logger.warn(LOG, "A model download is already running — ignoring the request for '%s'.",
				tostring(target_model))
			-- Surface the download already in progress rather than failing silently:
			-- from the user's side the click simply did nothing otherwise.
			if download_window and type(download_window.show) == "function" then
				pcall(download_window.show)
			end
			return
		end

		local function _internal_pull()
			-- Upvalues shared between closures so do_cancel/tail can coordinate
			local _dl_pid    = nil
			local _tail_task = nil
			local _rand_id   = tostring(math.random(1000, 9999))
			local _log_path  = "/tmp/hs_mlx_dl_" .. _rand_id .. ".log"
			local _exit_path = _log_path .. ".exit"

			-- silent=true suppresses the "Annulé" notification and complete() so callers that
			-- already handle their own UI (do_retry, check_timeout) don't double-notify
			local function do_cancel(silent)
				if _tail_task then
					pcall(function() _tail_task:terminate() end)
					_tail_task = nil
				end
				if _dl_pid then
					-- Kill the detached Python process directly — hs.task:terminate() would not reach
					-- it because Python called os.setpgrp() to escape Hammerspoon's process group
					os.execute("kill -TERM " .. tostring(_dl_pid) .. " 2>/dev/null")
					_dl_pid = nil
				end
				if deps.active_tasks then
					deps.active_tasks["download"]      = nil
					deps.active_tasks["download_tail"] = nil
				end
				-- Always reset the menubar % — the poll/handle_done path won't run after a cancel
				update_icon("MLX download cancellation icon reset")
				os.execute("rm -f /tmp/hs_mlx_active_download.json 2>/dev/null")
				if not silent then
					pcall(notifications.notify, i18n.get("mlx.download_cancelled"), string.format(i18n.get("mlx.download_cancelled_body"), target_model), "warning")
					if download_window then pcall(download_window.complete, false, target_model) end
				end
			end

			local function do_retry()
				-- Pass silent=true: do_retry manages its own lifecycle, no cancel notification needed
				do_cancel(true)
				hs.timer.doAfter(0.05, function()
					obj.pull_model(target_model, repo, on_success)
				end)
			end

			local function do_resolve_gated()
				if type(obj.prompt_hf_login) == "function" then
					hs.timer.doAfter(0.08, function()
						obj.prompt_hf_login(function(ok)
							if ok and type(do_retry) == "function" then
								hs.timer.doAfter(0.3, do_retry)
							end
						end)
					end)
				end
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
			local py = io.open(py_path, "w")
			if not py then
				pcall(notifications.notify, i18n.get("mlx.write_py_failed"), nil, "error")
				return
			end
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
			py:close()

			-- Write the launcher: resolves Python binary, installs deps, cleans stale cache,
			-- then starts Python detached via nohup (shields SIGHUP) and reports its PID
			local f = io.open(script_path, "w")
			if not f then
				pcall(notifications.notify, i18n.get("mlx.write_sh_failed"), nil, "error")
				return
			end
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
			f:close()

			os.execute("chmod +x " .. script_path)

			-- Persist session so a future HS reload can reattach tail -f without restarting the download
			local _session_json = string.format(
				"{\"model\":\"%s\",\"log_path\":\"%s\",\"exit_path\":\"%s\",\"repo\":\"%s\"}",
				target_model, _log_path, _exit_path, clean_repo
			)
			local _sf = io.open("/tmp/hs_mlx_active_download.json", "w")
			if _sf then _sf:write(_session_json); _sf:close() end

			if download_window then
				-- terminal_cmd points to the live log so the "Terminal" button shows real Python output
				pcall(download_window.show, {
					kind = "mlx_model",
					model = target_model,
					terminal_cmd = "tail -f " .. _log_path,
					on_cancel = do_cancel,
					on_resolve = do_resolve_gated,
					on_retry = do_retry,
				})
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
				-- Guard on _dl_pid rather than active_tasks: the task slot is transient for the
				-- short-lived launcher, but _dl_pid persists for the entire Python process lifetime
				if _dl_pid then
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
						do_cancel(true)
					else
						hs.timer.doAfter(30, check_timeout)
					end
				end
			end

			-- Shared stream processor used by both the launcher stdout and the tail task
			local function process_stream(out)
				if not out or out == "" then return end
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
				if _tail_task then
					pcall(function() _tail_task:terminate() end)
					_tail_task = nil
				end
				_dl_pid = nil
				if deps.active_tasks then
					deps.active_tasks["download"]      = nil
					deps.active_tasks["download_tail"] = nil
				end
				update_icon("MLX download completion icon reset")
				os.execute("rm -f /tmp/hs_mlx_active_download.json 2>/dev/null")

				-- Flush any remaining buffered output before showing final status
				if _stream_tail ~= "" and download_window then
					pcall(download_window.update, _current_pct, _bytes_done, _bytes_total, _stream_tail, _python_file_count)
					_stream_tail = ""
				end

				-- Read exit code written by Python atexit handler
				local exit_code = 1
				local ef = io.open(_exit_path, "r")
				if ef then
					local raw = ef:read("*l")
					ef:close()
					exit_code = tonumber(raw) or 1
					os.execute("rm -f " .. _exit_path .. " 2>/dev/null")
				end

				if exit_code == 0 then
					pcall(notifications.notify, i18n.get("mlx.model_installed"), string.format(i18n.get("mlx.model_ready"), target_model), "success")
					if download_window then pcall(download_window.complete, true, target_model) end
					deps.state.llm_model = target_model
						invalidate_installed_cache()
					if deps.keymap and type(deps.keymap.set_llm_model) == "function" then
						Logger.callback(LOG, "MLX downloaded-model runtime sync",
							deps.keymap.set_llm_model, target_model)
					end
					if not save_prefs("MLX downloaded-model preference save") then return false end
					obj.start_server(target_model, function()
						if type(on_success) == "function" then
							Logger.callback(LOG, "MLX download success", on_success)
						end
					end)
				else
					if download_window then pcall(download_window.complete, false, target_model, _saw_gated_error and "gated" or nil) end
					pcall(notifications.notify, i18n.get("mlx.download_failed"), i18n.get("mlx.download_failed_body"), "error")
				end
			end

			-- Starts a tail -f task that streams the Python log file back to Lua in real time;
			-- also polls the exit file every 3 s to catch completion reliably
			local function start_tail_monitor()
				_tail_task = TaskLifecycle.native("MLX download log tail", "/usr/bin/tail", function()
					-- Tail exited (killed by do_cancel or process gone) — check exit file
					hs.timer.doAfter(0.5, function()
						local ef = io.open(_exit_path, "r")
						if ef then ef:close(); handle_download_done() end
					end)
				end, function(_, stdout, stderr)
					process_stream((stdout or "") .. (stderr or ""))
					return true
				end, {"-F", "-n", "+1", _log_path})

				if _tail_task then
					if deps.active_tasks then deps.active_tasks["download_tail"] = _tail_task end
					if not TaskLifecycle.start(_tail_task, "MLX download log tail") then
						if deps.active_tasks then deps.active_tasks["download_tail"] = nil end
						_tail_task = nil
					end
				end

				-- Periodic poll: tail can miss the very last flush before Python exits
				local function poll_exit()
					if not _dl_pid then return end
					local ef = io.open(_exit_path, "r")
					if ef then ef:close(); handle_download_done()
					else hs.timer.doAfter(3, poll_exit) end
				end
				hs.timer.doAfter(3, poll_exit)
				hs.timer.doAfter(30, check_timeout)
			end

			-- Short-lived launcher: resolves Python, installs deps, cleans stale cache, then
			-- exits after spawning the detached Python process and printing its PID
			local launcher_task = TaskLifecycle.native("MLX detached download launcher", script_path, function(code, stdout, stderr)
				if deps.active_tasks then deps.active_tasks["download"] = nil end
				-- stdout/stderr are empty when a streaming callback is active — _dl_pid was already
				-- set by the streaming callback which received the __DLPID__ sentinel
				if not _dl_pid or code ~= 0 then
					-- Reset icon here: handle_download_done will not run after a launcher failure
					update_icon("MLX launcher-failure icon reset")
					if download_window then pcall(download_window.complete, false, target_model) end
					pcall(notifications.notify, i18n.get("mlx.launcher_failed"), string.format(i18n.get("mlx.launcher_failed_body"), code), "error")
					return
				end
				start_tail_monitor()
			end, function(_, stdout, stderr)
				local out = (stdout or "") .. (stderr or "")
				-- Parse __DLPID__ here — completion callback gets empty strings when streaming is active
				if not _dl_pid then
					local pid_str = out:match("__DLPID__:(%d+)")
					if pid_str then
						_dl_pid = tonumber(pid_str)
						-- Persist PID so a post-reload reattach can check liveness and cancel cleanly
						local sf = io.open("/tmp/hs_mlx_active_download.json", "r")
						if sf then
							local raw = sf:read("*a"); sf:close()
							local ok_j, sess = pcall(hs.json.decode, raw)
							if ok_j and type(sess) == "table" then
								sess.pid = _dl_pid
								local ok_e, enc = pcall(hs.json.encode, sess)
								if ok_e and enc then
									local wf = io.open("/tmp/hs_mlx_active_download.json", "w")
									if wf then wf:write(enc); wf:close() end
								end
							end
						end
					end
				end
				-- Strip the sentinel line before forwarding to the download window log
				local clean = out:gsub("__DLPID__:%d+\n?", "")
				process_stream(clean)
				return true
			end)

			if launcher_task then
				if deps.active_tasks then deps.active_tasks["download"] = launcher_task end
				if not TaskLifecycle.start(launcher_task, "MLX detached download launcher") then
					if deps.active_tasks then deps.active_tasks["download"] = nil end
					update_icon("MLX launcher-refusal icon reset")
					if download_window then pcall(download_window.complete, false, target_model) end
					pcall(notifications.notify, i18n.get("mlx.launcher_failed"),
						string.format(i18n.get("mlx.launcher_failed_body"), -1), "error")
				end
			else
				update_icon("MLX launcher-construction icon reset")
				if download_window then pcall(download_window.complete, false, target_model) end
				pcall(notifications.notify, i18n.get("mlx.launcher_failed"),
					string.format(i18n.get("mlx.launcher_failed_body"), -1), "error")
			end
		end

		-- Dependencies are pinned in pyproject.toml and provisioned by
		-- ensure-mlx-deps.sh on Hammerspoon startup; no runtime upgrade path.
		_internal_pull()
	end

	--- Reattaches the download UI and log tail to an already-running detached Python download.
	--- Called after a Hammerspoon reload when /tmp/hs_mlx_active_download.json exists.
	--- @param session table Decoded JSON session: { model, log_path, exit_path, pid, repo }.
	function obj.reattach_download(session)
		local model     = session.model     or "?"
		local log_path  = session.log_path  or ""
		local exit_path = session.exit_path or ""
		local pid       = session.pid

		Logger.start(LOG, "Reattaching download UI for '%s' (PID %s)…", model, tostring(pid))

		-- Check whether the download finished during the reload window
		local ef = io.open(exit_path, "r")
		if ef then
			local raw = ef:read("*l"); ef:close()
			local code = tonumber(raw) or 1
			os.execute("rm -f " .. exit_path .. " 2>/dev/null")
			os.execute("rm -f /tmp/hs_mlx_active_download.json 2>/dev/null")
			if code == 0 then
				pcall(notifications.notify, i18n.get("mlx.model_installed"), string.format(i18n.get("mlx.model_ready"), model), "success")
			else
				pcall(notifications.notify, i18n.get("mlx.download_failed"), string.format(i18n.get("mlx.download_interrupted_body"), model), "error")
			end
			Logger.info(LOG, "Reattach: download already finished (exit=%d) — no tail needed.", code)
			return
		end

		-- Check liveness via kill -0 (no signal sent, just checks if PID exists)
		if pid then
			local alive = os.execute("kill -0 " .. tostring(pid) .. " 2>/dev/null")
			if not alive then
				os.execute("rm -f /tmp/hs_mlx_active_download.json 2>/dev/null")
				pcall(notifications.notify, i18n.get("mlx.download_interrupted"), string.format(i18n.get("mlx.download_interrupted_body"), model), "error")
				Logger.warn(LOG, "Reattach: PID %d no longer alive — aborting reattach.", pid)
				return
			end
		end

		-- Re-register in active_tasks so the menu item and icon stay active
		if deps.active_tasks then deps.active_tasks["download_tail"] = true end
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

		local _tail_task = nil

		local function do_cancel_reattached(silent)
			if _tail_task then pcall(function() _tail_task:terminate() end); _tail_task = nil end
			if pid then os.execute("kill -TERM " .. tostring(pid) .. " 2>/dev/null") end
			if deps.active_tasks then
				deps.active_tasks["download"]      = nil
				deps.active_tasks["download_tail"] = nil
			end
			update_icon("MLX reattach cancellation icon reset")
			os.execute("rm -f /tmp/hs_mlx_active_download.json 2>/dev/null")
			if not silent then
				pcall(notifications.notify, i18n.get("mlx.download_cancelled"), string.format(i18n.get("mlx.download_cancelled_body"), model), "warning")
				if download_window then pcall(download_window.complete, false, model) end
			end
		end

		local function handle_done_reattached()
			if deps.active_tasks then
				deps.active_tasks["download"]      = nil
				deps.active_tasks["download_tail"] = nil
			end
			update_icon("MLX reattach completion icon reset")
			os.execute("rm -f /tmp/hs_mlx_active_download.json 2>/dev/null")
			local ef2 = io.open(exit_path, "r")
			local exit_code = 1
			if ef2 then
				local raw = ef2:read("*l"); ef2:close()
				exit_code = tonumber(raw) or 1
				os.execute("rm -f " .. exit_path .. " 2>/dev/null")
			end
			if exit_code == 0 then
				pcall(notifications.notify, i18n.get("mlx.model_installed"), string.format(i18n.get("mlx.model_ready"), model), "success")
				if download_window then pcall(download_window.complete, true, model) end
				if not save_prefs("MLX reattached-model preference save") then return false end
			else
				if download_window then pcall(download_window.complete, false, model) end
				pcall(notifications.notify, i18n.get("mlx.download_failed"), i18n.get("mlx.download_failed_body"), "error")
			end
		end

		local function process_stream_reattached(out)
			if not out or out == "" then return end
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
		end

		-- Open (or re-focus) the download window
		if download_window then
			pcall(download_window.show, {
				kind = "mlx_model",
				model = model,
				terminal_cmd = "tail -f " .. log_path,
				on_cancel = do_cancel_reattached,
				on_retry = function()
					do_cancel_reattached(true)
					hs.timer.doAfter(0.05, function()
						local repo = session.repo or ""
						if repo ~= "" then obj.pull_model(model, repo, nil) end
					end)
				end,
			})
		end

		-- Start a new tail -f on the existing log file
		_tail_task = TaskLifecycle.native("MLX reattached download log tail", "/usr/bin/tail", function()
			hs.timer.doAfter(0.5, function()
				local ef3 = io.open(exit_path, "r")
				if ef3 then ef3:close(); handle_done_reattached() end
			end)
		end, function(_, stdout, stderr)
			process_stream_reattached((stdout or "") .. (stderr or ""))
			return true
		end, {"-F", "-n", "+1", log_path})

		if _tail_task then
			deps.active_tasks["download_tail"] = _tail_task
			if not TaskLifecycle.start(_tail_task, "MLX reattached download log tail") then
				_tail_task = nil
				-- Keep the logical monitor sentinel: the exit-file poll remains the
				-- reliable completion backstop even when streaming cannot start.
				deps.active_tasks["download_tail"] = true
			end
		end

		-- Poll for exit file in case tail misses the final flush
		local function poll_exit_reattached()
			if not (deps.active_tasks and deps.active_tasks["download_tail"]) then return end
			local ef4 = io.open(exit_path, "r")
			if ef4 then ef4:close(); handle_done_reattached()
			else hs.timer.doAfter(3, poll_exit_reattached) end
		end
		hs.timer.doAfter(3, poll_exit_reattached)

		Logger.success(LOG, "Reattached download tail for '%s'.", model)
	end
end

return M
