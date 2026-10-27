--- ui/healthcheck/report.lua

--- ==============================================================================
--- MODULE: Diagnostics Exports And GitHub Forms (macOS)
--- DESCRIPTION:
--- What the diagnostics page's buttons do on this machine once
--- healthcheck.actions accepted them: copy the report, save it as a Markdown
--- file under the logs folder and reveal it, report it on GitHub (copy it,
--- then save an approved local attachment and open the short bug form), open a folder or a
--- settings page. Also the Debug menu's "Report a bug", which runs that same
--- report action on a fresh snapshot without the window, and "Suggest a feature".
---
--- FEATURES & RATIONALE:
--- 1. Shared output is rebuilt from the host snapshot through a closed typed
---    policy. Free text, paths and unknown fields are excluded regardless of
---    the page or details checkbox. Only approved technical content leaves.
--- 2. The clipboard and local attachment hold the complete approved report.
---    Only stable host version, OS and driver metadata are prefilled. The browser opens
---    after attachment completion and reveal, without an automatic upload.
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
local ReportRunner = require("healthcheck.report")
local ConfigKeys = require("config_keys")

local LOG = "healthcheck.report"

-- The executable that reveals a file in Finder and opens folders and URLs
local OPEN_BIN = "/usr/bin/open"





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

-- Retain exact native cleanup debt after logical cancellation. A subsequent
-- opener retries those handles; native settlement alone releases the registry.
local retained_openers = {}

--- Runs /usr/bin/open to its terminal receipt without blocking the native UI.
--- @param args table Literal arguments, without shell interpolation.
--- @param done function Receives the exact launcher outcome.
--- @param current function Exact action owner predicate.
--- @return table request Cancellable native opener.
local function open_with(args, done, current)
	local timeout = require("infra.timings").sec("ui", "desktop_open_timeout_ms")
	local cleanup = {}
	for request, retired in pairs(retained_openers) do
		if retired() then cleanup[#cleanup + 1] = request end
	end
	for _, request in ipairs(cleanup) do request.cancel() end
	local Scheduler = require("adapters.timer_scheduler")
	local request, task, timer = {}, nil, nil
	local active, terminal, retiring, forced_error = true, false, false, nil
	local function stop_timer()
		local owned = timer
		if owned then
			local ok, stopped = pcall(Scheduler.cancel, owned)
			if ok and stopped == true then timer = nil
			else Logger.error(LOG, "Desktop opener timer cleanup refused; exact handle retained.") end
		end
	end
	local function release()
		local settled = task == nil
		if task then
			local ok, result = pcall(task.isSettled)
			settled = ok and result == true
		end
		if settled then
			stop_timer()
			if timer == nil then retained_openers[request] = nil end
		end
	end
	local function terminate()
		if task then
			local ok, stopped = pcall(task.terminate)
			if not ok or stopped ~= true then
				Logger.error(LOG, "Desktop opener cleanup refused; exact task retained.")
			end
		end
	end
	function request.cancel()
		active, retiring = false, true
		stop_timer()
		terminate()
		release()
	end
	local function complete(code, detail)
		if terminal then return end
		terminal, retiring = true, true
		stop_timer()
		local admitted = active
		active = false
		release()
		if admitted then
			local settled = task == nil or task.isSettled() == true
			done({ ok = forced_error == nil and code == 0, code = code,
				error = forced_error or detail, cleanup_pending = not settled or nil })
		end
	end
	local function refuse(detail)
		forced_error, retiring = detail, true
		terminate()
		complete(nil, detail)
	end
	retained_openers[request] = function() return retiring end
	if current() ~= true then request.cancel(); return request end
	local built, candidate = pcall(require("adapters.shell_runner").spawn, OPEN_BIN, args, function(code)
		complete(code, code ~= 0 and "desktop opener refused" or nil)
	end)
	if not built or type(candidate) ~= "table" or type(candidate.start) ~= "function"
		or type(candidate.terminate) ~= "function" or type(candidate.isSettled) ~= "function"
		or type(candidate.onSettled) ~= "function" then
		refuse("desktop opener construction refused")
		return request
	end
	task = candidate
	local observed, accepted = pcall(task.onSettled, release)
	if not observed or accepted ~= true then refuse("desktop opener settlement observer refused"); return request end
	local probed, settled = pcall(task.isSettled)
	if not probed or settled == true then refuse("desktop opener construction refused"); return request end
	if current() ~= true then request.cancel(); return request end
	local scheduled, handle, committed = pcall(Scheduler.after, timeout, function()
			if not active or terminal then release(); return end
			refuse("desktop opener deadline")
		end)
	timer = scheduled and handle or nil
	if terminal or not active then stop_timer(); release(); return request end
	if current() ~= true then request.cancel(); return request end
	if not scheduled or committed ~= true then refuse("desktop opener deadline refused"); return request end
	local started, admitted = pcall(task.start)
	if not started and terminal then
		Logger.error(LOG, "The completed desktop opener start failed: %s", tostring(admitted))
	elseif not terminal and (not started or admitted ~= true) then
		refuse("desktop opener launch refused")
	end
	return request
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
		local closed, close_err = fh:close()
		if not ok then return nil, tostring(write_err) end
		if not closed then return nil, tostring(close_err) end
		return path
	end,
	make_dir = make_dir,
	exists = function(path) return hs.fs.attributes(path, "mode") ~= nil end,
	reveal = function(path, done, current) return open_with({ "-R", path }, done, current) end,
	open = function(target, done, current) return open_with({ target }, done, current) end,
	open_url = function(url, done)
		done({ ok = require("ui.ui_builder").open_http_url(url) == true })
		return { cancel = function() end }
	end,
	notify = function(title, body, kind)
		return require("adapters.application_notifier").send(title, { body = body, kind = kind })
	end,
	identity = function()
		local ConfigPaths = require("infra.config_paths")
		return {
			home = os.getenv("HOME"), user = os.getenv("USER"),
			config_dir = ConfigPaths.is_initialized() and ConfigPaths.get_config_dir() or nil,
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

--- What identifies this machine in paths and text, for redaction.
--- @param overrides table|nil Replacement side effects (tests only).
--- @return table { home, user, config_dir, case_insensitive }
function M.redaction_context(overrides)
	local identity = effects_with(overrides).identity()
	-- Without the home folder nothing would remove it, and every path under it
	-- would be published
	if type(identity.home) ~= "string" or identity.home == "" then
		error("the home folder is unknown, so nothing could be redacted")
	end
	-- APFS is case-insensitive by default, and so is every path a user types
	return { home = identity.home, user = identity.user, config_dir = identity.config_dir, case_insensitive = true }
end





-- ===============================
-- ===============================
-- ======= 2/ Page Actions =======
-- ===============================
-- ===============================

-- The diagnostics runner shared with the other desktop driver; this driver
-- supplies its effects and how a failed Finder reveal is judged.
local Runner = ReportRunner.new({
	logger = Logger,
	log = LOG,
	effects_with = effects_with,
	url_effects = { open_settings = "open" },
	module_current = function() return package.loaded["ui.healthcheck.report"] == M end,
	perform_requires_loaded_owner = true,
	reveal_outcome = function(receipt, path, finish)
		if receipt.cleanup_pending then
			finish({ ok = false, path = path }, "desktop reveal retirement remains pending")
			return true
		end
		if receipt.ok ~= true then
			Logger.warn(LOG, "The saved report could not be revealed in Finder (status=%s, reason=%s).",
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

--- Reports a bug exactly as the diagnostics page's report button does, without
--- the window: the approved report of a fresh snapshot is copied, saved and
--- revealed, then the bug form opens with the host version, OS and driver.
--- @param opts table|nil { state = menu state|nil }, for the features section.
--- @param overrides table|nil Replacement side effects (tests only).
--- @param complete function|nil Receives true once the form opened.
--- @return table|nil cancellable request
function M.report_bug(opts, overrides, complete)
	local state = type(opts) == "table" and opts.state or nil
	return menu_request(ConfigKeys.COMMAND.REPORT_BUG, overrides, complete, function(owner)
		local bridge = require("ui.healthcheck.core")
		local documents = bridge.config()
		local snapshot = bridge.run({ state = state, complete_local = true })
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
		local bridge = require("ui.healthcheck.core")
		local documents = bridge.config()
		local document = Share.document(bridge.run(), documents.schema,
			require("infra.i18n").get(documents.schema.share_policy.notice_key))
		local url = IssueLink.build_url(documents.templates, documents.repository, "feature", document.fields)
		return M.perform({ action = ConfigKeys.COMMAND.SUGGEST_FEATURE, url = url }, {}, documents, {}, overrides, nil, owner)
	end)
end

return M
