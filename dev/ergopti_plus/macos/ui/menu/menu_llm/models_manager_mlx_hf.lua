--- ui/menu/menu_llm/models_manager_mlx_hf.lua

--- ==============================================================================
--- MODULE: MLX Models Manager — HuggingFace Auth & Model Source
--- DESCRIPTION:
--- Attaches the HuggingFace login flow and model-source/repo helpers onto the
--- shared MLX models-manager object. Resolves a model's MLX repo, opens its
--- HuggingFace page, drives the token-entry webview, and persists a validated
--- token through a Python subprocess.
---
--- FEATURES & RATIONALE:
--- 1. Shared-context mixin: install(ctx) attaches its methods onto ctx.obj, so the
---    factory's other methods (start_server, check_requirements) keep calling
---    obj.get_mlx_repo unchanged while this auth/catalogue logic lives on its own.
--- 2. Self-contained auth: the token webview and its validation subprocess are
---    isolated from the server-lifecycle and download logic.
--- 3. Shared token frontend: prompt_hf_login loads the token UI from the
---    cross-driver _shared/ui/token_prompt/ tree (resolved via Paths.shared), so
---    the same frontend can later back a Windows WebView2 host.
--- ==============================================================================

local M = {}

local hs            = hs
local notifications = require("infra.notifications")
local ui_builder    = require("ui.ui_builder")
local i18n          = require("infra.i18n")
local Paths         = require("infra.paths")
local TaskLifecycle = require("adapters.task_lifecycle")
local TimerScheduler = require("adapters.timer_scheduler")
local Logger        = require("infra.logger")

local LOG = "menu_llm.models.mlx_hf"

local HF_TOKEN_FILE = (os.getenv("HOME") or "") .. "/.huggingface/token"




-- =====================================================
--- =====================================================
-- ======= 1/ HuggingFace Auth & Model Source =========
--- =====================================================
-- =====================================================

--- Attaches the HuggingFace auth + model-source methods onto the manager object.
--- @param ctx table Shared context: { obj = manager object, deps = injected deps,
---   presets = model catalogue }.
function M.install(ctx)
	local obj, deps, presets = ctx.obj, ctx.deps, ctx.presets
	local active_flow = nil
	local try_release_flow
	local pause_flow_ui_timers
	local schedule_flow_ui_timer

	--- Checks the exact requirement/download provenance for one auth flow.
	--- @param flow table HuggingFace auth owner.
	--- @return boolean authorized
	local function flow_is_authorized(flow)
		if type(flow) ~= "table" or flow.authorized ~= true then return false end
		local ok, authorized = xpcall(flow.provenance.is_authorized,
			debug.traceback)
		return ok == true and authorized == true
	end

	--- Reports whether any native or callback capability remains below a flow.
	--- @param flow table HuggingFace auth owner.
	--- @return boolean live
	local function flow_has_live_work(flow)
		return flow.timer_owner ~= nil
			or flow.prompt_callback_expected == true
			or flow.webview ~= nil
			or flow.webview_installing == true
			or flow.task ~= nil
			or flow.task_starting == true
			or (tonumber(flow.callback_depth) or 0) > 0
			or (type(flow.ui_timer_owners) == "table"
				and next(flow.ui_timer_owners) ~= nil)
	end

	--- Publishes one business terminal only after every exact child has settled.
	--- @param flow table HuggingFace auth owner.
	--- @param result boolean Terminal login result.
	--- @param label string Diagnostic callback label.
	--- @return boolean accepted
	local function request_terminal(flow, result, label)
		if flow.terminal_sent == true then return false end
		if flow.pending_terminal ~= nil then
			-- The logical result was already fenced while a native child remained.
			-- Its late exact completion must retry provenance release without
			-- replacing or duplicating that first business terminal.
			try_release_flow(flow)
			return false
		end
		flow.pending_terminal = { result = result == true, label = label }
		try_release_flow(flow)
		return true
	end

	--- Releases exact requirement provenance, then delivers at most one authorized
	--- terminal. A PAUSE-revoked flow settles structurally without invoking callers.
	--- @param flow table HuggingFace auth owner.
	--- @return boolean settled
	try_release_flow = function(flow)
		if flow_has_live_work(flow) then return false end
		local terminal = flow.pending_terminal
		if terminal ~= nil and flow.terminal_sent ~= true then
			flow.pending_terminal = nil
			flow.terminal_sent = true
			local deliver = flow_is_authorized(flow)
			flow.callback_depth = (flow.callback_depth or 0) + 1
			if flow.direct_operation ~= nil then
				local callback = deliver and flow.on_done or nil
				local ok, result = xpcall(function()
					return flow.direct_operation.finish(callback, terminal.label,
						terminal.result)
				end, debug.traceback)
				if ok ~= true then
					Logger.error(LOG, "HuggingFace direct terminal raised: %s.",
						tostring(result))
				end
			elseif deliver and type(flow.on_done) == "function" then
				Logger.callback(LOG, terminal.label, flow.on_done, terminal.result)
			end
			flow.callback_depth = flow.callback_depth - 1
		end
		if flow_has_live_work(flow) then return false end
		if flow.requirement_registered == true then
			local ok, released = xpcall(function()
				return flow.provenance.lifecycle.settle(flow)
			end, debug.traceback)
			if ok ~= true or released ~= true then
				Logger.error(LOG, "HuggingFace auth-flow settlement refused: %s.",
					tostring(released))
				return false
			end
			flow.requirement_registered = false
		end
		if active_flow == flow then active_flow = nil end
		return true
	end

	--- Proves that a start-refused task never became live.
	--- @param task any Exact native task.
	--- @return boolean stopped
	local function task_proven_not_running(task)
		local ok_method, method = xpcall(function() return task and task.isRunning end,
			debug.traceback)
		if not ok_method or type(method) ~= "function" then return false end
		local ok, running = xpcall(function() return method(task) end,
			debug.traceback)
		return ok == true and running == false
	end

	--- Fences, cancels, and joins every native child of one auth flow.
	--- @param flow table HuggingFace auth owner.
	--- @return boolean settled
	local function pause_flow(flow)
		flow.pause_depth = (flow.pause_depth or 0) + 1
		flow.authorized = false
		flow.prompt_callback_expected = false
		local settled = true
		local timer_owner = flow.timer_owner
		if timer_owner ~= nil then
			timer_owner.authorized = false
			timer_owner.committed = false
			if timer_owner.handle == nil then
				settled = timer_owner.installing ~= true and settled
				if timer_owner.installing ~= true then flow.timer_owner = nil end
			else
				local ok, result = xpcall(function()
					return TimerScheduler.cancel(timer_owner.handle)
				end, debug.traceback)
				if ok == true and result == true then
					if flow.timer_owner == timer_owner then flow.timer_owner = nil end
				else
					settled = false
				end
			end
		end
		if flow.webview ~= nil then
			local close_ok, closed = xpcall(function()
				if type(flow.close_webview) ~= "function" then return false end
				return flow.close_webview(nil, true)
			end, debug.traceback)
			if close_ok ~= true or closed ~= true then
				settled = false
			end
		end
		if type(pause_flow_ui_timers) == "function"
			and pause_flow_ui_timers(flow) ~= true then
			settled = false
		end
		if flow.task ~= nil then
			local task = flow.task
			if flow.task_termination_accepted ~= true then
				local accepted = TaskLifecycle.terminate(task,
					"HuggingFace login pause")
				-- A synchronous native completion is stronger settlement evidence
				-- than a terminate() implementation that mutates then returns false,
				-- nil, or throws.
				if flow.task ~= task then
					flow.task_termination_accepted = false
				else
					flow.task_termination_accepted = accepted == true
				end
			end
			-- `isRunning()==false` is not settlement evidence while the native
			-- constructor/start boundary is still on-stack: the same start call may
			-- activate immediately after a nested PAUSE returns. Keep the published
			-- exact candidate owned until that boundary unwinds and compensates it.
			if flow.task == task and flow.task_starting == true then
				settled = false
			elseif flow.task == task and task_proven_not_running(task) then
				if deps.active_tasks
					and deps.active_tasks["hf_login"] == task then
					deps.active_tasks["hf_login"] = nil
				end
				flow.task = nil
				flow.task_starting = false
				flow.task_committed = false
				flow.task_termination_accepted = false
				flow.task_terminal_consumed = true
			elseif flow.task == task then
				settled = false
			end
			if flow.task ~= nil then settled = false end
		end
		try_release_flow(flow)
		flow.pause_depth = flow.pause_depth - 1
		return settled == true and not flow_has_live_work(flow)
	end

	--- Resolves passed download provenance or acquires the existing direct
	--- maintenance capability used by the selector path.
	--- @param on_done function|nil Business terminal callback.
	--- @param passed table|nil `{ owner, lifecycle, is_authorized }`.
	--- @return table|nil flow Exact auth-flow owner.
	local function begin_flow(on_done, passed)
		if active_flow ~= nil then
			Logger.error(LOG,
				"HuggingFace login refused while a prior exact flow remains owned.")
			return nil
		end
		local provenance = passed
		local direct_operation = nil
		if type(provenance) ~= "table" then
			if type(ctx.begin_direct_operation) ~= "function" then
				Logger.error(LOG,
					"Direct HuggingFace prompt has no registered pause provenance.")
				return nil
			end
			local ok, operation = xpcall(function()
				return ctx.begin_direct_operation("HuggingFace token prompt")
			end, debug.traceback)
			if ok ~= true or type(operation) ~= "table" then
				Logger.error(LOG,
					"Direct HuggingFace prompt capability acquisition was refused.")
				return nil
			end
			direct_operation = operation
			provenance = {
				owner = operation,
				lifecycle = operation.lifecycle,
				is_authorized = operation.is_authorized,
			}
		end
		if type(provenance.owner) ~= "table"
			or type(provenance.lifecycle) ~= "table"
			or type(provenance.lifecycle.adopt) ~= "function"
			or type(provenance.lifecycle.settle) ~= "function"
			or type(provenance.is_authorized) ~= "function" then
			Logger.error(LOG, "HuggingFace prompt provenance is incomplete.")
			if direct_operation ~= nil then
				direct_operation.finish(nil,
					"HuggingFace provenance refusal", false)
			end
			return nil
		end
		local flow = {
			provenance = provenance,
			direct_operation = direct_operation,
			on_done = on_done,
			authorized = true,
			requirement_registered = false,
			terminal_sent = false,
			pending_terminal = nil,
			timer_owner = nil,
			prompt_callback_expected = false,
			webview = nil,
			webview_installing = false,
			webview_delete_accepted = false,
			webview_close_requested = false,
			webview_closed_during_install = false,
			webview_terminal_consumed = false,
			pending_webview_terminal = nil,
			pending_token = nil,
			callback_depth = 0,
			pause_depth = 0,
			ui_timer_owners = {},
			webview_continuation_pending = false,
			prompt_action_consumed = false,
			task = nil,
			task_starting = false,
			task_termination_accepted = false,
			task_committed = false,
			task_terminal_consumed = false,
		}
		active_flow = flow
		local adopt_ok, adopted = xpcall(function()
			return provenance.lifecycle.adopt(flow, pause_flow,
				"HuggingFace prompt/webview/task")
		end, debug.traceback)
		if adopt_ok ~= true or adopted ~= true then
			active_flow = nil
			Logger.error(LOG, "HuggingFace auth-flow adoption was refused.")
			if direct_operation ~= nil then
				direct_operation.finish(nil, "HuggingFace adoption refusal", false)
			end
			return nil
		end
		flow.requirement_registered = true
		if not flow_is_authorized(flow) then
			flow.authorized = false
			request_terminal(flow, false, "HuggingFace admission refusal")
			return nil
		end
		return flow
	end

	local function run_flow_callback(flow, label, callback, ...)
		flow.callback_depth = (flow.callback_depth or 0) + 1
		local args = table.pack(...)
		local ok, result = xpcall(function()
			return callback(table.unpack(args, 1, args.n))
		end, debug.traceback)
		flow.callback_depth = flow.callback_depth - 1
		if ok ~= true then
			Logger.error(LOG, "%s raised: %s.", tostring(label), tostring(result))
			request_terminal(flow, false, tostring(label) .. " failure")
		end
		try_release_flow(flow)
		return ok == true, result
	end

	local function notify_ui_timers_settled(flow)
		if next(flow.ui_timer_owners) ~= nil then return false end
		if type(flow.on_ui_timers_settled) == "function" then
			local callback = flow.on_ui_timers_settled
			flow.on_ui_timers_settled = nil
			run_flow_callback(flow, "HuggingFace webview timer settlement",
				callback)
		end
		try_release_flow(flow)
		return true
	end

	local function release_ui_timer(flow, owner)
		if flow.ui_timer_owners[owner] ~= true then return false end
		flow.ui_timer_owners[owner] = nil
		notify_ui_timers_settled(flow)
		return true
	end

	pause_flow_ui_timers = function(flow)
		local owners = {}
		for owner in pairs(flow.ui_timer_owners) do owners[#owners + 1] = owner end
		local settled = true
		for _, owner in ipairs(owners) do
			if flow.ui_timer_owners[owner] == true then
				owner.authorized = false
				owner.committed = false
				if owner.callback_running == true
					or (owner.handle == nil and owner.installing == true) then
					settled = false
				elseif owner.handle == nil then
					release_ui_timer(flow, owner)
				else
					local ok, result = xpcall(function()
						return TimerScheduler.cancel(owner.handle)
					end, debug.traceback)
					if ok == true and result == true
						and owner.callback_running ~= true then
						owner.native_settled = true
						release_ui_timer(flow, owner)
					else
						settled = false
					end
				end
			end
		end
		return settled == true and next(flow.ui_timer_owners) == nil
	end

	schedule_flow_ui_timer = function(flow, delay, callback, label)
		if not flow_is_authorized(flow) or type(callback) ~= "function" then
			return false
		end
		local owner = {
			handle = nil,
			authorized = true,
			committed = false,
			installing = true,
			native_settled = false,
			callback_pending = false,
			callback_running = false,
			callback_consumed = false,
		}
		flow.ui_timer_owners[owner] = true

		local function deliver()
			if owner.callback_pending ~= true or owner.callback_consumed == true
				or owner.native_settled ~= true or owner.committed ~= true then
				return false
			end
			owner.callback_consumed = true
			owner.callback_pending = false
			owner.callback_running = true
			flow.callback_depth = (flow.callback_depth or 0) + 1
			local ok, err = true, nil
			if owner.authorized == true and flow_is_authorized(flow) then
				ok, err = xpcall(callback, debug.traceback)
			end
			flow.callback_depth = flow.callback_depth - 1
			owner.callback_running = false
			if ok ~= true then
				Logger.error(LOG, "HuggingFace %s callback raised: %s.",
					tostring(label), tostring(err))
			end
			release_ui_timer(flow, owner)
			return ok == true
		end

		local schedule_ok, handle_or_error, committed = xpcall(function()
			return TimerScheduler.after(delay, function()
				if owner.callback_consumed == true or owner.callback_pending == true then
					return
				end
				owner.callback_pending = true
				if owner.installing ~= true then deliver() end
			end)
		end, debug.traceback)
		owner.installing = false
		if schedule_ok == true and type(handle_or_error) == "table" then
			owner.handle = handle_or_error
			local observed_ok, observed = xpcall(function()
				return TimerScheduler.onSettled(handle_or_error, function()
					owner.native_settled = true
					deliver()
					if owner.callback_consumed == true
						and owner.callback_running ~= true then
						release_ui_timer(flow, owner)
					elseif owner.authorized ~= true then
						release_ui_timer(flow, owner)
					end
				end)
			end, debug.traceback)
			if observed_ok ~= true or observed ~= true then committed = false end
		end
		if schedule_ok ~= true or type(handle_or_error) ~= "table"
			or committed ~= true then
			owner.authorized = false
			owner.committed = false
			if owner.handle ~= nil then
				local ok, stopped = xpcall(function()
					return TimerScheduler.cancel(owner.handle)
				end, debug.traceback)
				if ok == true and stopped == true then release_ui_timer(flow, owner) end
			else
				release_ui_timer(flow, owner)
			end
			return false
		end
		if owner.authorized ~= true or not flow_is_authorized(flow) then
			pause_flow_ui_timers(flow)
			return false
		end
		owner.committed = true
		deliver()
		return true
	end

	local function read_hf_token()
		local fh = io.open(HF_TOKEN_FILE, "r")
		if not fh then return nil end
		local raw = fh:read("*a")
		fh:close()
		local token = raw and raw:match("^%s*(.-)%s*$") or ""
		return token ~= "" and token or nil
	end

	function obj.get_mlx_repo(model_name)
		for _, provider in ipairs(presets) do
			for _, family in ipairs(provider.families or {}) do
				for _, m in ipairs(family.models or {}) do
					if m.name == model_name and m.urls and m.urls.mlx then
						return (m.urls.mlx:gsub("^https?://huggingface%.co/", ""))
					end
				end
			end
		end
		-- Custom user-added models are passed straight through: a HuggingFace
		-- repo path ("org/model-name") is the canonical MLX identifier and
		-- mlx_lm.server / huggingface_hub resolve it natively. Without this
		-- fallback, check_requirements would refuse any model the user adds
		-- via the "Ajouter un modèle personnalisé" menu entry.
		if type(model_name) == "string" and model_name:match("^[%w%._%-]+/[%w%._%-]+$") then
			return model_name
		end
		return nil
	end

	function obj.open_model_source_page(model_name)
		if type(ctx.begin_direct_operation) ~= "function" then
			Logger.error(LOG,
				"HuggingFace model-source navigation has no registered pause provenance.")
			return false
		end
		local operation_ok, operation = xpcall(function()
			return ctx.begin_direct_operation("HuggingFace model-source navigation")
		end, debug.traceback)
		if operation_ok ~= true or type(operation) ~= "table"
			or type(operation.lifecycle) ~= "table"
			or type(operation.lifecycle.adopt) ~= "function"
			or type(operation.lifecycle.settle) ~= "function"
			or type(operation.is_authorized) ~= "function"
			or type(operation.finish) ~= "function" then
			Logger.error(LOG,
				"HuggingFace model-source navigation ownership was refused.")
			return false
		end

		-- Keep the synchronous URL/notification continuation visible to PAUSE.
		-- A nested pause revokes it and returns false until this exact Lua/native
		-- boundary unwinds; no follow-up notification is then allowed through.
		local boundary = { running = true, authorized = true }
		local function pause_boundary()
			boundary.authorized = false
			return boundary.running ~= true
		end
		local adopt_ok, adopted = xpcall(function()
			return operation.lifecycle.adopt(boundary, pause_boundary,
				"HuggingFace model-source navigation callback")
		end, debug.traceback)
		if adopt_ok ~= true or adopted ~= true then
			boundary.running = false
			operation.finish(nil,
				"HuggingFace model-source navigation adoption refusal")
			return false
		end
		local function finish_boundary(label)
			boundary.running = false
			operation.lifecycle.settle(boundary)
			operation.finish(nil, label)
		end

		local repo = obj.get_mlx_repo(model_name)
		if type(repo) ~= "string" or repo == "" then
			-- The error notification is a native UI boundary too.  Keep it below the
			-- direct-operation child so a re-entrant PAUSE remains pending until send()
			-- returns instead of publishing PAUSED while the notification is in flight.
			xpcall(function()
				return notifications.notify(i18n.get("mlx.source_not_found"),
					i18n.get("mlx.source_not_found_body"), "error")
			end, debug.traceback)
			finish_boundary("HuggingFace model-source lookup refusal")
			return false
		end

		local url = "https://huggingface.co/" .. repo
		local ok_open, opened = xpcall(function()
			return hs.urlevent.openURL(url)
		end, debug.traceback)
		local authorized_ok, authorized = xpcall(operation.is_authorized,
			debug.traceback)
		if ok_open ~= true or opened ~= true
			or authorized_ok ~= true or authorized ~= true
			or boundary.authorized ~= true then
			if authorized_ok == true and authorized == true
				and boundary.authorized == true then
				pcall(notifications.notify, i18n.get("mlx.source_not_found"),
					i18n.get("mlx.open_source_failed"), "error")
			end
			finish_boundary("HuggingFace model-source navigation refusal")
			return false
		end

		pcall(notifications.notify, i18n.get("mlx.hf_login_title"),
			i18n.get("mlx.hf_page_opened"), "info")
		authorized_ok, authorized = xpcall(operation.is_authorized,
			debug.traceback)
		if authorized_ok ~= true or authorized ~= true
			or boundary.authorized ~= true then
			finish_boundary("HuggingFace model-source notification revocation")
			return false
		end
		finish_boundary("HuggingFace model-source navigation terminal")
		return true
	end

	--- Opens the token webview below an already-adopted exact auth-flow owner.
	--- `flow.webview_installing` is published by the timer continuation before
	--- this function crosses any UI boundary, so a reentrant PAUSE can join it.
	--- @param flow table Exact auth-flow owner.
	local function open_hf_prompt_impl(flow)
		if not flow_is_authorized(flow) then
			flow.webview_installing = false
			try_release_flow(flow)
			return false
		end

		local hs_app = hs.application and hs.application.get
			and hs.application.get("Hammerspoon") or nil
		if not hs_app and hs.application and hs.application.find then
			hs_app = hs.application.find("Hammerspoon")
		end
		if hs_app and type(hs_app.activate) == "function"
			and flow_is_authorized(flow) then
			pcall(function() hs_app:activate(true) end)
		end

		local hf_token_url = "https://huggingface.co/settings/tokens"
		local clipboard_token_raw = hs.pasteboard and hs.pasteboard.getContents
			and hs.pasteboard.getContents() or ""
		local clipboard_token = type(clipboard_token_raw) == "string"
			and clipboard_token_raw:match("^%s*(.-)%s*$") or ""
		local token_seed = clipboard_token:match("^hf_[%w_%-]+$")
			and clipboard_token or ""
		if token_seed == "" then token_seed = read_hf_token() or "" end
		if not flow_is_authorized(flow) then
			flow.webview_installing = false
			try_release_flow(flow)
			return false
		end

		local function continue_after_webview()
			if flow.webview_continuation_pending ~= true
				or next(flow.ui_timer_owners) ~= nil then
				return false
			end
			flow.webview_continuation_pending = false
			local token = flow.pending_token
			local terminal = flow.pending_webview_terminal
			flow.pending_token = nil
			flow.pending_webview_terminal = nil
			if not flow_is_authorized(flow) then
				try_release_flow(flow)
				return
			end
			if type(token) == "string" and token ~= "" then
				local ok, accepted = xpcall(function()
					return obj._process_hf_token(token, flow.on_done, flow)
				end, debug.traceback)
				if ok ~= true or accepted ~= true then
					request_terminal(flow, false,
						"HuggingFace token-processing dispatch refusal")
				end
				return
			end
			request_terminal(flow, false,
				terminal or "HuggingFace prompt close")
			return true
		end

		local function after_webview_settled()
			if flow.webview_terminal_consumed == true then return end
			flow.webview_terminal_consumed = true
			flow.webview = nil
			flow.webview_installing = false
			flow.webview_delete_accepted = false
			flow.webview_close_requested = false
			flow.webview_continuation_pending = true
			flow.on_ui_timers_settled = continue_after_webview
			-- When close is delivered synchronously from pause_flow(), that caller
			-- will cancel the timer registry exactly once after delete() unwinds.
			-- A natural/asynchronous close owns the same cancellation here.
			if (tonumber(flow.pause_depth) or 0) == 0 then
				pause_flow_ui_timers(flow)
			end
			continue_after_webview()
		end

		local function on_webview_close()
			run_flow_callback(flow, "HuggingFace webview close", function()
				if flow.webview_terminal_consumed == true then return end
				if flow.webview_installing == true and flow.webview == nil then
					flow.webview_closed_during_install = true
					return
				end
				after_webview_settled()
			end)
		end

		flow.close_webview = function(token, paused, terminal_label)
			if paused == true then
				flow.pending_token = nil
				flow.pending_webview_terminal = nil
			elseif type(token) == "string" and token ~= "" then
				flow.pending_token = token
				flow.pending_webview_terminal = nil
			else
				flow.pending_token = nil
				flow.pending_webview_terminal = terminal_label
					or "HuggingFace prompt cancellation"
			end
			local webview = flow.webview
			if webview == nil then
				return flow.webview_installing ~= true
			end
			if flow.webview_close_requested == true then return false end
			flow.webview_close_requested = true
			local ok, accepted = xpcall(function()
				if type(webview.delete) ~= "function" then
					error("HuggingFace token webview has no delete method")
				end
				return webview:delete()
			end, debug.traceback)
			-- The close callback is stronger settlement evidence than a misleading
			-- nil/false/throwing delete return from a mutating native implementation.
			if flow.webview == nil then return true end
			if ok ~= true or accepted == false or accepted == nil then
				flow.webview_close_requested = false
				Logger.error(LOG,
					"HuggingFace token webview deletion refused: %s.",
					tostring(accepted))
				return false
			end
			flow.webview_delete_accepted = true
			return flow.webview == nil
		end

		local ucc_ok, ucc = xpcall(function()
			return hs.webview.usercontent.new("token_bridge")
		end, debug.traceback)
		if ucc_ok ~= true or ucc == nil or ucc == false then
			flow.webview_installing = false
			request_terminal(flow, false,
				"HuggingFace prompt bridge construction failure")
			return false
		end
		if not flow_is_authorized(flow) then
			flow.webview_installing = false
			try_release_flow(flow)
			return false
		end

		local callback_ok, callback_result = xpcall(function()
			return ucc:setCallback(function(msg)
				local ok, result = run_flow_callback(flow,
					"HuggingFace webview message", function()
						if type(msg) ~= "table" or not flow_is_authorized(flow) then return end
						if msg.body == "open_link" then
							pcall(hs.urlevent.openURL, hf_token_url)
							return
						end
						if flow.prompt_action_consumed == true then return end
						if msg.body == "cancel" then
							flow.prompt_action_consumed = true
							flow.close_webview(nil, false,
								"HuggingFace prompt cancellation")
							return
						end
						if type(msg.body) ~= "table" or msg.body.type ~= "validate" then
							return
						end
						flow.prompt_action_consumed = true
						local token = type(msg.body.token) == "string"
							and msg.body.token:match("^%s*(.-)%s*$") or ""
						if token == "" and token_seed ~= "" then
							token = token_seed
							pcall(notifications.notify, i18n.get("mlx.token_detected"),
								i18n.get("mlx.token_detected_body"), "success")
						elseif token ~= "" and token_seed ~= ""
							and #token_seed > #token
							and token_seed:sub(-#token) == token then
							token = token_seed
							pcall(notifications.notify, i18n.get("mlx.token_corrected"),
								i18n.get("mlx.token_corrected_body"), "success")
						end
						if token == "" then
							pcall(notifications.notify, i18n.get("mlx.token_missing"),
								i18n.get("mlx.token_missing_body"), "error")
							flow.close_webview(nil, false,
								"HuggingFace empty-token result")
							return
						end
						flow.close_webview(token, false)
					end)
				if ok == true then return result end
			end)
		end, debug.traceback)
		if callback_ok ~= true or callback_result == false
			or callback_result == nil then
			flow.webview_installing = false
			request_terminal(flow, false,
				"HuggingFace prompt bridge callback refusal")
			return false
		end
		if not flow_is_authorized(flow) then
			flow.webview_installing = false
			try_release_flow(flow)
			return false
		end

		local screen = hs.screen.mainScreen()
		local f = screen and type(screen.frame) == "function" and screen:frame()
			or { x = 0, y = 0, w = 1920, h = 1080 }
		local W, H = 1560, 400
		local frame = {
			x = math.floor(f.x + (f.w - W) / 2),
			y = math.floor(f.y + (f.h - H) / 2),
			w = W,
			h = H,
		}
		local TOKEN_ASSETS_DIR = (Paths.shared("ui/token_prompt") or "") .. "/"
		if not flow_is_authorized(flow) then
			flow.webview_installing = false
			try_release_flow(flow)
			return false
		end
		local show_ok, webview = xpcall(function()
			return ui_builder.show_webview({
				frame             = frame,
				title             = i18n.get("mlx.hf_login_title"),
				style_masks       = { "titled", "closable", "nonactivating" },
				level             = hs.drawing.windowLevels.floating,
				allow_text_entry  = true,
				allow_new_windows = false,
				usercontent       = ucc,
				assets_dir        = TOKEN_ASSETS_DIR,
				on_close          = on_webview_close,
				on_webview_created = function(candidate)
					if flow.webview ~= nil then return false end
					flow.webview = candidate
					return flow_is_authorized(flow)
				end,
				schedule_after = function(delay, callback, label)
					return schedule_flow_ui_timer(flow, delay, callback, label)
				end,
				is_current = function()
					return flow_is_authorized(flow)
				end,
			})
		end, debug.traceback)
		if show_ok ~= true or webview == nil or webview == false then
			flow.webview_installing = false
			if flow.webview ~= nil and type(flow.close_webview) == "function" then
				local close_ok, closed = xpcall(function()
					return flow.close_webview(nil, true)
				end, debug.traceback)
				if close_ok ~= true or closed ~= true then
					Logger.error(LOG,
						"HuggingFace failed webview factory remains owned: %s.",
						tostring(closed))
				end
			end
			request_terminal(flow, false,
				"HuggingFace prompt webview construction failure")
			return false
		end
		if flow.webview ~= webview then
			flow.webview_installing = false
			request_terminal(flow, false,
				"HuggingFace prompt webview identity refusal")
			return false
		end
		flow.webview_installing = false
		if flow.webview_closed_during_install == true then
			flow.webview_closed_during_install = false
			after_webview_settled()
			return true
		end
		if not flow_is_authorized(flow) then
			flow.close_webview(nil, true)
			try_release_flow(flow)
		end
		return true
	end

	--- Contains every prompt-construction boundary and converts an exception into
	--- an exact terminal. In particular, the published `webview_installing` child
	--- must never strand the sole auth-flow owner when a native lookup raises.
	--- @param flow table Exact auth-flow owner.
	--- @return boolean committed
	local function open_hf_prompt(flow)
		local ok, result = xpcall(open_hf_prompt_impl, debug.traceback, flow)
		if ok == true then return result == true end
		Logger.error(LOG, "HuggingFace prompt construction raised: %s.",
			tostring(result))
		flow.webview_installing = false
		if flow.webview ~= nil and type(flow.close_webview) == "function" then
			local close_ok, closed = xpcall(function()
				return flow.close_webview(nil, true)
			end, debug.traceback)
			if close_ok ~= true or closed ~= true then
				Logger.error(LOG,
					"HuggingFace prompt rollback remains unsettled: %s.",
					tostring(closed))
			end
		end
		request_terminal(flow, false,
			"HuggingFace prompt construction exception")
		return false
	end

	--- Schedules the prompt below exact requirement provenance. The descriptor is
	--- visible before TimerScheduler.after(), buffers reentrant delivery, and only
	--- crosses into UI after the scheduler's native timer has settled.
	function obj.prompt_hf_login(on_done, provenance)
		local flow = begin_flow(on_done, provenance)
		if flow == nil then return false end
		local owner = {
			handle = nil,
			authorized = true,
			committed = false,
			installing = true,
			native_settled = false,
			callback_pending = false,
			callback_consumed = false,
		}
		flow.prompt_callback_expected = true
		flow.timer_owner = owner

		local function deliver_prompt()
			if owner.callback_consumed == true
				or owner.callback_pending ~= true
				or owner.committed ~= true
				or owner.native_settled ~= true then
				return
			end
			owner.callback_consumed = true
			owner.callback_pending = false
			if flow.timer_owner == owner then flow.timer_owner = nil end
			if owner.authorized ~= true or flow.prompt_callback_expected ~= true
				or not flow_is_authorized(flow) then
				flow.prompt_callback_expected = false
				try_release_flow(flow)
				return
			end
			-- Keep one published child across the timer-to-webview handoff.
			flow.webview_installing = true
			flow.prompt_callback_expected = false
			open_hf_prompt(flow)
		end

		local schedule_ok, handle_or_error, committed = xpcall(function()
			local handle, started = TimerScheduler.after(0.05, function()
				if owner.callback_consumed == true then return end
				owner.callback_pending = true
				deliver_prompt()
			end)
			return handle, started
		end, debug.traceback)
		local handle = schedule_ok == true and handle_or_error or nil
		owner.handle = type(handle) == "table" and handle or nil
		owner.installing = false

		local observer_registered = false
		if owner.handle ~= nil then
			local observer_ok, registered = xpcall(function()
				return TimerScheduler.onSettled(owner.handle, function()
					owner.native_settled = true
					if flow.timer_owner == owner then flow.timer_owner = nil end
					deliver_prompt()
					try_release_flow(flow)
				end)
			end, debug.traceback)
			observer_registered = observer_ok == true and registered == true
		end

		if schedule_ok ~= true or committed ~= true
			or owner.handle == nil or observer_registered ~= true then
			owner.authorized = false
			owner.committed = false
			flow.prompt_callback_expected = false
			if owner.handle ~= nil then
				local cancel_ok, settled = xpcall(function()
					return TimerScheduler.cancel(owner.handle)
				end, debug.traceback)
				if cancel_ok == true and settled == true then
					owner.native_settled = true
					if flow.timer_owner == owner then flow.timer_owner = nil end
				end
			else
				owner.native_settled = true
				if flow.timer_owner == owner then flow.timer_owner = nil end
			end
			Logger.error(LOG, "HuggingFace prompt timer start refused: %s.",
				tostring(schedule_ok and committed or handle_or_error))
			request_terminal(flow, false,
				"HuggingFace prompt timer start refusal")
			return false
		end

		owner.committed = true
		deliver_prompt()
		return true
	end

	function obj._process_hf_token(token, on_done, owned_flow)
		local flow = owned_flow
		if flow == nil then flow = begin_flow(on_done, nil) end
		if flow == nil or active_flow ~= flow or not flow_is_authorized(flow) then
			return false
		end
		if type(token) ~= "string" or token == "" then
			request_terminal(flow, false,
				"HuggingFace token-processing input refusal")
			return false
		end
		if flow.task ~= nil or flow.task_starting == true
			or (deps.active_tasks and deps.active_tasks["hf_login"] ~= nil) then
			request_terminal(flow, false,
				"HuggingFace token-processing sibling refusal")
			return false
		end
		local escaped_token = token:gsub('\\', '\\\\'):gsub('"', '\\"')

		local login_script = [[
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
python3 -u - <<'PY'
import sys
import os
import warnings
import pathlib

warnings.filterwarnings('ignore')
os.environ['PYTHONWARNINGS'] = 'ignore'

token = "]] .. escaped_token .. [["

if not token or len(token.strip()) == 0:
    print("Erreur: Token vide", file=sys.stderr)
    sys.exit(1)

try:
    import urllib.request
    import ssl

    ctx = ssl.create_default_context()
    req = urllib.request.Request(
        'https://huggingface.co/api/whoami-v2',
        headers={
            'User-Agent': 'huggingface/hub',
            'Authorization': f'Bearer {token.strip()}'
        }
    )
    try:
        resp = urllib.request.urlopen(req, timeout=10, context=ctx)
        status = resp.status
    except urllib.error.HTTPError as http_err:
        status = http_err.code

    if status != 200:
        print(f"Token validation failed: HTTP {status}", file=sys.stderr)
        sys.exit(1)

    home = os.path.expanduser("~")
    hf_dir = pathlib.Path(home) / ".huggingface"
    hf_dir.mkdir(parents=True, exist_ok=True)

    token_file = hf_dir / "token"
    token_file.write_text(token.strip(), encoding='utf-8')

    os.chmod(str(token_file), 0o600)

    print(f"Token saved to {token_file}", file=sys.stderr)

    try:
        import subprocess
        process = subprocess.Popen(
            ['git', 'credential-osxkeychain', 'store'],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )

        credential_input = f"protocol=https\nhost=huggingface.co\nusername=oauth2config\npassword={token.strip()}\n"
        process.communicate(input=credential_input, timeout=5)
    except Exception as e:
        print(f"Note: Git credential save skipped: {e}", file=sys.stderr)

    print("Connexion HuggingFace réussie")
    sys.exit(0)

except Exception as e:
    print(f"Erreur HuggingFace: {str(e)}", file=sys.stderr)
    sys.exit(1)
PY
		]]

		local task
		local pending_completion = nil

		local function finish_task(code, launched)
			if flow.task_terminal_consumed == true then return false end
			flow.task_terminal_consumed = true
			if deps.active_tasks and deps.active_tasks["hf_login"] == task then
				deps.active_tasks["hf_login"] = nil
			end
			if flow.task == task then flow.task = nil end
			flow.task_starting = false
			flow.task_committed = false
			flow.task_termination_accepted = false
			local succeeded = launched == true and code == 0
			run_flow_callback(flow, "HuggingFace login terminal", function()
				if flow_is_authorized(flow) then
					if succeeded then
						pcall(notifications.notify, i18n.get("mlx.hf_connected"),
							i18n.get("mlx.hf_connected_body"), "success")
					else
						pcall(notifications.notify, i18n.get("mlx.hf_login_title"),
							i18n.get("mlx.hf_connection_failed_body"), "error")
					end
				end
				request_terminal(flow, succeeded,
					succeeded and "HuggingFace login success"
						or "HuggingFace login failure")
			end)
			return true
		end

		local function on_task_done(code)
			if flow.task_terminal_consumed == true then return end
			if flow.task_starting == true then
				if pending_completion == nil then
					pending_completion = { code = code }
				end
				return
			end
			finish_task(code, flow.task_committed == true)
		end

		--- Signals the exact task and accepts observable stopped state as stronger
		--- evidence than a false/nil/throwing native return. A still-running task is
		--- retained for its real terminal callback and blocks every successor.
		--- @param label string Stable diagnostic label.
		--- @return boolean settled_or_accepted
		local function terminate_or_prove_stopped(label)
			local accepted = TaskLifecycle.terminate(task, label)
			if flow.task ~= task then return true end
			flow.task_termination_accepted = accepted == true
			if task_proven_not_running(task) then
				return finish_task(nil, false) == true
			end
			return accepted == true
		end

		flow.task_starting = true
		task = TaskLifecycle.native("HuggingFace login", "/bin/bash", on_task_done,
			function(_, stdout, stderr)
				local out = (stdout or "") .. (stderr or "")
				if out ~= "" and flow_is_authorized(flow) then
					print("[HF Login] " .. out)
				end
				return true
			end, { "-c", login_script })

		if task == nil or task == false then
			flow.task_starting = false
			if pending_completion ~= nil then
				finish_task(pending_completion.code, false)
			else
				request_terminal(flow, false,
					"HuggingFace login construction failure")
			end
			return false
		end

		flow.task = task
		if deps.active_tasks then deps.active_tasks["hf_login"] = task end
		if not flow_is_authorized(flow) then
			flow.task_starting = false
			if task_proven_not_running(task) then
				finish_task(nil, false)
			else
				terminate_or_prove_stopped(
					"HuggingFace login pre-start pause")
			end
			return false
		end

		local started = TaskLifecycle.start(task, "HuggingFace login")
		flow.task_starting = false
		if started == true then
			flow.task_committed = true
			if pending_completion ~= nil then
				finish_task(pending_completion.code, true)
			elseif task_proven_not_running(task) then
				-- A truthy start without either a live task or an exact terminal is
				-- not a committed native capability. Settle it as a failed launch.
				finish_task(nil, false)
				return false
			elseif not flow_is_authorized(flow) then
				-- A signal accepted while start() was still on-stack predates the
				-- capability that start() has just committed. Signal the same exact
				-- task again; otherwise pre-activation PAUSE can orphan a process that
				-- becomes live immediately after the nested pause returns.
				flow.task_committed = false
				flow.task_termination_accepted = false
				terminate_or_prove_stopped(
					"HuggingFace login reentrant pause")
				return false
			end
			return true
		end

		flow.task_committed = false
		if pending_completion ~= nil then
			finish_task(pending_completion.code, false)
		elseif task_proven_not_running(task) then
			finish_task(nil, false)
		else
			terminate_or_prove_stopped("HuggingFace login start refusal")
		end
		return false
	end
end

return M
