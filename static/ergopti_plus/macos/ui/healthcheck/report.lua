--- ui/healthcheck/report.lua

--- ==============================================================================
--- MODULE: Diagnostics Exports And GitHub Forms (macOS)
--- DESCRIPTION:
--- What the diagnostics page's buttons do on this machine once
--- healthcheck.actions accepted them: copy the report, save it as a Markdown
--- file under the logs folder and reveal it, report it on GitHub (copy it,
--- then open the bug form with the report prefilled), open a folder or a
--- settings page. Also the Debug menu's "Report a bug", which opens the
--- diagnostics window at its preview, and "Suggest a feature".
---
--- FEATURES & RATIONALE:
--- 1. Shared output is rebuilt from the host snapshot through a closed typed
---    policy. Free text, paths and unknown fields are excluded regardless of
---    the page or details checkbox. Only approved technical content leaves.
--- 2. GitHub answers 414 a little above 8 KB, so the issue link cuts a long
---    report to its budget; the clipboard holds it whole. A report saves no
---    file and reveals nothing: Finder would take the focus from the form.
--- 3. Paths come from the snapshot the host collected, by field id; a folder
---    that does not exist yet is created before it is opened; a file that does
---    not exist yet (today's errors file before the day's first warning) is
---    said to the page, not logged as a failure.
--- 4. Side effects are one table so a test can observe each of them; the
---    browser opens last, after the clipboard holds what it asks for, and
---    nothing follows it that could take the focus back.
--- ==============================================================================

local M = {}

local hs          = hs
local Logger      = require("infra.logger")
local IssueLink   = require("diagnostics.issue_link")
local Redact      = require("diagnostics.redact")
local Share       = require("healthcheck.share")

local LOG = "healthcheck.report"

-- The executable that reveals a file in Finder and opens folders and URLs
local OPEN_BIN = "/usr/bin/open"

-- The path fields that name a folder: created when missing, then opened
local FOLDER_IDS = { config_dir = true, logs_dir = true, crash_dir = true, diagnostics_dir = true, app_dir = true }





-- ===============================
-- ===============================
-- ======= 1/ Side Effects =======
-- ===============================
-- ===============================

--- Creates a folder and its parents in-process.
--- @param dir string Absolute folder path.
--- @return boolean created True when the folder exists afterwards.
local function make_dir(dir)
	local built = dir:sub(1, 1) == "/" and "/" or ""
	for part in dir:gmatch("[^/]+") do
		built = built .. part .. "/"
		if hs.fs.attributes(built, "mode") == nil then hs.fs.mkdir(built) end
	end
	return hs.fs.attributes(dir, "mode") == "directory"
end

--- Runs /usr/bin/open with arguments, without a shell.
--- @param args table
--- @return boolean started
local function open_with(args)
	local handle = require("adapters.shell_runner").spawn(OPEN_BIN, args, nil)
	return handle.start() == true
end

--- The production side effects; a test replaces any of them.
local DEFAULT_EFFECTS = {
	copy = function(text) return require("adapters.clipboard").write(text) == true end,
	save = function(dir, name, text)
		if not make_dir(dir) then return nil, "cannot create " .. dir end
		local path = dir .. "/" .. name
		local fh, err = io.open(path, "wb")
		if not fh then return nil, tostring(err) end
		local ok, write_err = fh:write(text)
		fh:close()
		if not ok then return nil, tostring(write_err) end
		return path
	end,
	make_dir = make_dir,
	exists = function(path) return hs.fs.attributes(path, "mode") ~= nil end,
	reveal = function(path) return open_with({ "-R", path }) end,
	open = function(target) return open_with({ target }) end,
	open_url = function(url) return require("ui.ui_builder").open_http_url(url) end,
	notify = function(title, body, kind)
		return require("adapters.application_notifier").send(title, { body = body, kind = kind })
	end,
	identity = function() return { home = os.getenv("HOME"), user = os.getenv("USER") } end,
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

--- What identifies this machine in paths and text, for redaction.
--- @param overrides table|nil Replacement side effects (tests only).
--- @return table { home, user, case_insensitive }
function M.redaction_context(overrides)
	local identity = effects_with(overrides).identity()
	-- Without the home folder nothing would remove it, and every path under it
	-- would be published
	if type(identity.home) ~= "string" or identity.home == "" then
		error("the home folder is unknown, so nothing could be redacted")
	end
	-- APFS is case-insensitive by default, and so is every path a user types
	return { home = identity.home, user = identity.user, case_insensitive = true }
end





-- ===============================
-- ===============================
-- ======= 2/ Page Actions =======
-- ===============================
-- ===============================

--- Saves the report under the diagnostics folder and reveals it.
--- @param effects table
--- @param paths table The snapshot's paths section.
--- @param name string Validated file name.
--- @param text string Redacted report.
--- @return string|nil path
--- @return string|nil error
local function save_and_reveal(effects, paths, name, text)
	if type(paths.diagnostics_dir) ~= "string" then return nil, "the diagnostics folder is unknown" end
	local path, err = effects.save(paths.diagnostics_dir, name, text)
	if not path then return nil, "the report could not be saved: " .. tostring(err) end
	if not effects.reveal(path) then Logger.warn(LOG, "The saved report could not be revealed in Finder.") end
	return path
end

--- Reports on GitHub: copies the full report, then opens the bug form with
--- that same report prefilled. Nothing is saved and nothing is revealed: the
--- browser opening is the last side effect, so the form keeps the focus.
--- @param effects table
--- @param documents table { templates, repository, redaction }
--- @param action table { text, fields } The page's text and identity fields.
--- @param redact function
--- @return table
local function report(effects, documents, action, redact, paths)
	local text = redact(action.text)
	-- First, and whole: the link may cut the report to fit GitHub's budget
	if not effects.copy(text) then error("the clipboard refused the report") end
	-- Save the complete reviewed document before opening its short issue form.
	local path, err = save_and_reveal(effects, paths, action.name, text)
	if not path then error(err) end
	local fields = {}
	for id, value in pairs(action.fields) do fields[id] = redact(value) end
	local report_field = documents.templates.templates.bug.report_field
	if type(report_field) ~= "string" then error("the bug template names no report field") end
	fields[report_field] = action.summary
	local url = IssueLink.build_url(documents.templates, documents.repository, "bug", fields)
	if not effects.open_url(url) then error("the browser could not be opened") end
	return { path = path }
end

--- Performs one action of the diagnostics page, already validated.
--- @param action table From healthcheck.actions.validate (copy, save, report,
---   open_path, open_settings).
--- @param paths table The snapshot's paths section.
--- @param documents table { templates, repository, redaction }
--- @param context table The redaction context.
--- @param overrides table|nil Replacement side effects (tests only).
--- @return table { ok = boolean, path = string|nil, missing = true|nil }
function M.perform(action, paths, documents, context, overrides, snapshot)
	local effects = effects_with(overrides)
	local function redact(text) return text end
	Logger.start(LOG, "Diagnostics action '%s'…", action.action)
	local ok, result = xpcall(function()
		if action.action == "copy" or action.action == "save" or action.action == "report" then
			local document = Share.document(snapshot, documents.schema,
				require("infra.i18n").get(documents.schema.share_policy.notice_key))
			assert(action.text == document.text, "Diagnostic sharing preview is stale or invalid")
			action = { action = action.action, text = document.text, fields = document.fields, name = document.name, summary = document.summary }
		end
		if action.action == "copy" then
			if not effects.copy(redact(action.text)) then error("the clipboard refused the report") end
			return {}
		elseif action.action == "save" then
			local path, err = save_and_reveal(effects, paths, action.name, redact(action.text))
			if not path then error(err) end
			return { path = path }
		elseif action.action == "report" then
			return report(effects, documents, action, redact, paths)
		elseif action.action == "open_path" then
			local path = paths[action.id]
			if type(path) ~= "string" or path == "" then error("the path " .. action.id .. " is unknown") end
			if FOLDER_IDS[action.id] and not effects.make_dir(path) then error("cannot create " .. path) end
			if not effects.exists(path) then
				if FOLDER_IDS[action.id] then error(path .. " does not exist") end
				-- A file not created yet, such as today's errors file before the
				-- day's first warning: nothing to open, and no failure of ours
				return { missing = path }
			end
			if not effects.open(path) then error("Finder could not open " .. path) end
			return {}
		elseif action.action == "open_settings" then
			if not effects.open(action.url) then error("System Settings could not be opened") end
			return {}
		end
		error("no handler for the action " .. tostring(action.action))
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "Diagnostics action '%s' failed: %s", action.action, tostring(result))
		return { ok = false }
	end
	if result.missing then
		Logger.info(LOG, "Diagnostics action '%s': %s does not exist yet.", action.action, result.missing)
		return { ok = false, missing = true }
	end
	Logger.success(LOG, "Diagnostics action '%s' done.", action.action)
	result.ok = true
	return result
end





-- =============================
-- =============================
-- ======= 3/ Debug Menu =======
-- =============================
-- =============================

--- Opens the diagnostics window at its preview: the user reviews exactly what
--- is shared before the report button copies it and opens GitHub.
--- @param opts table|nil { state = menu state|nil }
--- @return boolean opened
function M.report_bug(opts)
	return require("ui.healthcheck.core").show_window({ mode = "report", state = type(opts) == "table" and opts.state or nil })
end

--- Opens the GitHub feature form with the version and the system prefilled.
--- @param overrides table|nil Replacement side effects (tests only).
--- @return boolean opened
function M.suggest_feature(overrides)
	Logger.start(LOG, "Opening the feature request form…")
	local effects = effects_with(overrides)
	local ok, err = xpcall(function()
		local Core = require("ui.healthcheck.core")
		local documents = Core.config()
		local context = M.redaction_context(overrides)
		local document = Share.document(Core.run(), documents.schema,
			require("infra.i18n").get(documents.schema.share_policy.notice_key))
		local url = IssueLink.build_url(documents.templates, documents.repository, "feature", document.fields)
		if not effects.open_url(url) then error("the browser could not be opened") end
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "Feature request failed: %s", tostring(err))
		local I18n = require("infra.i18n")
		effects.notify(I18n.get("menu.debug.suggest_feature"), I18n.get("notify.github_report_failed"), "error")
		return false
	end
	Logger.success(LOG, "Feature request form opened.")
	return true
end

return M
