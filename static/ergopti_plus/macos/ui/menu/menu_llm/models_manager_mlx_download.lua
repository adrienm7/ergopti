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
local text_utils    = require("infra.text_utils")
local TaskLifecycle = require("adapters.task_lifecycle")
local TimerScheduler = require("adapters.timer_scheduler")
local MlxRepo = require("ui.menu.menu_llm.models_manager_mlx_repo")

-- Optional download-progress webview; absent in headless/unusual layouts.
local ok_dw, download_window = pcall(require, "ui.download_window")
if not ok_dw then download_window = nil end

-- Same LOG tag as the parent manager so download log lines stay grouped under
-- "menu_llm.mlx" exactly as before the split.
local LOG = "menu_llm.mlx"
local PID_GONE_EXIT = 72
local PID_IDENTITY_MISMATCH_EXIT = 73
local PID_IDENTITY_UNKNOWN_EXIT = 74
local PID_SIGNAL_REFUSED_EXIT = 75
local PID_TERM_ATTEMPT_LIMIT = 4





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
	local release_download_owner

	local function timer_handle_live(handle)
		return type(handle) == "table" and handle.timer ~= nil
	end

	local function cancel_owner_timer(owner, slot)
		local handle = owner.timers and owner.timers[slot]
		if handle == nil then return true end
		if type(handle) == "table" and handle.acquiring == true then
			handle.cancel_requested = true
			return false
		end
		local delivery = owner.timer_deliveries and owner.timer_deliveries[handle]
		if delivery ~= nil then delivery.cancelled = true end
		if not timer_handle_live(handle) then
			if owner.timers[slot] == handle then owner.timers[slot] = nil end
			if owner.timer_deliveries then owner.timer_deliveries[handle] = nil end
			return true
		end
		local ok, settled = Logger.callback(LOG,
			"MLX download " .. tostring(slot) .. " timer cancellation",
			TimerScheduler.cancel, handle)
		if ok == true and settled == true then
			if owner.timers[slot] == handle then owner.timers[slot] = nil end
			if owner.timer_deliveries then owner.timer_deliveries[handle] = nil end
			return true
		end
		if delivery ~= nil and type(delivery.finish) == "function" then
			delivery.finish()
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
		local predecessor = owner.timers[slot]
		if predecessor ~= nil then
			if cancel_owner_timer(owner, slot) ~= true then
				Logger.error(LOG, "MLX download '%s' timer replacement was refused.",
					tostring(slot))
				return false
			end
			if owner.timers[slot] ~= nil then
				Logger.error(LOG,
					"MLX download '%s' timer replacement was superseded during settlement.",
					tostring(slot))
				return false
			end
		end
		local cleanup_only = slot == "cleanup"
		local acquisition = {
			acquiring = true,
			cancel_requested = false,
		}
		owner.timers[slot] = acquisition
		local handle
		local retained_slot = slot
		local delivery = { cancelled = false, delivered = false, observer_attached = false }
		local function finish_delivery()
			if delivery.delivered == true then return true end
			-- A native-faithful scheduler can settle inside after() before the
			-- candidate crosses back into this scope. The acquisition transaction
			-- below rejects that delivery; do not index cleanup ledgers by nil here.
			if handle == nil then return false end
			if owner.timers[retained_slot] ~= handle then
				if owner.timer_deliveries then owner.timer_deliveries[handle] = nil end
				return false
			end
			if timer_handle_live(handle) then
				if delivery.observer_attached == true then return false end
				delivery.observer_attached = true
				local observe_ok, observed = Logger.callback(LOG,
					"MLX download " .. tostring(slot) .. " timer settlement observation",
					TimerScheduler.onSettled, handle, function()
						delivery.observer_attached = false
						finish_delivery()
					end)
				if observe_ok ~= true or observed ~= true then
					delivery.observer_attached = false
					return false
				end
				return false
			end
			delivery.delivered = true
			owner.timers[retained_slot] = nil
			if owner.timer_deliveries then owner.timer_deliveries[handle] = nil end
			if delivery.cancelled == true then
				if owner.revoked == true or owner.terminal_sent == true then
					release_download_owner(owner)
				end
				return true
			end
			if owner.paused == true and cleanup_only ~= true then
				owner.deferred_timers = owner.deferred_timers or {}
				owner.deferred_timers[slot] = {
					delay = delay,
					callback = callback,
				}
				return true
			end
			owner.callback_depth = (owner.callback_depth or 0) + 1
			local callback_ok, callback_result = Logger.callback(LOG,
				"MLX download " .. tostring(slot) .. " timer callback", callback)
			owner.callback_depth = owner.callback_depth - 1
			if owner.revoked == true or owner.terminal_sent == true then
				release_download_owner(owner)
			end
			if callback_ok ~= true then return false end
			return callback_result
		end
		delivery.finish = finish_delivery
		owner.timer_acquisition_depth = (owner.timer_acquisition_depth or 0) + 1
		local ok, candidate, committed = Logger.callback(LOG,
			"MLX download " .. tostring(slot) .. " timer acquisition",
			TimerScheduler.after, delay, finish_delivery)
		owner.timer_acquisition_depth = owner.timer_acquisition_depth - 1
		acquisition.acquiring = false
		handle = candidate
		if owner.timers[slot] == acquisition then
			if type(candidate) == "table" and timer_handle_live(candidate) then
				owner.timers[slot] = candidate
			else
				owner.timers[slot] = nil
			end
		else
			acquisition.cancel_requested = true
			-- Keep an otherwise-unreachable live candidate under its own opaque
			-- cleanup slot. It is permanently cancelled and can only be removed by
			-- exact TimerScheduler settlement.
			if type(candidate) == "table" and timer_handle_live(candidate) then
				retained_slot = candidate
				owner.timers[retained_slot] = candidate
			end
		end
		if type(candidate) == "table" then
			owner.timer_deliveries = owner.timer_deliveries or {}
			owner.timer_deliveries[candidate] = delivery
		end
		-- Revocation fences business continuations, not cleanup. The exact PID
		-- poll is what eventually proves the detached process and session file are
		-- gone; rejecting it merely because cancellation already revoked the owner
		-- strands both capabilities forever.
		local business_authorized = owner.paused ~= true
			and owner.revoked ~= true and owner.terminal_sent ~= true
		local authorized = acquisition.cancel_requested ~= true
			and download_owner == owner
			and (cleanup_only == true or business_authorized == true)
		if ok ~= true or type(candidate) ~= "table" or committed ~= true
			or timer_handle_live(candidate) ~= true or authorized ~= true
			or retained_slot ~= slot or owner.timers[retained_slot] ~= candidate then
			Logger.error(LOG, "MLX download '%s' timer acquisition was refused.",
				tostring(slot))
			if owner.paused == true and cleanup_only ~= true
				and download_owner == owner and owner.revoked ~= true
				and owner.terminal_sent ~= true then
				owner.deferred_timers = owner.deferred_timers or {}
				owner.deferred_timers[slot] = {
					delay = delay,
					callback = callback,
				}
			end
			delivery.cancelled = true
			cancel_owner_timer(owner, retained_slot)
			return false
		end
		return true
	end

	local function owner_has_native_work(owner, ignore_callback)
		for slot, handle in pairs(owner.timers or {}) do
			if type(handle) == "table" and handle.acquiring == true then return true end
			if timer_handle_live(handle) then return true end
			owner.timers[slot] = nil
		end
		return (ignore_callback ~= true and (owner.callback_depth or 0) > 0)
			or (owner.timer_acquisition_depth or 0) > 0
			or (owner.task_acquisition_depth or 0) > 0
			or owner.tail_starting == true
			or owner.tasks.launcher ~= nil
			or owner.tasks.tail ~= nil
			or owner.partial.pid ~= nil
			or owner.server_pending == true
	end

	release_download_owner = function(owner)
		if download_owner ~= owner or owner.keep_registered
			or owner_has_native_work(owner) then return false end
		if type(owner.remove_session) == "function"
			and owner.remove_session() ~= true then return false end
		local after_release = owner.after_release
		owner.after_release = nil
		if type(owner.on_release) == "function" then owner.on_release() end
		owner.active = false
		download_owner = nil
		if owner.requirement_registered == true
			and type(owner.requirement_lifecycle) == "table"
			and type(owner.requirement_lifecycle.settle) == "function" then
			owner.requirement_registered = false
			owner.requirement_lifecycle.settle(owner)
		end
		if type(after_release) == "function" then
			Logger.callback(LOG, "MLX download post-release successor", after_release)
		end
		return true
	end

	--- Captures one callback boundary while the exact download owner remains live.
	--- @param owner table Exact logical download owner.
	--- @param label string Stable diagnostic label.
	--- @param callback function Callback body.
	--- @param ... any Callback arguments.
	--- @return table results Packed Logger.callback results, including boundary status.
	local function owner_callback_results(owner, label, callback, ...)
		owner.callback_depth = (owner.callback_depth or 0) + 1
		local results = table.pack(Logger.callback(LOG, label, callback, ...))
		owner.callback_depth = math.max(0, owner.callback_depth - 1)
		if owner.revoked == true or owner.terminal_sent == true then
			release_download_owner(owner)
		end
		return results
	end

	--- Runs one native or UI callback while the exact download owner remains live.
	--- @param owner table Exact logical download owner.
	--- @param label string Stable diagnostic label.
	--- @param callback function Callback body.
	--- @param ... any Callback arguments.
	--- @return any result Callback result, or false when the boundary raised.
	local function run_owner_callback(owner, label, callback, ...)
		local results = owner_callback_results(owner, label, callback, ...)
		if results[1] ~= true then return false end
		return table.unpack(results, 2, results.n)
	end

	--- Keeps PAUSE joined while a task construction or start boundary is on-stack.
	--- The caller publishes any returned candidate before its first revalidation.
	--- @param owner table Exact logical download owner.
	--- @param label string Stable diagnostic label.
	--- @param callback function TaskLifecycle adapter operation.
	--- @param ... any Adapter arguments.
	--- @return any result Adapter result with false and nil preserved.
	local function run_owner_task_acquisition(owner, label, callback, ...)
		owner.task_acquisition_depth = (owner.task_acquisition_depth or 0) + 1
		local results = table.pack(Logger.callback(LOG, label, callback, ...))
		owner.task_acquisition_depth = math.max(0,
			owner.task_acquisition_depth - 1)
		if results[1] ~= true then return nil end
		return table.unpack(results, 2, results.n)
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

	--- Derives the only Python script path owned by one detached-download log.
	--- @param log_path string Detached log path.
	--- @return string|nil script_path Canonical sibling script path.
	local function derive_download_script_path(log_path)
		if type(log_path) ~= "string" then return nil end
		local stem = log_path:match("^(/tmp/hs_mlx_dl_[%w_-]+)%.log$")
		if stem == nil then return nil end
		return stem .. ".py"
	end

	--- Reads the process-authored exit proof without conflating access refusal with absence.
	--- @param path string Exact detached-process exit path.
	--- @param label string Stable diagnostic label.
	--- @return boolean|nil exists Exact existence, or nil when the probe is inconclusive.
	local function probe_download_exit_file(path, label)
		if type(path) ~= "string" or path == "" then return nil end
		local results = table.pack(Logger.callback(LOG, label .. " open", io.open, path, "r"))
		if results[1] ~= true then
			Logger.error(LOG, "%s raised: %s.", label, tostring(results[2]))
			return nil
		end
		local handle = results[2]
		if handle == nil or handle == false then
			local errno = tonumber(results[4])
			if errno == nil or errno == 2 then return false end
			Logger.error(LOG, "%s was refused: %s.", label, tostring(results[3]))
			return nil
		end
		local close_ok, closed = Logger.callback(LOG, label .. " close", function()
			return handle:close()
		end)
		if close_ok ~= true or closed == false or closed == nil then
			Logger.error(LOG, "%s close was refused: %s.", label, tostring(closed))
			return nil
		end
		return true
	end

	--- Signals a detached process only while PID and exact script identity still agree.
	--- @param pid number Detached process identifier.
	--- @param script_path string Exact Python script path persisted for this owner.
	--- @param signal_name string TERM or KILL.
	--- @param label string Stable diagnostic label.
	--- @return string outcome Identity-aware signal outcome.
	local function signal_verified_download_pid(pid, script_path, signal_name, label)
		if type(pid) ~= "number" or pid <= 0 or pid % 1 ~= 0
			or type(script_path) ~= "string" or script_path == ""
			or (signal_name ~= "TERM" and signal_name ~= "KILL") then
			Logger.error(LOG, "%s refused invalid process identity inputs.", label)
			return "identity_unknown"
		end
		local command = "MLX_EXPECTED_SCRIPT=" .. text_utils.shell_quote(script_path) .. "; "
			.. "MLX_PID=" .. tostring(pid) .. "; "
			.. "if ! kill -0 -- \"$MLX_PID\" 2>/dev/null; then exit "
			.. tostring(PID_GONE_EXIT) .. "; fi; "
			.. "MLX_COMM=$(/bin/ps -o comm= -p \"$MLX_PID\" 2>/dev/null); "
			.. "MLX_ARGS=$(/bin/ps -o args= -p \"$MLX_PID\" 2>/dev/null); "
			.. "if [ -z \"$MLX_COMM\" ] || [ -z \"$MLX_ARGS\" ]; then "
			.. "if kill -0 -- \"$MLX_PID\" 2>/dev/null; then exit "
			.. tostring(PID_IDENTITY_UNKNOWN_EXIT) .. "; else exit "
			.. tostring(PID_GONE_EXIT) .. "; fi; fi; "
			.. "case \"$MLX_COMM\" in *[Pp][Yy][Tt][Hh][Oo][Nn]*) ;; *) exit "
			.. tostring(PID_IDENTITY_MISMATCH_EXIT) .. ";; esac; "
			.. "printf '%s' \"$MLX_ARGS\" | /usr/bin/grep -Fq -- \"$MLX_EXPECTED_SCRIPT\" "
			.. "|| exit " .. tostring(PID_IDENTITY_MISMATCH_EXIT) .. "; "
			.. "kill -" .. signal_name .. " -- \"$MLX_PID\" 2>/dev/null || exit "
			.. tostring(PID_SIGNAL_REFUSED_EXIT)
		local results = table.pack(Logger.callback(LOG, label, os.execute, command))
		if results[1] ~= true then return "probe_failed" end
		local result = results[2]
		local exit_code = tonumber(results[4])
		if result == true or result == 0 or exit_code == 0 then return "signalled" end
		if exit_code == PID_GONE_EXIT then return "gone" end
		if exit_code == PID_IDENTITY_MISMATCH_EXIT then return "not_owned" end
		if exit_code == PID_IDENTITY_UNKNOWN_EXIT then return "identity_unknown" end
		if exit_code == PID_SIGNAL_REFUSED_EXIT then return "signal_refused" end
		return "probe_failed"
	end

	--- Chooses a bounded escalation signal for one retained detached PID owner.
	--- @param owner table Exact logical download owner.
	--- @return string signal_name TERM or KILL.
	local function next_pid_cleanup_signal(owner)
		local attempts = owner.partial.pid_term_attempts or 0
		if attempts >= PID_TERM_ATTEMPT_LIMIT then return "KILL" end
		return "TERM"
	end

	--- Records only an identity-verified TERM boundary, not an inconclusive probe.
	--- @param owner table Exact logical download owner.
	--- @param signal_name string Attempted signal.
	--- @param outcome string Identity-aware signal outcome.
	local function record_pid_cleanup_attempt(owner, signal_name, outcome)
		if signal_name == "TERM"
			and (outcome == "signalled" or outcome == "signal_refused") then
			owner.partial.pid_term_attempts = (owner.partial.pid_term_attempts or 0) + 1
		end
	end

	function obj.pull_model(target_model, repo, on_success, on_cancel, opts)
		if MlxRepo.is_valid(repo) ~= true then
			Logger.error(LOG,
				"Model download refused an invalid HuggingFace repository identifier.")
			if type(on_cancel) == "function" then
				Logger.callback(LOG, "MLX invalid repository cancellation",
					on_cancel, "invalid_repo")
			end
			return false
		end
		local is_current = type(opts) == "table" and opts.is_current or function() return true end
		local requirement_lifecycle = type(opts) == "table"
			and opts._requirement_lifecycle or nil
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
			requirement_lifecycle = requirement_lifecycle,
			requirement_registered = false,
			callback_depth = 0,
			timer_acquisition_depth = 0,
			task_acquisition_depth = 0,
			tail_starting = false,
			pause_requested = false,
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
			return ok == true and current == true and owner.revoked ~= true
				and (owner.registered ~= true or download_owner == owner)
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
			if download_window and type(download_window.focus) == "function" then
				Logger.callback(LOG, "MLX active download focus", download_window.focus)
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
				local results = owner_callback_results(owner,
					label .. " cancellation", function()
						local method = task.terminate
						if type(method) ~= "function" then
							error("task terminate method is unavailable")
						end
						return method(task)
					end)
				local result = results[2]
				if results[1] ~= true or result == false or result == nil then
					Logger.error(LOG, "%s cancellation was refused: %s.", label, tostring(result))
					return false
				end
				return true
			end

			--- Reads exact task liveness without confusing probe failure with stopped proof.
			--- @param task any Exact native task.
			--- @param label string Stable diagnostic label.
			--- @return boolean|nil running True/false only for an exact boolean probe.
			local function task_running_state(task, label)
				if task == nil then return false end
				local state_results = owner_callback_results(owner,
					label .. " running-state probe", function()
						local method = task.isRunning
						if type(method) ~= "function" then
							error("task running-state method is unavailable")
						end
						return method(task)
					end)
				local running = state_results[2]
				if state_results[1] ~= true
					or (running ~= true and running ~= false) then
					Logger.error(LOG, "%s running-state probe was inconclusive: %s.",
						label, tostring(running))
					return nil
				end
				return running
			end

			local function task_proven_stopped(task, label)
				return task_running_state(task, label) == false
			end

			--- Clears one stopped task only while its exact owner slot still matches.
			--- @param slot string Owner task slot.
			--- @param active_key string Shared active-task key.
			--- @param task any Exact native task.
			--- @return boolean cleared
			local function clear_owned_task(slot, active_key, task)
				if owner.tasks[slot] ~= task then return false end
				owner.tasks[slot] = nil
				if deps.active_tasks and deps.active_tasks[active_key] == task then
					deps.active_tasks[active_key] = nil
				end
				return true
			end

			--- Signals one exact task and consumes an observable stopped proof.
			--- A probe cannot settle the task while its construction/start boundary is
			--- still on-stack because the same native call may activate after returning.
			--- @param slot string Owner task slot.
			--- @param active_key string Shared active-task key.
			--- @param label string Stable diagnostic label.
			--- @return boolean accepted_or_settled
			local function signal_owned_task(slot, active_key, label)
				local task = owner.tasks[slot]
				if task == nil then return true end
				local accepted = signal_task(task, label)
				if owner.tasks[slot] ~= task then return true end
				if (owner.task_acquisition_depth or 0) == 0
					and task_proven_stopped(task, label) then
					clear_owned_task(slot, active_key, task)
					return true
				end
				return accepted == true
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
				local exit_exists = probe_download_exit_file(owner.partial.exit_path,
					"MLX detached-download cleanup exit-file probe")
				if exit_exists == nil then return schedule_pid_cleanup(), false end
				if exit_exists == true then
					owner.partial.pid = nil
					Logger.callback(LOG, "MLX detached-download cleanup exit-file removal",
						os.remove, owner.partial.exit_path)
					remove_owned_session()
					release_download_owner(owner)
					return true, true
				end
				local signal_name = next_pid_cleanup_signal(owner)
				local outcome = signal_verified_download_pid(pid, owner.partial.script_path,
					signal_name, "MLX detached-download cleanup identity probe")
				record_pid_cleanup_attempt(owner, signal_name, outcome)
				if outcome == "gone" or outcome == "not_owned" then
					owner.partial.pid = nil
					remove_owned_session()
					release_download_owner(owner)
					return true, true
				end
				if outcome ~= "signalled" then
					Logger.error(LOG,
						"MLX detached-download cleanup retained PID %d after %s.",
						pid, outcome)
				end
				return schedule_pid_cleanup(), outcome == "signalled"
			end

			-- silent=true suppresses the "Annulé" notification and complete() so callers that
			-- already handle their own UI (do_retry, check_timeout) don't double-notify.
			-- Authority is revoked before any native signal; callbacks may retire their
			-- exact handles afterwards but can never publish success.
			--- Checks whether one cancellation callback may publish its next business effect.
			--- @param reason string|nil Cancellation reason.
			--- @return boolean authorized
			local function cancellation_continuation_current(reason)
				return download_owner == owner
					and owner.attempt_generation == attempt_generation
					and owner.terminal_sent ~= true
					and (owner.pause_requested ~= true or reason == "script_paused")
			end

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
					signalled = signal_owned_task("tail", "download_tail",
						"MLX download log tail") and signalled
				end
				if owner.tasks.launcher then
					signalled = signal_owned_task("launcher", "download",
						"MLX detached download launcher") and signalled
				end
				if reason ~= "stale"
					and not cancellation_continuation_current(reason) then
					release_download_owner(owner)
					return false
				end
				-- A stale owner may run after its successor has already published a new
				-- percentage. Clean only the exact native/session owners in that case;
				-- resetting shared UI here would let A overwrite B.
				if reason ~= "stale"
					and cancellation_continuation_current(reason) then
					update_icon("MLX download cancellation icon reset")
				end
				if reason ~= "stale"
					and not cancellation_continuation_current(reason) then
					release_download_owner(owner)
					return false
				end
				if not silent then
					pcall(notifications.notify, i18n.get("mlx.download_cancelled"),
						string.format(i18n.get("mlx.download_cancelled_body"),
							target_model), "warning")
					if not cancellation_continuation_current(reason) then
						release_download_owner(owner)
						return false
					end
					if download_window then
						pcall(download_window.complete, false, target_model)
					end
				end
				if reason ~= "stale"
					and not cancellation_continuation_current(reason) then
					release_download_owner(owner)
					return false
				end
				if not retrying then settle_cancel(reason or "user_cancelled") end
				if owner.partial.pid then
					local _, pid_signalled = poll_pid_cleanup()
					if pid_signalled ~= true then signalled = false end
				end
				release_download_owner(owner)
				return signalled
			end
			owner.cancel = do_cancel
			owner.retry_cleanup = function()
				if owner.revoked ~= true and owner.retry_pending ~= true
					and owner.terminal_sent ~= true then return false end
				cancel_owner_timers(owner, owner.retry_pending and "retry" or nil)
				if owner.tasks.tail then
					signal_owned_task("tail", "download_tail", "MLX download log tail")
				end
				if owner.tasks.launcher then
					signal_owned_task("launcher", "download",
						"MLX detached download launcher")
				end
				if owner.partial.pid then
					poll_pid_cleanup()
				else
					remove_owned_session()
				end
				release_download_owner(owner)
				return not owner_has_native_work(owner)
			end
			if owner.requirement_registered ~= true
				and type(requirement_lifecycle) == "table"
				and type(requirement_lifecycle.adopt) == "function" then
				owner.pause_requirement = function()
					owner.pause_requested = true
					owner.revoked = true
					if type(owner.cancel) == "function" then
						owner.cancel(true, "script_paused")
					end
					if type(owner.retry_cleanup) == "function" then
						owner.retry_cleanup()
					end
					release_download_owner(owner)
					return download_owner ~= owner
						or owner_has_native_work(owner) ~= true
				end
				if requirement_lifecycle.adopt(owner, owner.pause_requirement,
					"MLX requirement download") ~= true then
					do_cancel(true, "requirement_owner_adoption_refused")
					return false
				end
				owner.requirement_registered = true
			end

			local function cancel_from_ui()
				return run_owner_callback(owner, "MLX download cancel UI callback",
					function()
						return do_cancel(false)
					end)
			end

			local function do_retry()
				return run_owner_callback(owner, "MLX download retry UI callback",
					function()
						if owner.terminal_sent or owner.retry_pending
							or not current_or_cancel() then return false end
						-- Keep the logical slot across the retry handoff.  No other request can
						-- enter between retiring this attempt and registering its successor.
						owner.keep_registered = true
						owner.retry_pending = true
						do_cancel(true, "retry", true)
						if owner.pause_requested == true or owner.revoked == true
							or owner.terminal_sent == true or download_owner ~= owner
							or owner.retry_pending ~= true then
							owner.keep_registered = false
							owner.retry_pending = false
							release_download_owner(owner)
							return false
						end
						local schedule_retry
						schedule_retry = function()
							local scheduled = schedule_owner_timer(owner, "retry", 0.05,
								function()
									if owner.revoked or owner.terminal_sent
										or not owner.retry_pending then
										owner.keep_registered = false
										release_download_owner(owner)
										return false
									end
									if owner_has_native_work(owner, true) then
										return schedule_retry()
									end
									if remove_owned_session() ~= true then
										return schedule_retry()
									end
									if owner.revoked or owner.terminal_sent
										or download_owner ~= owner
										or not owner.retry_pending then
										return false
									end
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
					end)
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
						end, {
							owner = owner,
							lifecycle = requirement_lifecycle,
							is_authorized = current_or_cancel,
						})
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
			owner.partial.script_path = py_path
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
				"{\"model\":\"%s\",\"log_path\":\"%s\",\"exit_path\":\"%s\",\"script_path\":\"%s\",\"repo\":\"%s\"}",
				target_model, _log_path, _exit_path, py_path, clean_repo
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
				if not current_or_cancel() then return false end
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
						return run_owner_callback(owner,
							"MLX downloaded-model server terminal callback", function()
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
							end)
					end
					local dispatch_ok, accepted = Logger.callback(LOG,
						"MLX downloaded-model server dispatch", obj.start_server, target_model,
						function(...)
							return run_owner_callback(owner,
								"MLX downloaded-model server success callback", function(...)
									local values = table.pack(...)
									if server_dispatching then
										if pending_server_terminal == nil then
											pending_server_terminal = {"success", values}
										end
										return true
								end
									return finish_server("success", values)
								end, ...)
						end,
						function(...)
							return run_owner_callback(owner,
								"MLX downloaded-model server failure callback", function(...)
									local values = table.pack(...)
									if server_dispatching then
										if pending_server_terminal == nil then
											pending_server_terminal = {"failure", values}
										end
										return true
								end
									return finish_server("failure", values)
								end, ...)
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
				local tail_start_committed = false
				local pending_tail_completion = false
				local pending_tail_chunks = {}
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
					if not still_current() then
						do_cancel(true, "stale")
						return false
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

				tail_task = run_owner_task_acquisition(owner,
					"MLX download tail construction transaction",
					TaskLifecycle.native, "MLX download log tail", "/usr/bin/tail",
					function()
						return run_owner_callback(owner,
							"MLX download tail completion callback", function()
								if tail_starting then
									pending_tail_completion = true
									return true
								end
								return finish_tail()
							end)
					end, function(_, stdout, stderr)
						return run_owner_callback(owner,
							"MLX download tail stream callback", function()
								local chunk = (stdout or "") .. (stderr or "")
								if tail_starting then
									if pending_tail_completion then return false end
									pending_tail_chunks[#pending_tail_chunks + 1] = chunk
									return true
								end
								if tail_start_committed ~= true
									or owner.tasks.tail ~= tail_task
									or operation_closed or owner.revoked
									or download_owner ~= owner then return false end
								return process_stream(chunk) ~= false
							end)
					end, {"-F", "-n", "+1", _log_path})

				if tail_task then
					owner.tasks.tail = tail_task
					if deps.active_tasks then deps.active_tasks["download_tail"] = tail_task end
					if not still_current() then
						do_cancel(true, "stale")
						tail_starting = false
						pending_tail_chunks = {}
						if pending_tail_completion then
							run_owner_callback(owner,
								"MLX download buffered tail completion", finish_tail)
						end
						return false
					end
					local started = run_owner_task_acquisition(owner,
						"MLX download tail start transaction", TaskLifecycle.start,
						tail_task, "MLX download log tail")
					tail_starting = false
					local tail_running = nil
					if started == true and pending_tail_completion ~= true then
						tail_running = task_running_state(tail_task,
							"MLX download log tail post-start")
					end
					if not still_current() then
						pending_tail_chunks = {}
						if pending_tail_completion then
							run_owner_callback(owner,
								"MLX download buffered tail completion", finish_tail)
						end
						do_cancel(true, "stale")
						return false
					end
					if started ~= true
						or (pending_tail_completion ~= true and tail_running ~= true) then
						pending_tail_chunks = {}
						local task_settled = pending_tail_completion
							or tail_running == false
						if task_settled ~= true then
							signal_owned_task("tail", "download_tail",
								"MLX download log tail")
							task_settled = owner.tasks.tail ~= tail_task
						end
						if task_settled then
							clear_owned_task("tail", "download_tail", tail_task)
						end
						do_cancel(true, "tail_task_start_refused")
						return false
					end
					tail_start_committed = true
					for _, chunk in ipairs(pending_tail_chunks) do
						local stream_result = run_owner_callback(owner,
							"MLX download buffered tail stream", process_stream, chunk)
						if owner.tasks.tail ~= tail_task or operation_closed or owner.revoked
							or download_owner ~= owner or stream_result == false then
							pending_tail_chunks = {}
							if not operation_closed and not owner.revoked then
								do_cancel(true, "tail_stream_refused")
							end
							return false
						end
					end
					pending_tail_chunks = {}
					if pending_tail_completion then
						local completion_result = run_owner_callback(owner,
							"MLX download buffered tail completion", finish_tail)
						if completion_result ~= true then return false end
					end
				else
					tail_starting = false
					pending_tail_chunks = {}
					if operation_closed or owner.revoked or download_owner ~= owner
						or owner.attempt_generation ~= attempt_generation then
						release_download_owner(owner)
						return false
					end
					do_cancel(true, "tail_task_construction_failed")
					return false
				end
				if operation_closed or owner.revoked or download_owner ~= owner
					or owner.attempt_generation ~= attempt_generation then
					return false
				end
				if not still_current() then
					do_cancel(true, "stale")
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
					if operation_closed or owner.revoked or download_owner ~= owner
						or owner.attempt_generation ~= attempt_generation then
						return false
					end
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
				if operation_closed or owner.revoked or download_owner ~= owner
					or owner.attempt_generation ~= attempt_generation
					or not still_current() then
					do_cancel(true, "stale")
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
			local launcher_start_committed = false
			local pending_launcher_completion = nil
			local pending_launcher_chunks = {}
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
					if not current_or_cancel() then return false end
					if download_window then
						pcall(download_window.complete, false, target_model)
					end
					if not current_or_cancel() then return false end
					pcall(notifications.notify, i18n.get("mlx.launcher_failed"),
						string.format(i18n.get("mlx.launcher_failed_body"), code),
						"error")
					if not current_or_cancel() then return false end
					do_cancel(true, "launcher_failed")
					return false
				end
				return start_tail_monitor()
			end

			local function process_launcher_chunk(out)
				if operation_closed or owner.revoked
					or owner.attempt_generation ~= attempt_generation then
					if owner.partial.pid then schedule_pid_cleanup() end
					return false
				end
				if not still_current() then
					do_cancel(true, "stale")
					return false
				end
				return process_stream(out) ~= false
			end

			launcher_task = run_owner_task_acquisition(owner,
				"MLX detached launcher construction transaction",
				TaskLifecycle.native, "MLX detached download launcher", script_path,
				function(code)
					return run_owner_callback(owner,
						"MLX detached launcher completion callback", function()
							if launcher_starting then
								if pending_launcher_completion == nil then
									pending_launcher_completion = table.pack(code)
								end
								return true
							end
							return finish_launcher(code)
						end)
				end, function(_, stdout, stderr)
					return run_owner_callback(owner,
						"MLX detached launcher stream callback", function()
							local out = (stdout or "") .. (stderr or "")
							-- Resource discovery remains live after logical revocation: a queued PID
							-- sentinel is cleanup evidence, never publication authority.
							if not owner.partial.pid then
								local pid_str = out:match("__DLPID__:(%d+)")
								if pid_str then
									owner.partial.pid = tonumber(pid_str)
									if persist_owned_pid() ~= true then
										if operation_closed or owner.revoked then
											schedule_pid_cleanup()
										else
											do_cancel(true, "session_pid_write_failed")
										end
										return false
									end
									if not current_or_cancel() then return false end
								end
							end
							-- Strip the sentinel line before forwarding to the download window log
							local clean = out:gsub("__DLPID__:%d+\n?", "")
							if launcher_starting then
								if pending_launcher_completion ~= nil then return false end
								pending_launcher_chunks[#pending_launcher_chunks + 1] = clean
								return true
							end
							if launcher_start_committed ~= true
								or owner.tasks.launcher ~= launcher_task then return false end
							return process_launcher_chunk(clean)
						end)
				end)

			if launcher_task then
				owner.tasks.launcher = launcher_task
				if deps.active_tasks then deps.active_tasks["download"] = launcher_task end
				if not current_or_cancel() then
					launcher_starting = false
					pending_launcher_chunks = {}
					if pending_launcher_completion ~= nil then
						run_owner_callback(owner,
							"MLX buffered launcher completion", finish_launcher,
							table.unpack(pending_launcher_completion, 1,
								pending_launcher_completion.n))
					end
					return false
				end
				local started = run_owner_task_acquisition(owner,
					"MLX detached launcher start transaction", TaskLifecycle.start,
					launcher_task, "MLX detached download launcher")
				launcher_starting = false
				local launcher_running = nil
				if started == true and pending_launcher_completion == nil then
					launcher_running = task_running_state(launcher_task,
						"MLX detached download launcher post-start")
				end
				if not still_current() then
					pending_launcher_chunks = {}
					if pending_launcher_completion ~= nil then
						run_owner_callback(owner,
							"MLX buffered launcher completion", finish_launcher,
							table.unpack(pending_launcher_completion, 1,
								pending_launcher_completion.n))
					end
					do_cancel(true, "stale")
					return false
				end
				if started ~= true
					or (pending_launcher_completion == nil
						and launcher_running ~= true) then
					pending_launcher_chunks = {}
					local task_settled = pending_launcher_completion ~= nil
						or launcher_running == false
					if task_settled ~= true then
						signal_owned_task("launcher", "download",
							"MLX detached download launcher")
						task_settled = owner.tasks.launcher ~= launcher_task
					end
					if task_settled then
						clear_owned_task("launcher", "download", launcher_task)
					end
					if not current_or_cancel() then return false end
					update_icon("MLX launcher-refusal icon reset")
					if not current_or_cancel() then return false end
					if download_window then
						pcall(download_window.complete, false, target_model)
					end
					if not current_or_cancel() then return false end
					pcall(notifications.notify, i18n.get("mlx.launcher_failed"),
						string.format(i18n.get("mlx.launcher_failed_body"), -1), "error")
					if not current_or_cancel() then return false end
					do_cancel(true, "launcher_start_refused")
					return false
				end
				launcher_start_committed = true
				for _, chunk in ipairs(pending_launcher_chunks) do
					local stream_result = run_owner_callback(owner,
						"MLX buffered launcher stream", process_launcher_chunk, chunk)
					if owner.tasks.launcher ~= launcher_task
						or stream_result ~= true then
						pending_launcher_chunks = {}
						if not operation_closed and not owner.revoked then
							do_cancel(true, "launcher_stream_refused")
						end
						return false
					end
				end
				pending_launcher_chunks = {}
				if pending_launcher_completion ~= nil then
					local completion_result = run_owner_callback(owner,
						"MLX buffered launcher completion", finish_launcher,
						table.unpack(pending_launcher_completion, 1,
							pending_launcher_completion.n))
					if completion_result == false then return false end
				end
				if not still_current() then
					do_cancel(true, "stale")
					return false
				end
			else
				if operation_closed or owner.revoked or download_owner ~= owner
					or owner.attempt_generation ~= attempt_generation then
					launcher_starting = false
					pending_launcher_chunks = {}
					release_download_owner(owner)
					return false
				end
				update_icon("MLX launcher-construction icon reset")
				if not current_or_cancel() then return false end
				if download_window then
					pcall(download_window.complete, false, target_model)
				end
				if not current_or_cancel() then return false end
				pcall(notifications.notify, i18n.get("mlx.launcher_failed"),
					string.format(i18n.get("mlx.launcher_failed_body"), -1), "error")
				if not current_or_cancel() then return false end
				launcher_starting = false
				pending_launcher_chunks = {}
				do_cancel(true, "launcher_construction_failed")
				return false
			end
			return true
		end

		-- Dependencies are pinned in pyproject.toml and provisioned by
		-- ensure-mlx-deps.sh on Hammerspoon startup; no runtime upgrade path.
		return _internal_pull()
	end

	--- Suspends the already-dispatched reattach monitor without killing the
	--- detached downloader. Timer deliveries are parked and tail output is ignored
	--- until the same owner is resumed.
	--- @return boolean settled
	function obj.pause_reattached_download()
		local owner = download_owner
		if owner == nil or owner.kind ~= "reattached" then return true end
		owner.pause_epoch = (owner.pause_epoch or 0) + 1
		owner.paused = true
		return (owner.callback_depth or 0) == 0
			and (owner.timer_acquisition_depth or 0) == 0
			and owner.tail_starting ~= true
	end

	--- Re-authorizes one parked reattach monitor and re-arms any timer that fired
	--- while paused. Refused timer acquisition keeps the owner parked and retryable.
	--- @param opts table|nil Fresh local/global freshness and terminal callbacks.
	--- @return boolean committed
	function obj.resume_reattached_download(opts)
		local owner = download_owner
		if owner == nil or owner.kind ~= "reattached" then return true end
		if (owner.callback_depth or 0) > 0
			or (owner.timer_acquisition_depth or 0) > 0
			or owner.tail_starting == true then
			return false
		end
		local resume_is_current = owner.is_current
		if type(opts) == "table" then
			if type(opts.is_current) == "function" then owner.is_current = opts.is_current end
			if type(opts.on_terminal) == "function" then owner.on_terminal = opts.on_terminal end
			if type(opts.resume_is_current) == "function" then
				resume_is_current = opts.resume_is_current
			else
				resume_is_current = owner.is_current
			end
		end
		local resume_pause_epoch = owner.pause_epoch or 0
		local current_results = owner_callback_results(owner,
			"MLX reattached local-resume freshness check", resume_is_current)
		local current = current_results[2]
		if current_results[1] ~= true or current ~= true
			or owner.pause_epoch ~= resume_pause_epoch
			or owner.revoked == true or owner.terminal_sent == true
			or download_owner ~= owner then return false end
		owner.paused = false
		for slot, pending in pairs(owner.deferred_timers or {}) do
			if schedule_owner_timer(owner, slot, pending.delay, pending.callback) ~= true then
				owner.paused = true
				return false
			end
			if owner.pause_epoch ~= resume_pause_epoch or owner.paused == true
				or owner.revoked == true or owner.terminal_sent == true
				or download_owner ~= owner then
				owner.paused = true
				return false
			end
			owner.deferred_timers[slot] = nil
		end
		if owner.pause_epoch ~= resume_pause_epoch or owner.paused == true
			or owner.revoked == true or owner.terminal_sent == true
			or download_owner ~= owner then
			owner.paused = true
			return false
		end
		if owner.tail_completion_pending == true
			and owner.timers.resume_commit == nil
			and (owner.deferred_timers == nil
				or owner.deferred_timers.resume_commit == nil) then
			local drain_after_resume_commit
			drain_after_resume_commit = function()
				if owner.tail_completion_pending ~= true then return true end
				-- The startup owner is resumed before ScriptControl publishes RESUMED.
				-- A later owner can still refuse and roll this monitor back in the same
				-- epoch, so terminal UI/session effects may cross only the globally-current
				-- callback supplied for the committed state.
				local globally_current_ok, globally_current = Logger.callback(LOG,
					"MLX reattached resume-commit freshness check", owner.is_current)
				if globally_current_ok ~= true or globally_current ~= true then
					owner.tail_completion_pending = true
					return schedule_owner_timer(owner, "resume_commit", 0.05,
						drain_after_resume_commit) == true
				end
				owner.tail_completion_pending = false
				if type(owner.finish_deferred_tail) == "function"
					and owner.finish_deferred_tail() == true then
					return true
				end
				owner.tail_completion_pending = true
				return schedule_owner_timer(owner, "resume_commit", 0.25,
					drain_after_resume_commit) == true
			end
			if schedule_owner_timer(owner, "resume_commit", 0,
				drain_after_resume_commit) ~= true then
				owner.paused = true
				return false
			end
		end
		return true
	end

	--- @return boolean active
	function obj.has_reattached_download()
		return download_owner ~= nil and download_owner.kind == "reattached"
	end

	--- Reattaches the download UI and log tail to an already-running detached Python download.
	--- Called after a Hammerspoon reload when /tmp/hs_mlx_active_download.json exists.
	--- @param session table Decoded JSON session: { model, log_path, exit_path, script_path, pid, repo }.
	--- @param opts table|nil Optional `is_current` and `on_terminal` callbacks.
	function obj.reattach_download(session, opts)
		if type(session) ~= "table" then return false end
		local model     = session.model     or "?"
		local log_path  = session.log_path  or ""
		local exit_path = session.exit_path or ""
		local derived_script_path = derive_download_script_path(log_path)
		local script_path = session.script_path == derived_script_path
			and session.script_path or derived_script_path
		local pid       = tonumber(session.pid)
		local session_file = "/tmp/hs_mlx_active_download.json"

		if download_owner ~= nil then
			Logger.warn(LOG, "Cannot reattach '%s': another MLX download owner is active.",
				tostring(model))
			return false
		end
		download_generation = download_generation + 1
		local owner = {
			kind = "reattached",
			active = true,
			generation = download_generation,
			attempt_generation = 1,
			tasks = { launcher = nil, tail = nil },
			timers = {},
			partial = {
				pid = pid,
				log_path = log_path,
				exit_path = exit_path,
				script_path = script_path,
			},
			registered = true,
			revoked = false,
			terminal_sent = false,
			session_published = true,
			paused = false,
			pause_epoch = 0,
			callback_depth = 1,
			timer_acquisition_depth = 0,
			tail_starting = false,
			deferred_timers = {},
			timer_deliveries = {},
			is_current = type(opts) == "table" and type(opts.is_current) == "function"
				and opts.is_current or function() return true end,
			on_terminal = type(opts) == "table" and opts.on_terminal or nil,
		}
		download_owner = owner
		local function finish_reattach_dispatch(result)
			owner.callback_depth = math.max(0, owner.callback_depth - 1)
			if owner.revoked == true or owner.terminal_sent == true then
				release_download_owner(owner)
			end
			return result
		end
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

		local function reattached_current()
			if owner.paused == true or owner.revoked == true or owner.terminal_sent == true
				or download_owner ~= owner then
				return false
			end
			local ok, current = Logger.callback(LOG,
				"MLX reattached freshness check", owner.is_current)
			return ok == true and current == true
				and owner.paused ~= true and owner.revoked ~= true
				and owner.terminal_sent ~= true and download_owner == owner
		end
		--- Checks whether a reattached callback may publish its next business effect.
		--- @return boolean authorized
		local function reattached_business_authorized()
			return owner.paused ~= true and download_owner == owner
		end
		if not reattached_current() then
			owner.paused = true
			return finish_reattach_dispatch(false)
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

		--- Reads exact reattached-tail liveness without treating probe failure as stopped.
		--- @param task any Exact native tail task.
		--- @return boolean|nil running Exact boolean state, or nil when inconclusive.
		local function reattached_tail_running_state(task)
			if task == nil then return false end
			local state_results = owner_callback_results(owner,
				"MLX reattached tail running-state probe", function()
					local method = task.isRunning
					if type(method) ~= "function" then
						error("task running-state method is unavailable")
					end
					return method(task)
				end)
			local running = state_results[2]
			if state_results[1] ~= true
				or (running ~= true and running ~= false) then
				Logger.error(LOG,
					"MLX reattached tail running-state probe was inconclusive: %s.",
					tostring(running))
				return nil
			end
			return running
		end

		--- Clears the exact stopped reattach tail while retaining its monitor sentinel.
		--- @param task any Exact native tail task.
		--- @return boolean cleared
		local function clear_reattached_tail(task)
			if owner.tasks.tail ~= task then return false end
			owner.tasks.tail = nil
			if deps.active_tasks and deps.active_tasks["download_tail"] == task then
				deps.active_tasks["download_tail"] = owner
			end
			return true
		end

		local function signal_tail()
			local task = owner.tasks.tail
			if task == nil then return true end
			local results = owner_callback_results(owner,
				"MLX reattached tail cancellation", function()
					local method = task.terminate
					if type(method) ~= "function" then
						error("task terminate method is unavailable")
					end
					return method(task)
				end)
			local result = results[2]
			local accepted = results[1] == true and result ~= false and result ~= nil
			if owner.tasks.tail ~= task then return true end
			if owner.tail_starting ~= true
				and reattached_tail_running_state(task) == false then
				clear_reattached_tail(task)
				return true
			end
			return accepted
		end

		local function probe_exit_file(read_code)
			if read_code ~= true then
				return probe_download_exit_file(exit_path,
					"MLX reattached exit-file probe")
			end
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
			if not reattached_business_authorized() then
				release_download_owner(owner)
				return false
			end
			update_icon("MLX reattach completion icon reset")
			if not reattached_business_authorized() then
				release_download_owner(owner)
				return false
			end
			if not silent then
				if success then
					pcall(notifications.notify, i18n.get("mlx.model_installed"),
						string.format(i18n.get("mlx.model_ready"), model), "success")
					if not reattached_business_authorized() then
						release_download_owner(owner)
						return false
					end
					if download_window then pcall(download_window.complete, true, model) end
				elseif reason == "user_cancelled" then
					pcall(notifications.notify, i18n.get("mlx.download_cancelled"),
						string.format(i18n.get("mlx.download_cancelled_body"), model), "warning")
					if not reattached_business_authorized() then
						release_download_owner(owner)
						return false
					end
					if download_window then pcall(download_window.complete, false, model) end
				elseif reason == "process_missing" then
					pcall(notifications.notify, i18n.get("mlx.download_interrupted"),
						string.format(i18n.get("mlx.download_interrupted_body"), model), "error")
					if not reattached_business_authorized() then
						release_download_owner(owner)
						return false
					end
					if download_window then pcall(download_window.complete, false, model) end
				else
					if download_window then pcall(download_window.complete, false, model) end
					if not reattached_business_authorized() then
						release_download_owner(owner)
						return false
					end
					pcall(notifications.notify, i18n.get("mlx.download_failed"),
						i18n.get("mlx.download_failed_body"), "error")
				end
			end
			if not reattached_business_authorized() then
				release_download_owner(owner)
				return false
			end
			if type(owner.on_terminal) == "function" then
				run_owner_callback(owner, "MLX reattached terminal observer",
					owner.on_terminal, success == true, reason)
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
			local exists = probe_exit_file(false)
			if exists == nil then return schedule_reattached_cleanup() end
			local live_pid = owner.partial.pid
			if exists == true then
				owner.partial.pid = nil
				owner.partial.pid_settled = true
				Logger.callback(LOG, "MLX reattached exit-file removal",
					os.remove, exit_path)
			elseif live_pid then
				local signal_name = next_pid_cleanup_signal(owner)
				local outcome = signal_verified_download_pid(live_pid,
					owner.partial.script_path, signal_name,
					"MLX reattached PID cleanup identity probe")
				record_pid_cleanup_attempt(owner, signal_name, outcome)
				if outcome == "gone" or outcome == "not_owned" then
					owner.partial.pid = nil
					owner.partial.pid_settled = true
				elseif outcome == "signalled" then
					return schedule_reattached_cleanup()
				else
					Logger.error(LOG, "MLX reattached cleanup retained PID %d after %s.",
						live_pid, outcome)
					return schedule_reattached_cleanup()
				end
			elseif owner.partial.pid_settled ~= true then
				return schedule_reattached_cleanup()
			end
			cancel_owner_timer(owner, "cleanup")
			if owner.tasks.tail ~= nil then return schedule_reattached_cleanup() end
			if owner.remove_session() ~= true then return schedule_reattached_cleanup() end
			if owner.retry_pending then
				if owner.paused == true then return schedule_reattached_cleanup() end
				local repo = session.repo or ""
				if repo == "" then
					owner.retry_pending = false
					owner.keep_registered = false
					settle_reattached(false, "retry_unavailable", false)
					return false
				end
				if owner_has_native_work(owner, true) then
					return schedule_reattached_cleanup()
				end
				owner.retry_pending = false
				owner.keep_registered = false
				owner.after_release = function()
					return obj.pull_model(model, repo, nil, nil)
				end
				release_download_owner(owner)
				return true
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
			cleanup_reattached()
			local continuation_authorized = reattached_business_authorized()
			if not retrying and continuation_authorized then
				settle_reattached(false, reason or "user_cancelled", silent)
				continuation_authorized = reattached_business_authorized()
			end
			if owner_has_native_work(owner) and owner.timers.cleanup == nil then
				schedule_reattached_cleanup()
			elseif not owner_has_native_work(owner) then
				cleanup_reattached()
			end
			return continuation_authorized
		end
		owner.cancel = do_cancel_reattached

		local function handle_done_reattached()
			if owner.paused == true then
				owner.tail_completion_pending = true
				return true
			end
			if not reattached_current() then
				if owner.paused == true then
					owner.tail_completion_pending = true
					return true
				end
				return false
			end
			if owner.completion_seen or owner.revoked then return false end
			local exists, exit_code = probe_exit_file(true)
			if owner.paused == true then
				owner.tail_completion_pending = true
				return true
			end
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
			if owner.paused == true then return true end
			if not reattached_current() then return false end
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
			if owner.paused == true then return true end
			if download_window then
				pcall(download_window.update, _current_pct, _bytes_done, _bytes_total, out, _python_file_count)
			end
			return true
		end

		-- Completion may already have happened between startup session discovery and
		-- owner registration. The same terminal path handles that case.
		local finished, finish_detail = probe_exit_file(false)
		if owner.paused == true then
			return finish_reattach_dispatch(false)
		end
		if finished == nil then
			do_cancel_reattached(false, finish_detail)
			return finish_reattach_dispatch(false)
		end
		if finished == true then
			return finish_reattach_dispatch(handle_done_reattached())
		end

		if owner.partial.pid then
			local ok_probe, alive = Logger.callback(LOG,
				"MLX reattached PID liveness probe", os.execute,
				"kill -0 " .. tostring(owner.partial.pid) .. " 2>/dev/null")
			if owner.paused == true then
				return finish_reattach_dispatch(false)
			end
			if not ok_probe then
				do_cancel_reattached(false, "pid_probe_failed")
				return finish_reattach_dispatch(false)
			end
			if alive ~= true and alive ~= 0 then
				owner.partial.pid = nil
				settle_reattached(false, "process_missing", false)
				owner.remove_session()
				release_download_owner(owner)
				return finish_reattach_dispatch(false)
			end
		end

		local poll_exit_reattached
		local function defer_poll_exit_reattached()
			owner.deferred_timers.poll = {
				delay = 3,
				callback = poll_exit_reattached,
			}
			return true
		end

		poll_exit_reattached = function()
			if owner.paused == true then
				return defer_poll_exit_reattached()
			end
			if not reattached_current() then
				if owner.paused == true then return defer_poll_exit_reattached() end
				return false
			end
			if owner.revoked or owner.terminal_sent then return false end
			local exists = probe_exit_file(false)
			if owner.paused == true then
				if exists == true then
					owner.tail_completion_pending = true
					return true
				end
				return defer_poll_exit_reattached()
			end
			if exists == nil then
				do_cancel_reattached(false, "exit_file_probe_failed")
				return false
			end
			if exists == true then return handle_done_reattached() end
			if owner.paused == true then return defer_poll_exit_reattached() end
			if not schedule_owner_timer(owner, "poll", 3, poll_exit_reattached) then
				if owner.paused == true then return true end
				do_cancel_reattached(false, "poll_timer_refused")
				return false
			end
			return true
		end
		if not schedule_owner_timer(owner, "poll", 3, poll_exit_reattached) then
			if owner.paused == true then
				return finish_reattach_dispatch(false)
			end
			do_cancel_reattached(false, "poll_timer_refused")
			return finish_reattach_dispatch(false)
		end
		if owner.paused == true then return finish_reattach_dispatch(false) end

		-- Open (or re-focus) the download window
		if download_window then
			pcall(download_window.show, {
				kind = "mlx_model",
				model = model,
				terminal_cmd = "tail -f " .. log_path,
				on_cancel = function(...)
					return run_owner_callback(owner,
						"MLX reattached cancel UI callback", function(...)
							if not reattached_current() then return false end
							return do_cancel_reattached(...)
						end, ...)
				end,
				on_retry = function()
					return run_owner_callback(owner,
						"MLX reattached retry UI callback", function()
							if not reattached_current() then return false end
							if owner.retry_pending or owner.terminal_sent then return false end
							return do_cancel_reattached(true, "retry")
						end)
				end,
			})
		end
		if owner.paused == true then return finish_reattach_dispatch(false) end

		-- Start a new tail -f on the existing log file
		local tail_task
		local tail_starting = true
		local tail_start_committed = false
		local pending_tail_completion = false
		local pending_tail_chunks = {}
		owner.tail_starting = true
		local function finish_tail()
			if owner.tasks.tail ~= tail_task then return false end
			owner.tasks.tail = nil
			if deps.active_tasks and deps.active_tasks["download_tail"] == tail_task then
				deps.active_tasks["download_tail"] = owner
			end
			if owner.paused == true then
				owner.tail_completion_pending = true
				return true
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
			if not reattached_current() then
				if owner.paused == true then
					owner.tail_completion_pending = true
					return true
				end
				return false
			end
			if not schedule_owner_timer(owner, "tail_done", 0.5, handle_done_reattached) then
				if owner.paused == true then return true end
				return poll_exit_reattached()
			end
			return true
		end
		owner.finish_deferred_tail = function()
			local settled = handle_done_reattached()
			if settled == true or owner.terminal_sent == true then return true end
			return owner.timers.poll ~= nil
				or (owner.deferred_timers and owner.deferred_timers.poll ~= nil)
		end

		tail_task = TaskLifecycle.native("MLX reattached download log tail", "/usr/bin/tail", function()
			if tail_starting then
				pending_tail_completion = true
				return true
			end
			owner.callback_depth = owner.callback_depth + 1
			local callback_ok, callback_result = Logger.callback(LOG,
				"MLX reattached tail completion callback", finish_tail)
			owner.callback_depth = owner.callback_depth - 1
			if owner.revoked == true or owner.terminal_sent == true then
				release_download_owner(owner)
			end
			if callback_ok ~= true then return false end
			return callback_result
		end, function(_, stdout, stderr)
			local chunk = (stdout or "") .. (stderr or "")
			if tail_starting then
				if pending_tail_completion then return false end
				pending_tail_chunks[#pending_tail_chunks + 1] = chunk
				return true
			end
			if tail_start_committed ~= true or owner.tasks.tail ~= tail_task then
				return false
			end
			owner.callback_depth = owner.callback_depth + 1
			local callback_ok, callback_result = Logger.callback(LOG,
				"MLX reattached tail stream callback",
				process_stream_reattached, chunk)
			owner.callback_depth = owner.callback_depth - 1
			if owner.revoked == true or owner.terminal_sent == true then
				release_download_owner(owner)
			end
			return callback_ok == true and callback_result ~= false
		end, {"-F", "-n", "+1", log_path})

		if tail_task then
			owner.tasks.tail = tail_task
			if deps.active_tasks then deps.active_tasks["download_tail"] = tail_task end
			local started = TaskLifecycle.start(tail_task, "MLX reattached download log tail")
			tail_starting = false
			owner.tail_starting = false
			local tail_running = nil
			if started == true and pending_tail_completion ~= true then
				tail_running = reattached_tail_running_state(tail_task)
			end
			if started ~= true
				or (pending_tail_completion ~= true and tail_running ~= true) then
				pending_tail_chunks = {}
				local task_settled = pending_tail_completion or tail_running == false
				if task_settled ~= true then
					signal_tail()
					task_settled = owner.tasks.tail ~= tail_task
				end
				if task_settled then
					clear_reattached_tail(tail_task)
				end
				-- Keep the logical monitor sentinel: the exit-file poll remains the
				-- reliable completion backstop even when streaming cannot start.
				if deps.active_tasks and owner.tasks.tail == nil then
					deps.active_tasks["download_tail"] = owner
				end
			else
				tail_start_committed = true
				if owner.paused == true then
					pending_tail_chunks = {}
					if pending_tail_completion then
						owner.tail_completion_pending = true
					end
					return finish_reattach_dispatch(false)
				end
				for _, chunk in ipairs(pending_tail_chunks) do
					if owner.tasks.tail ~= tail_task
						or process_stream_reattached(chunk) ~= true then
						pending_tail_chunks = {}
						signal_tail()
						return finish_reattach_dispatch(false)
					end
				end
				pending_tail_chunks = {}
				if pending_tail_completion then finish_tail() end
			end
		else
			tail_starting = false
			owner.tail_starting = false
			pending_tail_chunks = {}
		end
		if owner.paused == true then return finish_reattach_dispatch(false) end

		Logger.success(LOG, "Reattached download tail for '%s'.", model)
		return finish_reattach_dispatch(true)
	end
end

return M
