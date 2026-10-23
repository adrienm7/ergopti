--- ui/healthcheck/report.lua

--- ==============================================================================
--- MODULE: Diagnostics Exports And GitHub Forms (Linux)
--- DESCRIPTION:
--- What the diagnostics page's buttons do on this machine once
--- healthcheck.actions accepted them: copy the report, save it as a Markdown
--- file under the logs folder and open that folder, report it on GitHub (copy
--- it, then save and reveal its attachment before opening the bug template) or
--- a file. Also the Debug menu's "Report a bug", which runs that same report
--- action on a fresh snapshot without the window, and "Suggest a feature".
---
--- FEATURES & RATIONALE:
--- 1. Shared output is rebuilt from the host snapshot through a closed typed
---    policy. Free text, paths and unknown fields are excluded regardless of
---    the page or details checkbox. Only approved technical content leaves.
--- 2. The clipboard and attachment hold the complete approved report.
---    GitHub receives stable host version, OS and driver metadata. Editable
---    fields stay out of the URL; the browser opens after attachment reveal.
--- 3. Paths come from the snapshot the host collected, by field id; a folder
---    that does not exist yet is created before it is opened; a file that does
---    not exist yet (today's errors file before the day's first warning) is
---    said to the page, not logged as a failure.
--- 4. Side effects are one table so a test can observe each of them; the
---    browser opens last, after the clipboard holds what it asks for, and
---    nothing follows it that could take the focus back.
--- ==============================================================================

local M = {}

local Logger      = require("logger.shim")
local IssueLink   = require("diagnostics.issue_link")
local Redact      = require("diagnostics.redact")
local Share       = require("healthcheck.share")

local LOG = "healthcheck.report"

-- The path fields that name a folder: created when missing, then opened
local FOLDER_IDS = { config_dir = true, logs_dir = true, crash_dir = true, diagnostics_dir = true, app_dir = true }





-- ===============================
-- ===============================
-- ======= 1/ Side Effects =======
-- ===============================
-- ===============================

--- Receives the launcher exit and both closed streams without blocking GTK.
--- @param target string A path or a URL.
--- @param done function Receives the real native exit receipt.
--- @param current function Exact page/action authority.
--- @return table|nil cancellable native request
local function xdg_open(target, done, current)
	return require("adapters.desktop_opener").open(target, done, current)
end

--- The production side effects; a test replaces any of them.
local DEFAULT_EFFECTS = {
	copy = function(text) return require("adapters.clipboard").write(text) == true end,
	make_dir = function(dir)
		local Shell = require("adapters.shell_runner")
		return Shell.run("mkdir -p " .. Shell.quote(dir))
	end,
	save = function(dir, name, text)
		local Shell = require("adapters.shell_runner")
		if not Shell.run("mkdir -p " .. Shell.quote(dir)) then return nil, "cannot create " .. dir end
		local path = dir .. "/" .. name
		-- The filesystem adapter owns buffered write and close receipts: only a
		-- completed file may be reported as saved and revealed to the user.
		if require("adapters.file_system").write(path, text) ~= true then
			return nil, "cannot complete writing " .. path
		end
		return path
	end,
	exists = function(path)
		local fh = io.open(path, "rb")
		if fh then fh:close() return true end
		-- A folder cannot be opened as a file on every system; ask the shell
		local Shell = require("adapters.shell_runner")
		return Shell.run("test -e " .. Shell.quote(path))
	end,
	-- No portable "select this file" exists across file managers; the folder
	-- holding it is the next best thing
	reveal = function(path, done, current) return xdg_open(path:match("^(.*)/[^/]*$") or path, done, current) end,
	open = xdg_open,
	open_url = xdg_open,
	notify = function(title, body, level)
		require("adapters.application_notifier").send(body ~= "" and body or title, { title = title, level = level })
		return true
	end,
	identity = function()
		return {
			home = require("infra.config_paths").home(),
			user = os.getenv("USER") or os.getenv("LOGNAME"),
			config_dir = require("infra.config_paths").get_config_dir(),
		}
	end,
}

--- Merges test overrides over the production effects.
--- @param overrides table|nil
--- @return table
local function effects_with(overrides)
	local effects = {}
	for name, fn in pairs(DEFAULT_EFFECTS) do effects[name] = fn end
	for name, fn in pairs(overrides or {}) do effects[name] = fn end
	return effects
end

--- What identifies this machine in paths and text, for redaction. Linux file
--- systems compare paths case-sensitively.
--- @param overrides table|nil Replacement side effects (tests only).
--- @return table { home, user, config_dir, case_insensitive }
function M.redaction_context(overrides)
	local identity = effects_with(overrides).identity()
	-- Without the home folder nothing would remove it, and every path under it
	-- would be published
	if type(identity.home) ~= "string" or identity.home == "" then
		error("the home folder is unknown, so nothing could be redacted")
	end
	return { home = identity.home, user = identity.user, config_dir = identity.config_dir, case_insensitive = false }
end





-- ===============================
-- ===============================
-- ======= 2/ Page Actions =======
-- ===============================
-- ===============================

--- Performs one action through an explicit completion and retained owner.
--- Async opener admission is never a result. Inline completion is valid for
--- synchronous actions and native ports that have already received their exit.
--- @param owner table { current = function(): boolean, complete = function(result) }
--- @return table operation { cancel = function() }
function M.perform(action, paths, documents, context, overrides, snapshot, owner)
	assert(type(owner) == "table" and type(owner.current) == "function" and type(owner.complete) == "function",
		"Diagnostics action needs its current owner and completion")
	local effects, request = effects_with(overrides), {}
	local active, child, pending = true, nil, nil
	function request.cancel()
		active, pending = false, nil
		local retained = child
		child = nil
		if retained then retained.cancel() end
	end
	local function current()
		if not active then return false end
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
		local path, detail = effects.save(paths.diagnostics_dir, action.name, action.text)
		if not current() then return end
		if not path then error("the report could not be saved: " .. tostring(detail)) end
		launch("reveal", path, function(receipt)
			if receipt.ok ~= true then
				Logger.warn(LOG, "The saved report's folder could not be opened (status=%s, reason=%s).",
					tostring(receipt.code), tostring(receipt.error))
			end
			if current() then next_step(path) end
		end)
	end
	invoke(function()
		Logger.start(LOG, "Diagnostics action '%s'…", action.action)
		if not current() then return end
		if action.action == "copy" or action.action == "save" or action.action == "report" then
			local document = Share.document(snapshot, documents.schema,
				require("infra.i18n").get(documents.schema.share_policy.notice_key))
			assert(action.text == document.text, "Diagnostic sharing preview is stale or invalid")
			action = { action = action.action, text = document.text, fields = document.fields, name = document.name }
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
			if FOLDER_IDS[action.id] then
				local created = effects.make_dir(path)
				if not current() then return end
				if created ~= true then error("cannot create " .. path) end
			end
			local exists = effects.exists(path)
			if not current() then return end
			if not exists then
				if FOLDER_IDS[action.id] then error(path .. " does not exist") end
				finish({ ok = false, missing = true }); return
			end
			launch("open", path, function(receipt) opened(receipt) end)
		elseif action.action == "suggest_feature" then
			launch("open_url", action.url, function(receipt) opened(receipt) end)
		else error("no handler for the action " .. tostring(action.action)) end
	end)
	return request
end





-- =============================
-- =============================
-- ======= 3/ Debug Menu =======
-- =============================
-- =============================

-- One request per Debug menu row: a second click supersedes the first
local _menu_slots = { report_bug = {}, suggest_feature = {} }

--- Runs one Debug menu GitHub request under an exact owner: a failure is
--- logged and notified, and the completion receives the child outcome.
--- @param id string The menu row, a key of _menu_slots.
--- @param overrides table|nil Replacement side effects (tests only).
--- @param complete function|nil Receives true once the form opened.
--- @param start function Receives the owner and returns the perform request.
--- @return table|nil cancellable request
local function menu_request(id, overrides, complete, start)
	local slot = _menu_slots[id]
	local previous = slot.request
	local token = {}
	slot.owner, slot.request = token, nil
	local function current() return slot.owner == token and package.loaded["ui.healthcheck.report"] == M end
	if previous then previous.cancel() end
	if not current() then return nil end
	local effects = effects_with(overrides)
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

--- The daemon's snapshot without the window, the probes not run.
--- @return table snapshot, table documents
local function menu_snapshot(complete_local)
	local bridge = require("ui.healthcheck.bridge")
	return bridge.build_snapshot(require("ui.webview_manager").get_daemon_state(), false, false, complete_local == true),
		bridge.config()
end

--- Reports a bug exactly as the diagnostics page's report button does, without
--- the window: the approved report of a fresh snapshot is copied, saved and its
--- folder opened, then the bug form opens with the host version, OS and driver.
--- @param overrides table|nil Replacement side effects (tests only).
--- @param complete function|nil Receives true once the form opened.
--- @return table|nil cancellable request
function M.report_bug(overrides, complete)
	return menu_request("report_bug", overrides, complete, function(owner)
		local snapshot, documents = menu_snapshot(true)
		assert(type(snapshot) == "table" and type(snapshot.sections) == "table"
			and type(snapshot.sections.paths) == "table", "the diagnostics snapshot has no paths section")
		local document = Share.document(snapshot, documents.schema,
			require("infra.i18n").get(documents.schema.share_policy.notice_key))
		return M.perform({ action = "report", text = document.text, fields = document.fields },
			snapshot.sections.paths, documents, M.redaction_context(overrides), overrides, snapshot, owner)
	end)
end

--- Opens the GitHub feature form with the version and the system prefilled.
--- @param overrides table|nil Replacement side effects (tests only).
--- @param complete function|nil Receives true once the form opened.
--- @return table|nil cancellable request; completion receives the child outcome.
function M.suggest_feature(overrides, complete)
	return menu_request("suggest_feature", overrides, complete, function(owner)
		local snapshot, documents = menu_snapshot()
		local document = Share.document(snapshot, documents.schema,
			require("infra.i18n").get(documents.schema.share_policy.notice_key))
		local url = IssueLink.build_url(documents.templates, documents.repository, "feature", document.fields)
		return M.perform({ action = "suggest_feature", url = url }, {}, documents, {}, overrides, nil, owner)
	end)
end

return M
