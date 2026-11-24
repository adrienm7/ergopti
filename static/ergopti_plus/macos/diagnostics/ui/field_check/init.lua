--- diagnostics/ui/field_check/init.lua

--- ==============================================================================
--- MODULE: Field Check Window
--- DESCRIPTION:
--- The Debug menu's one-click Mac checks: a click runs the check
--- (diagnostics/engine/field_check/field_check.lua over the real ports), writes the evidence line to the
--- log and shows the result, one line per step, with a « Copy report » button.
---
--- FEATURES & RATIONALE:
--- 1. One click, no arguments: the menu row names the check; nothing else is
---    asked of the user. The key accounting check says once, in a
---    notification, that it watches the keyboard, and that it keeps counts only.
--- 2. The same text goes to the window and the clipboard, built from the same
---    privacy-safe result as the log line.
--- 3. Localized: every sentence comes from the locales; step values are raw
---    tokens (counts, states, versions).
--- 4. « Test everything » runs the plan's checks one after the other over the
---    same engine and shows one combined report; a check that misses its
---    deadline is abandoned so the next one can start.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")
local I18n = require("core.i18n.engine.i18n")
local Engine = require("diagnostics.engine.field_check.field_check")
local RunAll = require("diagnostics.engine.field_check.run_all")

local LOG = "diagnostics.ui.field_check"

--- Menu row id → check identity and window title key.
M.ROWS = {
	field_check_lease = { check = "lease", title = "menu.debug.field_check_lease" },
	field_check_owned_runtime = { check = "owned_runtime", title = "menu.debug.field_check_owned_runtime" },
	field_check_toolchain = { check = "toolchain", title = "menu.debug.field_check_toolchain" },
	field_check_login_items = { check = "login_items", title = "menu.debug.field_check_login_items" },
	field_check_key_accounting = { check = "key_accounting", title = "menu.debug.field_check_key_accounting", watches_keys = true },
}

--- Rows every driver shows (declared for all platforms in the shared manifest), as
--- opposed to the Mac-only ones above.
M.SHARED_ROWS = {
	field_check_network = { check = "network", title = "menu.debug.field_check_network" },
	composer_check = { check = "composer", title = "menu.debug.composer_check" },
}

--- The « Test everything » row and the title of its combined report (the row's own label).
M.ALL_ROW = require("settings.engine.keys").COMMAND.FIELD_REPORT
M.ALL_TITLE = "menu.debug." .. M.ALL_ROW

--- Reads and decodes one bundled JSON declaration; a missing or broken file raises.
--- @param path string|nil Absolute path.
--- @return table
local function read_json(path)
	assert(type(path) == "string", "field check: a declaration path is unresolved")
	local value, err = require("core.fs.adapters.json_codec").decode_file(path)
	assert(type(value) == "table", "field check: unreadable declaration: " .. tostring(err))
	return value
end

--- This driver's « Test everything » declarations: the shared plan, the field
--- run steps (their checks and deadlines) and the TODO-tests coverage.
--- @return table declaration, table steps, table coverage
local function declarations()
	local source = debug.getinfo(1, "S").source or ""
	local root = assert((source:sub(1, 1) == "@" and source:sub(2) or source):match("^(.*)/diagnostics/ui/field_check/init%.lua$"),
		"field check: the driver root is unresolved")
	local data = root .. "/diagnostics/data/"
	return read_json(require("core.fs.engine.paths").shared("diagnostics/data/field_check_all.json")),
		read_json(data .. "field_run.json").steps, read_json(data .. "field_todo_coverage.json")
end

--- Native services, replaceable by tests.
local function native()
	return {
		ports = function() return require("diagnostics.adapters.field_check_ports").new() end,
		notify = function(title, body, kind)
			return require("platform.focus.application_notifier").send(title, { body = body, kind = kind })
		end,
		alert = function(...) return require("core.ui.engine.dialog_util").block_alert(...) end,
		copy = function(text) return hs.pasteboard.setContents(text) end,
		after = function(seconds, fn) return require("core.events.timer_scheduler").after(seconds, fn) end,
		cancel = function(handle) return require("core.events.timer_scheduler").cancel(handle) end,
		declarations = declarations,
	}
end

--- Shows a finished report from a fresh turn, with « Copy report » and « Close ».
--- @param env table Native services.
--- @param title_key string Locale key of the window title.
--- @param text string The report text.
local function show_report(env, title_key, text)
	-- A modal dialog is shown from a fresh turn, not from the port callback.
	env.after(require("core.timing.engine.timings").sec("ui", "ui_handoff_ms"), function()
		local copy_label, close_label = I18n.get("field_check.copy"), I18n.get("field_check.close")
		local clicked = env.alert(I18n.get(title_key), text, copy_label, close_label)
		if clicked == copy_label then
			local ok = env.copy(text)
			Logger.info(LOG, "Report copy %s.", ok and "done" or "refused")
			if ok then env.notify(I18n.get(title_key), I18n.get("field_check.copied"), "info") end
		end
	end)
end

--- Runs the check of a Debug menu row.
--- @param row_id string A key of M.ROWS.
--- @param services table|nil Test doubles for native services.
--- @return boolean started
function M.run(row_id, services)
	local row = M.ROWS[row_id] or M.SHARED_ROWS[row_id]
	assert(row ~= nil, "field check: unknown menu row " .. tostring(row_id))
	local env = services or native()
	if Engine.is_running() then
		env.notify(I18n.get(row.title), I18n.get("field_check.busy"), "warn")
		return false
	end
	if row.watches_keys then
		env.notify(I18n.get(row.title), I18n.get("field_check.keys_prompt"), "info")
	end
	return Engine.run(row.check, env.ports(), function(result)
		show_report(env, row.title, Engine.format_text(result, I18n.get))
	end)
end

-- True while « Test everything » runs its sequence.
local _all_running = false

--- Runs every check of this driver's « Test everything » plan one after the
--- other (_shared/diagnostics/engine/field_check/run_all.lua), then shows one
--- combined report and writes its evidence line.
--- @param services table|nil Test doubles for native services.
--- @return boolean started
function M.run_all(services)
	local env = services or native()
	if _all_running or Engine.is_running() then
		env.notify(I18n.get(M.ALL_TITLE), I18n.get("field_check.busy"), "warn")
		return false
	end
	local declaration, steps, coverage = env.declarations()
	local plan = RunAll.plan(declaration, "hs", steps, coverage)
	_all_running = true
	Logger.start(LOG, "Test everything started: %d checks.", #plan.run)
	env.notify(I18n.get(M.ALL_TITLE), I18n.format("field_check.all.started", #plan.run), "info")
	RunAll.run(plan, {
		start = function(entry, on_result) return Engine.run(entry.check, env.ports(), on_result) end,
		after = env.after,
		cancel = env.cancel,
		abandon = function() Engine.abandon() end,
	}, function(summary)
		_all_running = false
		Logger.evidence(LOG, "Test everything result: %s", RunAll.format_log_line(summary))
		Logger.success(LOG, "Test everything finished: %s.", summary.passed and "pass" or "fail")
		show_report(env, M.ALL_TITLE, RunAll.format_text(summary, I18n.get))
	end)
	return true
end

--- Forgets a pending « Test everything »; tests only.
function M._reset()
	_all_running = false
end

return M
