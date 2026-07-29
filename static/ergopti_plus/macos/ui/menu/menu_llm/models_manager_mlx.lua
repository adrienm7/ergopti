--- ui/menu/menu_llm/models_manager_mlx.lua

--- ==============================================================================
--- MODULE: MLX Models Manager
--- DESCRIPTION:
--- Handles all MLX specifics, server execution, requirements parsing, and downloads.
---
--- FEATURES & RATIONALE:
--- 1. Subprocess Handling: Spawns the huggingface cli cleanly.
--- 2. File Verification: Safely verifies tensors to guarantee cache integrity.
--- ==============================================================================

local M = {}
local hs            = hs
local notifications = require("lib.notifications")
local Logger = require("lib.logger")
local fs_dir       = require("lib.fs_dir")
local i18n = require("lib.i18n")

-- GC-root table: every live hs.task is pinned here so Lua's garbage collector
-- cannot SIGTERM it mid-run (hs.task held only in a local is collected on return).
M._active_tasks = {}

-- Optional dependency: the auto-bootstrap status lives in this module so we
-- can differentiate "still installing" from "definitively failed" when the
-- MLX import probe below fails. If the module is absent (unusual layout),
-- we fall back to the previous generic behaviour.
local ok_mlx_deps, mlx_deps_checker = pcall(require, "modules.llm.mlx_deps_checker")
if not ok_mlx_deps then mlx_deps_checker = nil end

local LOG = "menu_llm.mlx"

-- Needed so M.new can register the cross-session restart hook (set_restart_hook).
-- The server-launch port resolution and active-PID reporting now live in the
-- sibling models_manager_mlx_server module. A plain require (not pcall) because
-- api_mlx is the MLX backend's core module — if it cannot load, MLX predictions
-- are dead anyway, so failing fast is correct.
local ApiMlx = require("modules.llm.api_mlx")





-- =========================================
-- =========================================
-- ======= 1/ MLX Engine Core System =======
-- =========================================
-- =========================================

function M.new(deps, presets)
	local obj = {}
	deps.active_tasks = deps.active_tasks or {}
	obj._installed_cache = nil
	obj._installed_cache_ts = 0
	-- Installed-models scan cache TTL. The HF hub directory only changes on a
	-- download or delete (both invalidate the cache below), so the old 1 s TTL just
	-- wasted ~70-120 ms re-scanning the cache on nearly every menu open. 30 s
	-- matches the Ollama manager and keeps repeated opens off the filesystem.
	local INSTALLED_CACHE_TTL = 30
	local function invalidate_installed_cache() obj._installed_cache_ts = 0 end

	-- Register a restart hook so api_mlx can request a fresh launch when its
	-- discovery loop detects a model-ID mismatch it cannot resolve on its own
	-- (typically a cross-session leftover whose PGID was wrongly adopted as the
	-- active guard). The hook is invoked with the expected short model name.
	if type(ApiMlx) == "table" and type(ApiMlx.set_restart_hook) == "function" then
		ApiMlx.set_restart_hook(function(target)
			-- api_mlx passes _expected_model_id, which is the resolved backend ID
			-- (e.g. "Meta-Llama-3.1-8B-Instruct-4bit"). get_mlx_repo expects the
			-- menu label (e.g. "Llama-3.1-8B-Instruct"). When the resolved ID does
			-- not match any preset, fall back to obj._server_target — the label
			-- of the most recent successful start_server, which is exactly the
			-- server we are trying to restart.
			local resolved_repo = (type(target) == "string" and target ~= "") and obj.get_mlx_repo(target) or nil
			local effective_target = target
			if not resolved_repo and obj._server_target and obj._server_target ~= "" then
				Logger.warn(LOG, "Restart hook target '%s' has no repo — falling back to last server target '%s'.",
					tostring(target), tostring(obj._server_target))
				effective_target = obj._server_target
			end
			if type(effective_target) ~= "string" or effective_target == "" then
				Logger.warn(LOG, "Restart hook invoked without a usable target — ignoring.")
				return
			end
			Logger.warn(LOG, "Restart hook invoked for target='%s' — calling start_server.", effective_target)
			-- Force a fresh launch: clear server_target and the active task entry so
			-- start_server's reuse branch cannot short-circuit. The currently-tracked
			-- task is the one we just hard-killed (or about to); reusing it would
			-- mean returning success against a dead/wrong-model process.
			if deps.active_tasks and deps.active_tasks["mlx_server"] then
				local existing = deps.active_tasks["mlx_server"]
				pcall(function() if type(existing.terminate) == "function" then existing:terminate() end end)
				deps.active_tasks["mlx_server"] = nil
			end
			obj._server_target = nil
			-- on_success / on_cancel are nil here: the prediction layer is already
			-- waiting on its own warmup retry loop and will pick up the new server
			-- automatically once the bash launcher emits the PGID line.
			pcall(obj.start_server, effective_target, nil, nil, { silent_notifications = true })
		end)
	end

	local module_source = debug.getinfo(1, "S").source:sub(2)
	local project_root = module_source:match("^(.*)/static/ergopti_plus/macos/ui/menu/menu_llm/models_manager_mlx%.lua$")
	-- Single, canonical Python interpreter for every Hammerspoon-driven MLX
	-- invocation. This venv is provisioned by modules/llm/ensure-mlx-deps.sh
	-- on first launch from the pinned pyproject.toml, so its absolute path is
	-- the only one we ever shell out to. Any consumer that hits a missing
	-- interpreter must fail fast — silent fallback to a system python would
	-- bypass the pinned mlx-lm version and reintroduce the very drift we are
	-- trying to eliminate.
	local hs_root = project_root and (project_root .. "/static/ergopti_plus/macos") or ""
	local project_venv_python = hs_root ~= "" and (hs_root .. "/.venv/bin/python") or ""

	-- When the Swift launcher is running (ERGOPTI_CONFIG_DIR is set), the
	-- bundle is read-only and ensure-mlx-deps.sh redirected the venv to
	-- ~/Library/Application Support/Ergopti/mlx-venv (same logic as the
	-- shell script). Override the computed in-bundle path accordingly.
	local _ergopti_config_dir = os.getenv("ERGOPTI_CONFIG_DIR")
	if _ergopti_config_dir and _ergopti_config_dir ~= "" then
		local home = os.getenv("HOME") or ""
		if home ~= "" then
			project_venv_python = home .. "/Library/Application Support/Ergopti/mlx-venv/bin/python"
		end
	end

	if project_venv_python == "" or not hs.fs.attributes(project_venv_python, "mode") then
		-- The auto-bootstrap (modules/llm/mlx_deps_checker) provisions this interpreter
		-- on every reload; if it is still missing here the bootstrap failed and
		-- the user has already been notified.
		Logger.warn(LOG, "Project venv python introuvable à %s — bootstrap auto en échec.",
			tostring(project_venv_python))
	end
	local project_venv_python_escaped = project_venv_python:gsub("\\", "\\\\"):gsub("\"", "\\\"")

	-- HuggingFace auth + model-source helpers (get_mlx_repo, open_model_source_page,
	-- prompt_hf_login, _process_hf_token) are attached onto obj here. They share only
	-- obj/deps/presets, so they live in a sibling module to keep the catalogue/auth
	-- logic out of the server-lifecycle and download code below.
	require("ui.menu.menu_llm.models_manager_mlx_hf").install({ obj = obj, deps = deps, presets = presets })

	function obj.get_installed_models()
		local now = hs.timer.secondsSinceEpoch()
		if type(obj._installed_cache) == "table" and (now - (obj._installed_cache_ts or 0)) < INSTALLED_CACHE_TTL then
			return obj._installed_cache
		end

		local installed = {}
		local home = os.getenv("HOME")
		if not home then
			Logger.error(LOG, "get_installed_models: HOME env var not set — cannot scan MLX cache.")
			return installed
		end
		local hub_dir = home .. "/.cache/huggingface/hub/"
		Logger.debug(LOG, "Scanning MLX installed models cache…")
		for _, provider in ipairs(presets) do
			for _, family in ipairs(provider.families or {}) do
				for _, m in ipairs(family.models or {}) do
					if m.urls and m.urls.mlx then
						local raw_repo = m.urls.mlx:gsub("^https?://huggingface%.co/", "")
						local safe_repo = "models--" .. raw_repo:gsub("/", "--")
						local snapshots_dir = hub_dir .. safe_repo .. "/snapshots"
						local attr = hs.fs.attributes(snapshots_dir)
						if attr and attr.mode == "directory" then
							local is_valid = false
							for _, commit in ipairs(fs_dir.entries(snapshots_dir)) do
								if commit ~= "." and commit ~= ".." then
									local commit_dir = snapshots_dir .. "/" .. commit
									local attr_c = hs.fs.attributes(commit_dir)
									if attr_c and attr_c.mode == "directory" then
										for _, file in ipairs(fs_dir.entries(commit_dir)) do
											if file:match("%.safetensors$") or file:match("%.bin$") then
												local file_path = commit_dir .. "/" .. file
												local fattr = hs.fs.attributes(file_path)

												-- Hugging Face snapshots often expose large tensor weights as symlinks.
												-- Accept symlinked weights as valid to avoid false negatives at startup.
												if fattr and (fattr.mode == "link" or (fattr.size and fattr.size > 10000)) then
													is_valid = true
													break
												end
											end
										end
									end
								end
								if is_valid then break end
							end
							if is_valid then
								installed[m.name] = true
								Logger.debug(LOG, "MLX model detected in cache: %s", tostring(m.name))
							end
						end
					end
				end
			end
		end
		local count = 0
		for _ in pairs(installed) do count = count + 1 end
		obj._installed_cache = installed
		obj._installed_cache_ts = now
		Logger.debug(LOG, "MLX installed models scan complete: %d model(s).", count)
		return installed
	end

	-- MLX server-launch lifecycle (obj.start_server): cross-session adoption,
	-- defensive port sweeps, the detached bash launcher, readiness probing, and
	-- crash auto-recovery. It shares obj/deps/the pinned interpreter and the
	-- canonical M._active_tasks GC root, so it lives in a sibling module to keep
	-- this ~570-line lifecycle out of the catalogue/download code below.
	require("ui.menu.menu_llm.models_manager_mlx_server").install({
		obj                         = obj,
		deps                        = deps,
		project_venv_python_escaped = project_venv_python_escaped,
		active_tasks_gc_root        = M._active_tasks,
	})

	-- Model download (obj.pull_model) + post-reload reattach (obj.reattach_download).
	-- Shares obj/deps/presets/the pinned interpreter and the parent's installed-cache
	-- invalidator, so the ~600-line downloader lives in its own sibling module.
	require("ui.menu.menu_llm.models_manager_mlx_download").install({
		obj                         = obj,
		deps                        = deps,
		presets                     = presets,
		project_venv_python_escaped = project_venv_python_escaped,
		invalidate_installed_cache  = invalidate_installed_cache,
	})





	-- =====================================
	-- =====================================
	-- ======= 2/ Dependency Parsing =======
	-- =====================================
	-- =====================================

	function obj.check_requirements(target_model, on_success, on_cancel, opts)
		if not target_model or target_model == "" then 
			if type(on_success) == "function" then on_success() end
			return 
		end
		Logger.debug(LOG, "Checking MLX requirements for model %s…", tostring(target_model))

		local function do_check()
			local installed = obj.get_installed_models()
			if installed[target_model] then
				Logger.info(LOG, "MLX model %s is installed. Starting server…", tostring(target_model))
				obj.start_server(target_model, on_success, on_cancel, opts)
			else
				Logger.warn(LOG, "MLX model %s not detected as installed. Starting download flow…", tostring(target_model))
				local repo = obj.get_mlx_repo(target_model)
				if not repo then 
					pcall(notifications.notify, i18n.get("mlx.model_unavailable"), string.format(i18n.get("mlx.model_unavailable_body"), target_model), "error")
					if on_cancel then on_cancel() end 
					return 
				end
				
				if type(deps.shared_system_check) == "function" then
					deps.shared_system_check(target_model, "Apple MLX", repo, function()
						obj.pull_model(target_model, repo, on_success)
					end, on_cancel)
				else
					obj.pull_model(target_model, repo, on_success)
				end
			end
		end

		-- Verify the pinned project venv has every required MLX dependency
		-- importable. If it does not, the venv is broken / out of sync and the
		-- user must run modules/llm/ensure-mlx-deps.sh manually — silently
		-- pip-installing a fallback would bypass pyproject.toml.
		local check_cmd = "\"" .. project_venv_python_escaped .. "\" -c 'import mlx_lm; import huggingface_hub; import jinja2; import safetensors'"
		-- Forward-declared, pinned before start() and released as the callback's
		-- first act — the same three steps its sibling delete_task performs.
		-- Held only by a local, the task was collectable the moment this function
		-- returned, while the python import probe still had one to three seconds
		-- to run. A GC cycle in that window makes Hammerspoon SIGTERM the
		-- subprocess and the completion callback never fires: neither do_check nor
		-- on_cancel runs, and on_cancel is what releases the prediction lock that
		-- model_switcher and startup_controller set. Predictions then stay locked
		-- with no START-without-SUCCESS trail, and only a full reload recovers.
		local check_task
		check_task = hs.task.new("/bin/bash", function(code)
			if check_task then M._active_tasks[check_task] = nil end
			if code == 0 then
				do_check()
			else
				-- Differentiate three cases so the user sees the truth:
				--   1. bootstrap still running → "patientez", do not flip to error
				--   2. bootstrap failed        → show the actual stderr cause
				--   3. unknown                 → previous generic message
				if mlx_deps_checker and mlx_deps_checker.is_pending and mlx_deps_checker.is_pending() then
					Logger.info(LOG, "MLX import probe failed but bootstrap still pending — launching install.")
					-- Show the progress window and kick off the actual install.
					-- The checker is idempotent: if it is already running, the second
					-- call exits silently; if it was never started (e.g., LLM was
					-- disabled at startup), this is the first real launch.
					local llm_progress = require("ui.download_window")
					if not llm_progress.is_active() then
						pcall(llm_progress.show, {
							kind     = "mlx_install",
							title    = i18n.get("mlx.init_title"),
							subtitle = i18n.get("mlx.init_subtitle"),
						})
					end
					pcall(mlx_deps_checker.check_and_install_deps)
				elseif mlx_deps_checker and mlx_deps_checker.has_failed and mlx_deps_checker.has_failed() then
					local cause = (mlx_deps_checker.get_failure_message and mlx_deps_checker.get_failure_message())
						or "Cause inconnue. Consultez la console Hammerspoon."
					Logger.error(LOG, "MLX dependencies missing — bootstrap definitively failed: %s",
						tostring(cause):gsub("\n", " | "))
					pcall(notifications.notify, i18n.get("mlx.deps_missing"), cause, "error")
					-- F-LOW-10: the "failed" state used to be a permanent dead end —
					-- check_and_install_deps() short-circuited on it forever, so a
					-- transient (now-resolved) failure required a full HS reload to
					-- recover from. Reset back to "pending" so the NEXT attempt (the
					-- user retrying "install now" via this same check_requirements
					-- path) actually re-runs the bootstrap instead of hitting the
					-- same cached failure again.
					if mlx_deps_checker.reset_bootstrap_state then
						pcall(mlx_deps_checker.reset_bootstrap_state)
					end
				else
					Logger.error(LOG, "MLX dependencies missing in %s — auto-bootstrap may have failed.", project_venv_python_escaped)
					pcall(notifications.notify, i18n.get("mlx.deps_missing"),
						i18n.get("mlx.deps_missing_body"), "error")
				end
				if on_cancel then pcall(on_cancel) end
			end
		end, {"-c", check_cmd})
		
		if check_task then
			M._active_tasks[check_task] = true
			pcall(function() check_task:start() end)
		else
			Logger.error(LOG, "Failed to create MLX requirement check task.")
			if on_cancel then pcall(on_cancel) end
		end
	end

	function obj.delete_model(model_name)
		if not model_name or model_name == "" then return end
		local repo = obj.get_mlx_repo(model_name)
		if not repo then return end
		local home = os.getenv("HOME")
		local safe_repo = "models--" .. repo:gsub("/", "--")
		local path = home .. "/.cache/huggingface/hub/" .. safe_repo
		Logger.debug(LOG, "Deleting MLX model %s at %s…", tostring(model_name), path)

		-- A multi-GB model-cache delete must never run synchronously on the
		-- menu-click handler's thread — Hammerspoon has a single main run loop,
		-- and a blocking synchronous shell-out here freezes keystrokes, timers,
		-- and the menubar for the whole deletion (mirrors the identical bug class
		-- already fixed on the Ollama manager's task-based deletes).
		local delete_task
		delete_task = hs.task.new("/bin/rm", function(code, _stdout, stderr)
			if delete_task then M._active_tasks[delete_task] = nil end  -- delete_task captured by closure
			invalidate_installed_cache()
			if code == 0 then
				Logger.info(LOG, "MLX model %s deleted successfully.", tostring(model_name))
				pcall(notifications.notify, i18n.get("mlx.model_deleted"), model_name, "success")
			else
				Logger.error(LOG, "MLX model delete failed for %s: %s", tostring(model_name), tostring(stderr))
				pcall(notifications.notify, i18n.get("mlx.model_deleted"), model_name, "error")
			end
			pcall(deps.update_menu)
		end, {"-rf", path})

		if delete_task then
			M._active_tasks[delete_task] = true
			pcall(function() delete_task:start() end)
		else
			Logger.error(LOG, "Failed to create MLX model delete task for %s.", tostring(model_name))
		end
	end

	return obj
end

return M
