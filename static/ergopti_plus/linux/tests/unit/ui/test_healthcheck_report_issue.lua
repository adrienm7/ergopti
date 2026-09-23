--- tests/unit/ui/test_healthcheck_report_issue.lua

--- ==============================================================================
--- MODULE: Report A Bug / Suggest A Feature (Linux)
--- DESCRIPTION:
--- Debug > Report a bug copies the full diagnostics to the clipboard, saves
--- them as a Markdown file beside today's errors file, opens its folder, then
--- opens the GitHub bug form with a bounded prefill; Suggest a feature opens
--- the feature form. Everything that leaves the machine is redacted: the home
--- folder and the account name must reach neither the clipboard, the file nor
--- the URL (report-bug-flow).
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local HOME = "/home/jdoe"
local LOGS_DIR = "/var/tmp/ergopti_report_logs"
local FIXED_NOW = 1790000000

--- The repository the URLs must point at, read from its single source.
--- @return table { owner, repo }
local function repository()
	local path = helpers.driver_root() .. "/../_shared/modules/updater/defaults.json"
	local fh = assert(io.open(path, "rb"))
	local defaults = Json.decode(fh:read("*a"))
	fh:close()
	return defaults.github
end

--- Runs the callback with the config folder under the fixture home and the
--- errors file in a known folder, restoring both afterwards.
--- @param callback function Receives (Report, calls, overrides).
local function with_report(callback)
	local ConfigPaths = require("infra.config_paths")
	local LoggerSink = require("infra.logger_sink")
	local saved_config, saved_errors = ConfigPaths.get_config_dir, LoggerSink.errors_log_path
	ConfigPaths.get_config_dir = function() return HOME .. "/.config/ergopti_plus" end
	LoggerSink.errors_log_path = function() return LOGS_DIR .. "/ErgoptiPlus_errors_2026-09-21.log" end
	local calls = { copy = {}, save = {}, reveal = {}, open_url = {}, notify = {} }
	local overrides = {
		identity = function() return { home = HOME, user = "jdoe" } end,
		now = function() return FIXED_NOW end,
		state = function() return {} end,
		copy = function(text) calls.copy[#calls.copy + 1] = text; return true end,
		save = function(dir, name, text)
			calls.save[#calls.save + 1] = { dir = dir, name = name, text = text }
			return dir .. "/" .. name
		end,
		reveal = function(path) calls.reveal[#calls.reveal + 1] = path; return true end,
		open_url = function(url) calls.open_url[#calls.open_url + 1] = url; return true end,
		notify = function(title, body, level)
			calls.notify[#calls.notify + 1] = { title = title, body = body, level = level }
			return true
		end,
	}
	local ok, err = pcall(callback, helpers.load_module("ui.healthcheck.report"), calls, overrides)
	ConfigPaths.get_config_dir, LoggerSink.errors_log_path = saved_config, saved_errors
	if not ok then error(err, 0) end
end

helpers.describe("healthcheck report issue (linux)", function()
	helpers.it("copies, saves, reveals, then opens the bug form (report-bug-flow)", function()
		with_report(function(Report, calls, overrides)
			helpers.assert_eq(Report.report_bug(overrides), true)
			helpers.assert_eq(#calls.copy, 1, "the diagnostics reach the clipboard once")
			local markdown = calls.copy[1]
			helpers.assert_eq(markdown:sub(1, 26), "# ErgoptiPlus diagnostics\n", "a Markdown report")
			helpers.assert_contains(markdown, "config_dir: ~/.config/ergopti_plus")
			helpers.assert_true(not markdown:find("jdoe", 1, true), "the account never leaves the machine")

			helpers.assert_eq(#calls.save, 1)
			helpers.assert_eq(calls.save[1].dir, LOGS_DIR .. "/diagnostics")
			helpers.assert_true(calls.save[1].name:match("^ergopti%-diagnostics%-linux%-[%w%._%-]+%-20260921T141320Z%.md$")
				~= nil, "the saved name carries the driver, the version and the UTC time: " .. calls.save[1].name)
			helpers.assert_eq(calls.save[1].text, markdown, "the saved file is what was copied")
			helpers.assert_eq(calls.reveal[1], LOGS_DIR .. "/diagnostics/" .. calls.save[1].name)

			local url = calls.open_url[1]
			local repo = repository()
			local prefix = "https://github.com/" .. repo.owner .. "/" .. repo.repo
				.. "/issues/new?template=bug_report.yml&version="
			helpers.assert_eq(url:sub(1, #prefix), prefix)
			helpers.assert_contains(url, "&driver=linux&diagnostics=Version%3A%20")
			helpers.assert_true(#url <= 7000, "the prefill stays within the URL budget")
			helpers.assert_true(not url:find("jdoe", 1, true), "the URL carries no account name")
			helpers.assert_eq(calls.notify[1].level, "info")
		end)
	end)

	helpers.it("stops before the browser when the clipboard refuses (report-bug-flow)", function()
		with_report(function(Report, calls, overrides)
			overrides.copy = function() return false end
			helpers.assert_eq(Report.report_bug(overrides), false)
			helpers.assert_eq(#calls.save, 0, "nothing is saved")
			helpers.assert_eq(#calls.open_url, 0, "the form never opens without its report")
			helpers.assert_eq(calls.notify[1].level, "error")
		end)
	end)

	helpers.it("refuses to report when the home folder is unknown (report-bug-flow)", function()
		with_report(function(Report, calls, overrides)
			-- Nothing could remove the home folder, so every path under it would leak
			overrides.identity = function() return { user = "jdoe" } end
			helpers.assert_eq(Report.report_bug(overrides), false)
			helpers.assert_eq(#calls.copy, 0, "nothing unredacted reaches the clipboard")
			helpers.assert_eq(#calls.save, 0, "nothing is saved")
			helpers.assert_eq(#calls.open_url, 0, "the form never opens")
			helpers.assert_eq(calls.notify[1].level, "error")
		end)
	end)

	helpers.it("opens the feature form with the version and the system (report-bug-flow)", function()
		with_report(function(Report, calls, overrides)
			helpers.assert_eq(Report.suggest_feature(overrides), true)
			helpers.assert_eq(#calls.copy, 0, "a feature request copies nothing")
			local repo = repository()
			local prefix = "https://github.com/" .. repo.owner .. "/" .. repo.repo
				.. "/issues/new?template=feature_request.yml&version="
			helpers.assert_eq(calls.open_url[1]:sub(1, #prefix), prefix)
			helpers.assert_contains(calls.open_url[1], "&driver=linux")
		end)
	end)
end)
