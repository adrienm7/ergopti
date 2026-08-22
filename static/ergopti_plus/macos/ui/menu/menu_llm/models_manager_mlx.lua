--- ui/menu/menu_llm/models_manager_mlx.lua

--- ==============================================================================
--- MODULE: MLX Models Manager
--- DESCRIPTION:
--- Handles all MLX specifics, server execution, requirements parsing, and downloads.
---
--- FEATURES & RATIONALE:
--- 1. Subprocess Handling: Spawns the huggingface cli cleanly.
--- 2. File Verification: Safely verifies tensors to guarantee cache integrity.
--- 3. Exact Requirement Ownership: Joins native import probes before pause.
--- ==============================================================================

local M = {}
local hs            = hs
local notifications = require("infra.notifications")
local Logger = require("infra.logger")
local fs_dir       = require("infra.fs_dir")
local i18n = require("infra.i18n")
local ApiCommon = require("modules.llm.api_common")
local TaskLifecycle = require("adapters.task_lifecycle")
local RequirementRegistry = require("ui.menu.menu_llm.requirement_operation_registry")

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

-- Retained for start_server / port helpers; the restart-hook registration it once
-- carried was removed with its only invoker.
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
	-- Import probes are independently owned from their caller continuations. A
	-- caller generation fence prevents stale business work, but only this ledger
	-- can prove the exact native task has completed before PAUSED is published
	local requirement_tasks = {}
	local requirement_registry = RequirementRegistry.new({
		backend = "MLX",
		require_owned = deps.script_control ~= nil,
	})
	local maintenance_capability = requirement_registry.create_owner(
		"MLX model maintenance")
	local maintenance_registration_required = type(deps.script_control) == "table"
		and type(deps.script_control.register_pause_owner) == "function"
	local maintenance_registered = maintenance_registration_required ~= true
	-- Installed-models scan cache TTL. The HF hub directory only changes on a
	-- download or delete (both invalidate the cache below), so the old 1 s TTL just
	-- wasted ~70-120 ms re-scanning the cache on nearly every menu open. 30 s
	-- matches the Ollama manager and keeps repeated opens off the filesystem.
	local INSTALLED_CACHE_TTL = 30
	local function invalidate_installed_cache() obj._installed_cache_ts = 0 end

	-- The cross-session restart hook was removed with the code that called it:
	-- api_mlx_discovery documents that reading data[1].id as the loaded model and
	-- "fixing" mismatches with zombie kills and forced restarts was chasing a
	-- phantom. The registration side outlived its only invoker and read as live.

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
	local begin_maintenance
	require("ui.menu.menu_llm.models_manager_mlx_hf").install({
		obj = obj,
		deps = deps,
		presets = presets,
		begin_direct_operation = function(label)
			return begin_maintenance(label)
		end,
	})

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

	--- Releases one exact requirement-task owner after native completion.
	--- @param owner table Requirement-task lifecycle owner.
	--- @return boolean released True only for the first terminal delivery.
	local function release_requirement_task(owner)
		if type(owner) ~= "table" or owner.settled == true then return false end
		owner.settled = true
		local task = owner.task
		if task ~= nil then
			if requirement_tasks[task] == owner then requirement_tasks[task] = nil end
			M._active_tasks[task] = nil
		end
		return true
	end

	--- Proves that a start-refused native task never became live. A false/nil/
	--- throwing start is otherwise ambiguous because native state may have mutated
	--- before the refusal crossed the Lua boundary.
	--- @param task any Exact native task handle.
	--- @param label string Diagnostic label.
	--- @return boolean stopped Literal true only for an exact `isRunning()==false`.
	local function requirement_task_proven_not_running(task, label)
		local ok_method, method = xpcall(function()
			return task and task.isRunning
		end, debug.traceback)
		if not ok_method or type(method) ~= "function" then return false end
		local ok_running, running = xpcall(function()
			return method(task)
		end, debug.traceback)
		if not ok_running then
			Logger.error(LOG, "%s running-state probe raised: %s.",
				tostring(label), tostring(running))
		end
		return ok_running == true and running == false
	end

	--- Revokes and signals one exact requirement task without treating SIGTERM
	--- acceptance as exit settlement. False, nil, and throw retain the same handle
	--- for retry; a successful signal remains pending until its callback arrives.
	--- @param owner table Requirement-task lifecycle owner.
	--- @param label string Stable diagnostic label.
	--- @return boolean settled True only after exact native completion.
	local function cancel_requirement_task(owner, label)
		if type(owner) ~= "table" or owner.settled == true then return true end
		owner.authorized = false
		owner.cleanup = true
		if owner.termination_accepted == true then return false end
		local task = owner.task
		local ok_method, terminate_method = xpcall(function()
			return task and task.terminate
		end, debug.traceback)
		if not ok_method or type(terminate_method) ~= "function" then
			Logger.error(LOG,
				"%s cannot terminate the exact requirement task; owner retained.",
				tostring(label))
			return false
		end
		local ok_terminate, signal_or_error = xpcall(function()
			return terminate_method(task)
		end, debug.traceback)
		if owner.settled == true then return true end
		if not ok_terminate or signal_or_error == nil or signal_or_error == false then
			Logger.error(LOG,
				"%s requirement-task termination refused; exact owner retained: %s.",
				tostring(label), tostring(signal_or_error))
			return false
		end
		owner.termination_accepted = true
		Logger.debug(LOG,
			"%s requirement-task termination accepted; awaiting exact completion.",
			tostring(label))
		return false
	end

	local function maintenance_admitted()
		if maintenance_registered ~= true then return false end
		if maintenance_registration_required ~= true then return true end
		local control = deps.script_control
		if type(control.is_paused) ~= "function"
			or type(control.is_pause_transition_pending) ~= "function" then
			return false
		end
		local paused_ok, paused = xpcall(control.is_paused, debug.traceback)
		local pending_ok, pending = xpcall(
			control.is_pause_transition_pending, debug.traceback)
		return paused_ok == true and paused == false
			and pending_ok == true and pending == false
	end

	begin_maintenance = function(label)
		if maintenance_admitted() ~= true then
			Logger.debug(LOG, "%s rejected by model-maintenance pause admission.", label)
			return nil
		end
		local operation, reason = requirement_registry.begin(maintenance_capability)
		if operation == nil then
			Logger.error(LOG, "%s ownership acquisition refused: %s.",
				label, tostring(reason))
		end
		return operation
	end

	if maintenance_registration_required then
		local maintenance_owner = {
			pause = function()
				local settled = requirement_registry.pause(maintenance_capability)
				return settled == true
			end,
			resume = function() return true end,
		}
		local registered_ok, registered = xpcall(function()
			return deps.script_control.register_pause_owner(
				"mlx_model_maintenance", maintenance_owner)
		end, debug.traceback)
		maintenance_registered = registered_ok == true and registered == true
		if maintenance_registered ~= true then
			Logger.error(LOG, "MLX model-maintenance pause-owner registration refused: %s.",
				tostring(registered))
		end
	end

	--- Creates one opaque requirement-operation pause capability.
	--- @param label string Stable owner label for diagnostics.
	--- @return table|nil capability Opaque exact-owner token, or nil on refusal.
	function obj.create_requirement_owner(label)
		return requirement_registry.create_owner(label)
	end

	--- Fences and joins every exact descendant launched by one MLX requirement
	--- capability. Descendant modules retain their native owners; the registry
	--- stores only their scoped pause/join delegates.
	--- @param capability table Opaque token returned by create_requirement_owner().
	--- @return boolean settled True only after every descendant settled.
	--- @return boolean had_tasks True when this call observed a logical operation.
	function obj.pause_requirements(capability)
		return requirement_registry.pause(capability)
	end

	function obj.check_requirements(target_model, on_success, on_cancel, opts)
		local requirement_capability = type(opts) == "table"
			and opts.requirement_owner or nil
		local operation, refusal_reason = requirement_registry.begin(
			requirement_capability)
		if operation == nil then
			if type(on_cancel) == "function" then
				Logger.callback(LOG, "MLX requirement ownership refusal",
					on_cancel, refusal_reason)
			end
			return false
		end
		local caller_is_current = type(opts) == "table" and opts.is_current
			or function() return true end
		local operation_opts = {}
		if type(opts) == "table" then
			for key, value in pairs(opts) do operation_opts[key] = value end
		end
		operation_opts._requirement_lifecycle = operation.lifecycle
		operation_opts.is_current = function()
			if operation.is_authorized() ~= true then return false end
			local ok, current = Logger.callback(LOG,
				"MLX caller requirement freshness check", caller_is_current)
			return ok == true and current == true
		end
		opts = operation_opts
		local is_current = operation_opts.is_current
		local function still_current()
			local ok, current = Logger.callback(LOG,
				"MLX requirement freshness check", is_current)
			return ok == true and current == true
		end
		local function settle(callback, label, ...)
			return operation.finish(callback, label, ...)
		end
		local function settle_cancel(...)
			return settle(on_cancel, "MLX requirement cancellation", ...)
		end
		local function current_or_cancel()
			if still_current() then return true end
			settle_cancel("stale")
			return false
		end
		local function settle_success(...)
			if not current_or_cancel() then return false end
			return settle(on_success, "MLX requirement success", ...)
		end
		if not current_or_cancel() then return false end
		if not target_model or target_model == "" then 
			return settle_success()
		end
		Logger.debug(LOG, "Checking MLX requirements for model %s…", tostring(target_model))

		local function do_check()
			if not current_or_cancel() then return false end
			local installed = obj.get_installed_models()
			if installed[target_model] then
				Logger.info(LOG, "MLX model %s is installed. Starting server…", tostring(target_model))
				if not current_or_cancel() then return false end
				local started = obj.start_server(target_model, settle_success, settle_cancel, opts)
				if started == false then settle_cancel("start_refused") end
				return started ~= false
			else
				if not current_or_cancel() then return false end
				Logger.warn(LOG, "MLX model %s not detected as installed. Starting download flow…", tostring(target_model))
				local repo = obj.get_mlx_repo(target_model)
				if not repo then 
					pcall(notifications.notify, i18n.get("mlx.model_unavailable"), string.format(i18n.get("mlx.model_unavailable_body"), target_model), "error")
					settle_cancel("unavailable")
					return false
				end
				
				if type(deps.shared_system_check) == "function" then
					local check_ok, accepted = Logger.callback(LOG, "MLX shared system check",
						deps.shared_system_check, target_model, "Apple MLX", repo, function()
							if not current_or_cancel() then return false end
							return obj.pull_model(target_model, repo,
								settle_success, settle_cancel, opts)
						end, settle_cancel, opts)
					if not check_ok or accepted ~= true then
						settle_cancel("system_check_refused")
						return false
					end
					return true
				else
					if not current_or_cancel() then return false end
					return obj.pull_model(target_model, repo,
						settle_success, settle_cancel, opts) ~= false
				end
			end
		end

		-- Verify the pinned project venv has every required MLX dependency
		-- importable. If it does not, the venv is broken / out of sync and the
		-- user must run modules/llm/ensure-mlx-deps.sh manually — silently
		-- pip-installing a fallback would bypass pyproject.toml.
		local check_cmd = "\"" .. project_venv_python_escaped .. "\" -c 'import mlx_lm; import huggingface_hub; import jinja2; import safetensors'"
		-- Publish the exact owner before start(). TaskLifecycle.start() can mutate
		-- native state and still return false/nil/throw, so refusal begins cleanup;
		-- it never authorizes the queued completion or drops the GC pin
		local task_owner = {
			task = nil,
			authorized = true,
			cleanup = false,
			settled = false,
			start_committed = false,
			dispatching = true,
			pending_terminal = nil,
			termination_accepted = false,
		}
		local check_task
		local function handle_requirement_completion(code)
			if not current_or_cancel() then return end
			if code == 0 then
				return do_check()
			else
				-- Differentiate three cases so the user sees the truth:
				--   1. bootstrap still running → "patientez", do not flip to error
				--   2. bootstrap failed        → show the actual stderr cause
				--   3. unknown                 → previous generic message
				if mlx_deps_checker and mlx_deps_checker.is_pending and mlx_deps_checker.is_pending() then
					Logger.info(LOG, "MLX import probe failed but bootstrap still pending — launching install.")
					local bootstrap_ok, accepted = xpcall(
						mlx_deps_checker.check_and_install_deps, debug.traceback)
					if not bootstrap_ok or accepted ~= true then
						Logger.debug(LOG,
							"MLX dependency install was rejected by its pause admission.")
						return settle_cancel("dependency_bootstrap_refused")
					end
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
				return settle_cancel("dependency_probe_failed")
			end
		end
		local function complete_requirement_task(...)
			if task_owner.settled == true then return false end
			if task_owner.dispatching == true then
				if task_owner.pending_terminal ~= nil then return false end
				task_owner.pending_terminal = table.pack(...)
				return true
			end
			local authorized = task_owner.authorized == true
				and task_owner.start_committed == true
				and operation.is_authorized() == true
			release_requirement_task(task_owner)
			operation.lifecycle.settle(task_owner)
			if not authorized then return true end
			return handle_requirement_completion(...)
		end
		check_task = TaskLifecycle.native("MLX requirement check", "/bin/bash",
			complete_requirement_task, {"-c", check_cmd})
		task_owner.task = check_task
		
		if check_task then
			requirement_tasks[check_task] = task_owner
			M._active_tasks[check_task] = true
			task_owner.pause_join = function()
				return cancel_requirement_task(task_owner,
					"MLX requirement operation pause")
			end
			if operation.lifecycle.adopt(task_owner, task_owner.pause_join,
				"MLX import probe") ~= true then
				task_owner.authorized = false
				task_owner.cleanup = true
				cancel_requirement_task(task_owner,
					"MLX requirement owner adoption refusal")
				settle_cancel("requirement_owner_adoption_refused")
				return false
			end
			local started = TaskLifecycle.start(check_task, "MLX requirement check")
			task_owner.dispatching = false
			if started ~= true then
				task_owner.authorized = false
				task_owner.cleanup = true
				if task_owner.pending_terminal ~= nil then
					task_owner.pending_terminal = nil
					release_requirement_task(task_owner)
					operation.lifecycle.settle(task_owner)
				elseif requirement_task_proven_not_running(check_task,
					"MLX requirement start refusal") then
					release_requirement_task(task_owner)
					operation.lifecycle.settle(task_owner)
				else
					cancel_requirement_task(task_owner,
						"MLX requirement start refusal")
				end
				settle_cancel("task_start_refused")
				return false
			end
			task_owner.start_committed = true
			if task_owner.pending_terminal ~= nil then
				local terminal = task_owner.pending_terminal
				task_owner.pending_terminal = nil
				complete_requirement_task(table.unpack(terminal, 1, terminal.n))
			end
		else
			task_owner.authorized = false
			task_owner.dispatching = false
			task_owner.settled = true
			settle_cancel("task_construction_failed")
			return false
		end
		return true
	end

	function obj.delete_model(model_name)
		if not model_name or model_name == "" then return false end
		local operation = begin_maintenance("MLX model deletion")
		if operation == nil then return false end
		local repo = obj.get_mlx_repo(model_name)
		if not repo then
			operation.finish(nil, "MLX model deletion repository refusal")
			return false
		end
		local home = os.getenv("HOME")
		if type(home) ~= "string" or home == "" then
			operation.finish(nil, "MLX model deletion HOME refusal")
			return false
		end
		local safe_repo = "models--" .. repo:gsub("/", "--")
		local path = home .. "/.cache/huggingface/hub/" .. safe_repo
		Logger.debug(LOG, "Deleting MLX model %s at %s…", tostring(model_name), path)

		-- A multi-GB model-cache delete must never run synchronously on the
		-- menu-click handler's thread — Hammerspoon has a single main run loop,
		-- and a blocking synchronous shell-out here freezes keystrokes, timers,
		-- and the menubar for the whole deletion (mirrors the identical bug class
		-- already fixed on the Ollama manager's task-based deletes).
		local owner = {
			task = nil,
			authorized = true,
			cleanup = false,
			settled = false,
			start_committed = false,
			dispatching = true,
			pending_terminal = nil,
			termination_accepted = false,
		}
		local function release_delete_owner()
			if release_requirement_task(owner) ~= true then return false end
			operation.lifecycle.settle(owner)
			return true
		end
		local delete_task
		local function finish_delete(code, _stdout, stderr)
			if owner.settled == true then return false end
			local authorized = owner.authorized == true
				and owner.start_committed == true
				and operation.is_authorized() == true
			release_delete_owner()
			operation.finish(nil, "MLX model deletion terminal")
			if authorized ~= true then return false end
			invalidate_installed_cache()
			if code == 0 then
				Logger.info(LOG, "MLX model %s deleted successfully.", tostring(model_name))
				pcall(notifications.notify, i18n.get("mlx.model_deleted"), model_name, "success")
			else
				Logger.error(LOG, "MLX model delete failed for %s: %s", tostring(model_name), tostring(stderr))
				pcall(notifications.notify, i18n.get("mlx.model_deleted"), model_name, "error")
			end
			if type(deps.update_menu) == "function" then
				Logger.callback(LOG, "MLX model deletion menu refresh", deps.update_menu)
			end
			return code == 0
		end
		delete_task = TaskLifecycle.native("MLX model deletion", "/bin/rm", function(...)
			if owner.dispatching == true then
				if owner.pending_terminal == nil then
					owner.pending_terminal = table.pack(...)
				end
				return true
			end
			return finish_delete(...)
		end, {"-rf", path})
		owner.task = delete_task

		if delete_task then
			requirement_tasks[delete_task] = owner
			M._active_tasks[delete_task] = true
			owner.pause_join = function()
				return cancel_requirement_task(owner, "MLX model deletion pause")
			end
			if operation.lifecycle.adopt(owner, owner.pause_join,
				"MLX model deletion") ~= true then
				owner.authorized = false
				owner.cleanup = true
				if requirement_task_proven_not_running(delete_task,
					"MLX deletion adoption refusal") then
					release_delete_owner()
				else
					cancel_requirement_task(owner, "MLX deletion adoption refusal")
				end
				operation.finish(nil, "MLX deletion adoption refusal")
				return false
			end
			local start_ok, started = xpcall(function()
				return TaskLifecycle.start(delete_task, "MLX model deletion")
			end, debug.traceback)
			owner.dispatching = false
			if start_ok ~= true or started ~= true then
				if start_ok ~= true then
					Logger.error(LOG,
						"MLX model deletion start raised; exact task retained: %s.",
						tostring(started))
				end
				owner.authorized = false
				owner.cleanup = true
				if owner.pending_terminal ~= nil then
					local terminal = owner.pending_terminal
					owner.pending_terminal = nil
					finish_delete(table.unpack(terminal, 1, terminal.n))
				else
					-- A native start may publish/mutate the process capability before
					-- returning false, nil, or throwing. Signal the already-pinned exact
					-- candidate first; an isRunning()==false probe may then prove that
					-- even a refused signal left no physical task to await.
					cancel_requirement_task(owner,
						"MLX model deletion start refusal")
					if owner.settled ~= true
						and requirement_task_proven_not_running(delete_task,
							"MLX model deletion start-refusal settlement") then
						release_delete_owner()
					end
				end
				operation.finish(nil, "MLX model deletion start refusal")
				return false
			end
			owner.start_committed = true
			if operation.is_authorized() ~= true then
				owner.authorized = false
				owner.cleanup = true
				cancel_requirement_task(owner, "MLX model deletion post-start fence")
				operation.finish(nil, "MLX model deletion revoked")
				return false
			end
			if owner.pending_terminal ~= nil then
				local terminal = owner.pending_terminal
				owner.pending_terminal = nil
				return finish_delete(table.unpack(terminal, 1, terminal.n))
			end
			return true
		end
		owner.dispatching = false
		owner.settled = true
		operation.finish(nil, "MLX model deletion construction refusal")
		return false
	end

	return obj
end

return M
