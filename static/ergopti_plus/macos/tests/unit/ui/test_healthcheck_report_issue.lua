--- tests/unit/ui/test_healthcheck_report_issue.lua

--- ==============================================================================
--- MODULE: Report A Bug / Suggest A Feature (macOS)
--- DESCRIPTION:
--- Debug > Report a bug copies the full diagnostics to the clipboard, saves
--- them as a Markdown file beside today's errors file, reveals it, then opens
--- the GitHub bug form with a bounded prefill; Suggest a feature opens the
--- feature form. Everything that leaves the machine is redacted: the home
--- folder and the account name must reach neither the clipboard, the file nor
--- the URL (report-bug-flow).
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

-- A level no variant reaches: the headless logger re-points its dated paths on
-- the next line it writes, which would move the errors file under the test
local SILENT_LEVEL = 1000

local FIXED_NOW = 1790000000
local HOME = "/Users/jdoe"

--- The repository the URLs must point at, read from its single source.
--- @return table { owner, repo }
local function repository()
	local fh = assert(io.open(helpers.shared("modules/updater/defaults.json"), "rb"))
	local defaults = Json.decode(fh:read("*a"))
	fh:close()
	return defaults.github
end

--- Runs the callback with the report module over the real healthcheck, whose
--- native probes are replaced by collectors that mention the home folder.
--- @param callback function Receives (Report, calls, overrides, logs_dir).
local function with_report(callback)
	helpers.with_stub_scope({
		"infra.logger", "logger", "ui.healthcheck.core", "ui.healthcheck.helpers", "ui.healthcheck.report",
	}, function()
		local Logger = helpers.load_with_stubs("infra.logger")
		Logger.set_level(SILENT_LEVEL)
		local logs_dir = helpers.temp_dir() .. "/ergopti_report_logs"
		Logger.ERRORS_LOG_FILE = logs_dir .. "/ErgoptiPlus_errors_2026-09-23.log"
		local collectors = helpers.load_with_stubs("ui.healthcheck.helpers")
		for name, value in pairs(collectors) do
			if type(value) == "function" then collectors[name] = function() return {} end end
		end
		collectors.sys_info = function()
			return { os_version = "Version 15.1 (Build 24B83)", arch = "arm64", git_hash = "f58d15798",
				commit_source = "build", config_dir = HOME .. "/.config/ergopti_plus" }
		end
		collectors.collect_logs_info = function()
			return { errors_today = HOME .. "/Library/Logs/ergopti_plus/ErgoptiPlus_errors_2026-09-23.log" }
		end
		helpers.load_with_stubs("ui.healthcheck.core")
		local Report = helpers.load_with_stubs("ui.healthcheck.report")
		local calls = { copy = {}, save = {}, reveal = {}, open_url = {}, notify = {} }
		local overrides = {
			identity = function() return { home = HOME, user = "jdoe" } end,
			now = function() return FIXED_NOW end,
			copy = function(text) calls.copy[#calls.copy + 1] = text; return true end,
			save = function(dir, name, text)
				calls.save[#calls.save + 1] = { dir = dir, name = name, text = text }
				return dir .. "/" .. name
			end,
			reveal = function(path) calls.reveal[#calls.reveal + 1] = path; return true end,
			open_url = function(url) calls.open_url[#calls.open_url + 1] = url; return true end,
			notify = function(title, body, kind)
				calls.notify[#calls.notify + 1] = { title = title, body = body, kind = kind }
				return true
			end,
		}
		callback(Report, calls, overrides, logs_dir)
	end)
end

helpers.describe("healthcheck report issue (report-bug-flow)", function()
	helpers.it("copies, saves, reveals, then opens the bug form (report-bug-flow)", function()
		with_report(function(Report, calls, overrides, logs_dir)
			helpers.assert_eq(Report.report_bug(overrides), true)
			helpers.assert_eq(#calls.copy, 1, "the diagnostics reach the clipboard once")
			local markdown = calls.copy[1]
			helpers.assert_true(markdown:sub(1, 26) == "# ErgoptiPlus diagnostics\n", "a Markdown report")
			helpers.assert_contains(markdown, "errors_today: ~/Library/Logs/ergopti_plus/")
			helpers.assert_true(not markdown:find(HOME, 1, true), "the home folder never leaves the machine")
			helpers.assert_true(not markdown:find("jdoe", 1, true), "nor the account name")

			helpers.assert_eq(#calls.save, 1)
			helpers.assert_eq(calls.save[1].dir, logs_dir .. "/diagnostics")
			helpers.assert_true(calls.save[1].name:match("^ergopti%-diagnostics%-macos%-[%w%._%-]+%-20260921T141320Z%.md$")
				~= nil, "the saved name carries the driver, the version and the UTC time: " .. calls.save[1].name)
			helpers.assert_eq(calls.save[1].text, markdown, "the saved file is what was copied")
			helpers.assert_eq(calls.reveal[1], logs_dir .. "/diagnostics/" .. calls.save[1].name)

			helpers.assert_eq(#calls.open_url, 1)
			local url = calls.open_url[1]
			local repo = repository()
			local prefix = "https://github.com/" .. repo.owner .. "/" .. repo.repo
				.. "/issues/new?template=bug_report.yml&version="
			helpers.assert_eq(url:sub(1, #prefix), prefix)
			helpers.assert_contains(url, "&driver=macos&diagnostics=Version%3A%20")
			helpers.assert_true(#url <= 7000, "the prefill stays within the URL budget")
			helpers.assert_true(not url:find("jdoe", 1, true), "the URL carries no account name")

			helpers.assert_eq(#calls.notify, 1)
			helpers.assert_eq(calls.notify[1].kind, "info")
		end)
	end)

	helpers.it("stops before the browser when the clipboard refuses (report-bug-flow)", function()
		with_report(function(Report, calls, overrides)
			overrides.copy = function() return false end
			helpers.assert_eq(Report.report_bug(overrides), false)
			helpers.assert_eq(#calls.save, 0, "nothing is saved")
			helpers.assert_eq(#calls.open_url, 0, "the form never opens without its report")
			helpers.assert_eq(#calls.notify, 1)
			helpers.assert_eq(calls.notify[1].kind, "error")
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
			helpers.assert_eq(calls.notify[1].kind, "error")
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
			helpers.assert_contains(calls.open_url[1], "&os=macOS%20Version%2015.1")
			helpers.assert_contains(calls.open_url[1], "&driver=macos")
		end)
	end)
end)
