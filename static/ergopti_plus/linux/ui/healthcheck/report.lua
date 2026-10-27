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
local ReportRunner = require("healthcheck.report")
local ConfigKeys = require("config_keys")

local LOG = "healthcheck.report"





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

-- The diagnostics runner shared with the other desktop driver; this driver
-- supplies its effects and how a failed folder reveal is judged.
local Runner = ReportRunner.new({
	logger = Logger,
	log = LOG,
	effects_with = effects_with,
	url_effects = {},
	module_current = function() return package.loaded["ui.healthcheck.report"] == M end,
	perform_requires_loaded_owner = false,
	reveal_outcome = function(receipt)
		if receipt.ok ~= true then
			Logger.warn(LOG, "The saved report's folder could not be opened (status=%s, reason=%s).",
				tostring(receipt.code), tostring(receipt.error))
		end
		return false
	end,
})

--- Performs one action through an explicit completion and retained owner.
--- @param owner table { current = function(): boolean, complete = function(result) }
--- @return table operation { cancel = function() }
function M.perform(action, paths, documents, context, overrides, snapshot, owner)
	return Runner.perform(action, paths, documents, context, overrides, snapshot, owner)
end





-- =============================
-- =============================
-- ======= 3/ Debug Menu =======
-- =============================
-- =============================

local menu_request = Runner.menu_request

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
	return menu_request(ConfigKeys.COMMAND.REPORT_BUG, overrides, complete, function(owner)
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
	return menu_request(ConfigKeys.COMMAND.SUGGEST_FEATURE, overrides, complete, function(owner)
		local snapshot, documents = menu_snapshot()
		local document = Share.document(snapshot, documents.schema,
			require("infra.i18n").get(documents.schema.share_policy.notice_key))
		local url = IssueLink.build_url(documents.templates, documents.repository, "feature", document.fields)
		return M.perform({ action = ConfigKeys.COMMAND.SUGGEST_FEATURE, url = url }, {}, documents, {}, overrides, nil, owner)
	end)
end

return M
