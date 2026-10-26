--- _shared/lua/healthcheck/report.lua

--- ==============================================================================
--- MODULE: Diagnostics Action Runner (Shared)
--- DESCRIPTION:
--- The engine behind the diagnostics page's buttons and the Debug menu's
--- "Report a bug" and "Suggest a feature" rows on macOS and Linux
--- (ui/healthcheck/report.lua): one action runs under an exact owner, through
--- an explicit completion, with every side effect (clipboard, file save,
--- folder creation, opener, notification) injected.
---
--- FEATURES & RATIONALE:
--- 1. Async opener admission is never a result: an action finishes once, from
---    the child's receipt, and a superseded or cancelled request neither
---    completes nor starts a successor child.
--- 2. The driver supplies what differs by platform: its effects table, the
---    extra actions that open a URL,
---    how a failed reveal is judged, and whether the action is bound to the
---    loaded driver module.
--- 3. A Debug menu row holds one request: a second click supersedes the first.
--- ==============================================================================

local IssueLink = require("diagnostics.issue_link")
local Share = require("healthcheck.share")

local M = {}

-- The path fields that name a folder: created when missing, then opened.
M.FOLDER_IDS = { config_dir = true, logs_dir = true, crash_dir = true, diagnostics_dir = true, app_dir = true }

-- The actions that open a URL the caller built, by effect kind.
local URL_EFFECTS = { suggest_feature = "open_url" }




-- =============================================
-- =============================================
-- ======= 1/ Public API =======================
-- =============================================
-- =============================================

--- Builds one driver's runner.
--- @param ports table {
---   logger = central logger, log = log namespace,
---   effects_with = function(overrides) -> effects table,
---   url_effects = map of extra action name -> effect kind opening action.url,
---   reveal_outcome = function(receipt, path, finish) -> boolean: logs a failed
---     reveal and returns true when it already finished the action,
---   module_current = function() -> boolean: the driver module is still the loaded one,
---   perform_requires_loaded_owner = boolean: whether perform() also checks it }
--- @return table runner { perform, menu_request }
function M.new(ports)
	assert(type(ports) == "table" and type(ports.logger) == "table" and type(ports.log) == "string",
		"a diagnostics runner needs a logger and a log namespace")
	for _, name in ipairs({ "effects_with", "reveal_outcome", "module_current" }) do
		assert(type(ports[name]) == "function", "a diagnostics runner needs the port " .. name)
	end
	assert(type(ports.url_effects) == "table" and type(ports.perform_requires_loaded_owner) == "boolean",
		"a diagnostics runner needs url_effects and perform_requires_loaded_owner")
	local Logger, LOG = ports.logger, ports.log
	local runner = {}

	--- Performs one action through an explicit completion and retained owner.
	--- Async opener admission is never a result. Inline completion is valid for
	--- synchronous actions and native ports that have already received their exit.
	--- @param owner table { current = function(): boolean, complete = function(result) }
	--- @return table operation { cancel = function() }
	local function perform(action, paths, documents, context, overrides, snapshot, owner)
		assert(type(owner) == "table" and type(owner.current) == "function" and type(owner.complete) == "function",
			"Diagnostics action needs its current owner and completion")
		local effects, request = ports.effects_with(overrides), {}
		local active, child, pending = true, nil, nil
		function request.cancel()
			active, pending = false, nil
			local retained = child
			child = nil
			if retained then retained.cancel() end
		end
		local function current()
			if not active or (ports.perform_requires_loaded_owner and not ports.module_current()) then return false end
			if owner.current() == true then return true end
			request.cancel()
			return false
		end
		local function finish(result, detail)
			if not current() then return end
			active, pending = false, nil
			if result.missing then
				Logger.info(LOG, "Diagnostics action '%s': the file does not exist yet.", action.action)
			elseif result.ok then
				Logger.success(LOG, "Diagnostics action '%s' done.", action.action)
			else
				Logger.error(LOG, "Diagnostics action '%s' failed: %s", action.action, tostring(detail))
			end
			if owner.current() == true then owner.complete(result) end
		end
		local function invoke(fn, ...)
			if not current() then return end
			local ok, detail = xpcall(fn, debug.traceback, ...)
			if not ok then finish({ ok = false }, detail) end
		end
		local function launch(kind, target, next_step)
			if not current() then return end
			local ticket = {}
			pending = ticket
			local function completed(receipt)
				if not current() or pending ~= ticket then return end
				pending, child = nil, nil
				invoke(next_step, type(receipt) == "table" and receipt or { ok = false, error = "invalid launcher receipt" })
			end
			local called, handle, detail = pcall(effects[kind], target, completed, current)
			if pending == ticket and current() then
				if called and type(handle) == "table" and type(handle.cancel) == "function" then child = handle
				else completed({ ok = false, error = tostring(called and detail or handle) }) end
			elseif not called then
				Logger.error(LOG, "The completed launcher port failed: %s", tostring(handle))
			elseif type(handle) == "table" and type(handle.cancel) == "function" then
				-- An inline callback may already have dispatched a successor child.
				handle.cancel()
			end
		end
		local function opened(receipt, path)
			finish({ ok = receipt.ok == true, path = path, exit_code = receipt.code }, receipt.error)
		end
		local function save_then(next_step)
			if type(paths.diagnostics_dir) ~= "string" then error("the diagnostics folder is unknown") end
			-- The opt-in day log first, so the report is the file revealed last
			if action.day_log_file then
				local log_path, log_detail = effects.save(paths.diagnostics_dir, action.day_log_file.name, action.day_log_file.text)
				if not current() then return end
				if not log_path then error("the day log could not be saved: " .. tostring(log_detail)) end
			end
			local path, detail = effects.save(paths.diagnostics_dir, action.name, action.text)
			if not current() then return end
			if not path then error("the report could not be saved: " .. tostring(detail)) end
			launch("reveal", path, function(receipt)
				if ports.reveal_outcome(receipt, path, finish) then return end
				if current() then next_step(path) end
			end)
		end
		invoke(function()
			Logger.start(LOG, "Diagnostics action '%s'…", action.action)
			if not current() then return end
			if action.action == "copy" or action.action == "save" or action.action == "report" then
				-- The opt-in day log is written by save and report only, and only from
				-- the collection prepared for this very snapshot
				local with_log = action.day_log == true
				if with_log and action.action == "copy" then error("the day log is saved with the report, never copied") end
				local document = Share.document(snapshot, documents.schema,
					require("infra.i18n").get(documents.schema.share_policy.notice_key), with_log)
				assert(action.text == document.text, "Diagnostic sharing preview is stale or invalid")
				action = { action = action.action, text = document.text, fields = document.fields, name = document.name,
					day_log_file = with_log and require("healthcheck.day_log").file(snapshot, documents, document.snapshot) or nil }
			end
			if not current() then return end
			if action.action == "copy" or action.action == "report" then
				local copied = effects.copy(action.text)
				if not current() then return end
				if copied ~= true then error("the clipboard refused the report") end
			end
			if action.action == "copy" then finish({ ok = true })
			elseif action.action == "save" then save_then(function(path) finish({ ok = true, path = path }) end)
			elseif action.action == "report" then
				save_then(function(path)
					local fields = {}
					for _, id in ipairs({ "version", "os", "driver" }) do fields[id] = action.fields[id] end
					assert(type(documents.templates.templates.bug.report_field) == "string", "the bug template names no report field")
					local url = IssueLink.build_url(documents.templates, documents.repository, "bug", fields)
					launch("open_url", url, function(receipt) opened(receipt, path) end)
				end)
			elseif action.action == "open_path" then
				local path = paths[action.id]
				if type(path) ~= "string" or path == "" then error("the path " .. action.id .. " is unknown") end
				if M.FOLDER_IDS[action.id] then
					local created = effects.make_dir(path)
					if not current() then return end
					if created ~= true then error("cannot create " .. path) end
				end
				local exists = effects.exists(path)
				if not current() then return end
				if not exists then
					if M.FOLDER_IDS[action.id] then error(path .. " does not exist") end
					finish({ ok = false, missing = true }); return
				end
				launch("open", path, function(receipt) opened(receipt) end)
			elseif URL_EFFECTS[action.action] or ports.url_effects[action.action] then
				local kind = URL_EFFECTS[action.action] or ports.url_effects[action.action]
				launch(kind, action.url, function(receipt) opened(receipt) end)
			else error("no handler for the action " .. tostring(action.action)) end
		end)
		return request
	end
	runner.perform = perform

	-- One request per Debug menu row: a second click supersedes the first
	local menu_slots = { report_bug = {}, suggest_feature = {} }

	--- Runs one Debug menu GitHub request under an exact owner: a failure is
	--- logged and notified, and the completion receives the child outcome.
	--- @param id string The menu row, a key of menu_slots.
	--- @param overrides table|nil Replacement side effects (tests only).
	--- @param complete function|nil Receives true once the form opened.
	--- @param start function Receives the owner and returns the perform request.
	--- @return table|nil cancellable request
	local function menu_request(id, overrides, complete, start)
		local slot = menu_slots[id]
		local previous = slot.request
		local token = {}
		slot.owner, slot.request = token, nil
		local function current() return slot.owner == token and ports.module_current() end
		if previous then previous.cancel() end
		if not current() then return nil end
		local effects = ports.effects_with(overrides)
		local function finished(result)
			if not current() then return end
			slot.request = nil
			if result.ok ~= true then
				local i18n = require("infra.i18n")
				effects.notify(i18n.get("menu.debug." .. id), i18n.get("notify.github_report_failed"), "error")
			end
			if current() and type(complete) == "function" then complete(result.ok == true) end
		end
		local completed = false
		local ok, request = xpcall(start, debug.traceback, {
			current = current, complete = function(result) completed = true; finished(result) end,
		})
		if not ok then Logger.error(LOG, "Debug menu request '%s' failed: %s", id, tostring(request)); finished({ ok = false }); return nil end
		if current() and not completed then slot.request = request else request.cancel() end
		return request
	end

	runner.menu_request = menu_request

	return runner
end

return M
