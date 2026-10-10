--- ui/healthcheck/report.lua

--- ==============================================================================
--- MODULE: Diagnostics Exports And GitHub Forms (Linux)
--- DESCRIPTION:
--- What the diagnostics page's buttons do on this machine once
--- healthcheck.actions accepted them: copy the report, save it as a Markdown
--- file under the logs folder and open that folder, report it on GitHub (copy
--- it, then save and reveal its attachment before opening the bug template) or
--- a file. Also the Debug menu's "Report a bug", which opens the diagnostics
--- window at its preview, and "Suggest a feature".
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

--- Opens a target with the desktop's handler, in the background.
--- @param target string A path or a URL.
--- @return boolean started
local function xdg_open(target)
	local Shell = require("adapters.shell_runner")
	return Shell.run("xdg-open " .. Shell.quote(target) .. " >/dev/null 2>&1 &")
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
	reveal = function(path) return xdg_open(path:match("^(.*)/[^/]*$") or path) end,
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
--- @return table { home, user, case_insensitive }
function M.redaction_context(overrides)
	local identity = effects_with(overrides).identity()
	-- Without the home folder nothing would remove it, and every path under it
	-- would be published
	if type(identity.home) ~= "string" or identity.home == "" then
		error("the home folder is unknown, so nothing could be redacted")
	end
	return { home = identity.home, user = identity.user, case_insensitive = false }
end





-- ===============================
-- ===============================
-- ======= 2/ Page Actions =======
-- ===============================
-- ===============================

--- Saves the report under the diagnostics folder and opens that folder.
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
	if not effects.reveal(path) then Logger.warn(LOG, "The saved report's folder could not be opened.") end
	return path
end

--- Reports on GitHub: copies and saves the complete approved report, then
--- reveals its local attachment before opening the bug form with stable host
--- version, OS and driver fields. Editable fields stay outside the URL; the
--- browser opens last and no attachment is uploaded automatically.
--- @param effects table
--- @param documents table { templates, repository, redaction }
--- @param action table Host-approved text and technical identity fields.
--- @param redact function
--- @param paths table Host-retained attachment directory.
--- @return table
local function report(effects, documents, action, redact, paths)
	local text = redact(action.text)
	-- Copy the complete reviewed report independently of its short metadata URL
	if not effects.copy(text) then error("the clipboard refused the report") end
	-- Complete the local attachment before opening the metadata-only issue form.
	local path, err = save_and_reveal(effects, paths, action.name, text)
	if not path then error(err) end
	local fields = {}
	-- Only the host-derived technical identity is stable enough to prefill.
	for _, id in ipairs({ "version", "os", "driver" }) do fields[id] = action.fields[id] end
	local report_field = documents.templates.templates.bug.report_field
	if type(report_field) ~= "string" then error("the bug template names no report field") end
	local url = IssueLink.build_url(documents.templates, documents.repository, "bug", fields)
	if not effects.open_url(url) then error("the browser could not be opened") end
	return { path = path }
end

--- Performs one action of the diagnostics page, already validated.
--- @param action table From healthcheck.actions.validate (copy, save, report, open_path).
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
			if not effects.open(path) then error("the file manager could not open " .. path) end
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
--- @return boolean opened
function M.report_bug()
	return require("ui.healthcheck.bridge").open("report")
end

--- Opens the GitHub feature form with the version and the system prefilled.
--- @param overrides table|nil Replacement side effects (tests only).
--- @return boolean opened
function M.suggest_feature(overrides)
	Logger.start(LOG, "Opening the feature request form…")
	local effects = effects_with(overrides)
	local ok, err = xpcall(function()
		local Bridge = require("ui.healthcheck.bridge")
		local documents = Bridge.config()
		local context = M.redaction_context(overrides)
		local document = Share.document(Bridge.build_snapshot(require("ui.webview_manager").get_daemon_state(), false), documents.schema,
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
