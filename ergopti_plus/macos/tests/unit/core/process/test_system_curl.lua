--- tests/unit/core/process/test_system_curl.lua

--- ==============================================================================
--- MODULE: System curl gate (owned-runtimes row "/usr/bin/curl", SYS)
--- DESCRIPTION:
--- The driver downloads with the curl macOS ships and never replaces it. Before
--- this gate a missing or too old /usr/bin/curl surfaced only as a bare task
--- failure in whichever feature tried first. The gate reads the version once,
--- refuses every later curl start with one localized reason, tells the user
--- once, and the two native spawn entry points honour it.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs a body with the gate over scripted edges, then restores the native ones.
--- @param version_text string|nil What `curl --version` prints.
--- @param body function Receives the gate, the probe count and the notifications.
local function with_gate(version_text, body)
	local SystemCurl = require("core.network.adapters.system_curl")
	local probes, told = { n = 0 }, {}
	SystemCurl._set_deps({
		read_version = function() probes.n = probes.n + 1 return version_text end,
		notify = function(title, text) told[#told + 1] = { title = title, body = text } return true end,
	})
	local ok, err = xpcall(body, debug.traceback, SystemCurl, probes, told)
	SystemCurl._set_deps(nil)
	if not ok then error(err, 0) end
end

helpers.describe("system curl gate", function()
	helpers.it("parses the version line and holds the minimum (system-curl-sys)", function()
		local SystemCurl = require("core.network.adapters.system_curl")
		helpers.assert_eq(SystemCurl.parse_version("curl 8.7.1 (x86_64-apple-darwin24.0) libcurl/8.7.1"), "8.7.1")
		helpers.assert_nil(SystemCurl.parse_version("zsh: no such file or directory"))
		helpers.assert_true(SystemCurl.verdict_for("curl 7.64.1 (x86_64-apple-darwin20.0)").ok)
		local old = SystemCurl.verdict_for("curl 7.54.0 (x86_64-apple-darwin17.0)")
		helpers.assert_eq(old.reason, "too_old")
		helpers.assert_eq(old.found, "7.54.0")
		helpers.assert_eq(SystemCurl.verdict_for(nil).reason, "missing")
	end)

	helpers.it("checks once and accepts a shipped curl (system-curl-sys)", function()
		with_gate("curl 8.7.1 (arm64-apple-darwin24.0)\n", function(SystemCurl, probes, told)
			helpers.assert_true(SystemCurl.check("first"))
			helpers.assert_true(SystemCurl.check("second"))
			helpers.assert_eq(probes.n, 1, "the version is read once per session")
			helpers.assert_eq(#told, 0)
		end)
	end)

	helpers.it("refuses a too old curl with a localized reason, told once (system-curl-sys)", function()
		with_gate("curl 7.54.0 (x86_64-apple-darwin17.0)\n", function(SystemCurl, probes, told)
			local ok, reason = SystemCurl.check("first")
			helpers.assert_eq(ok, false)
			helpers.assert_true(type(reason) == "string" and reason:find("7.54.0", 1, true) ~= nil,
				"the reason names the version found")
			helpers.assert_true(reason:find(SystemCurl.MINIMUM_VERSION, 1, true) ~= nil,
				"the reason names the minimum")
			helpers.assert_eq(select(1, SystemCurl.check("second")), false)
			helpers.assert_eq(probes.n, 1)
			helpers.assert_eq(#told, 1, "the user is told once, every refusal is logged")
		end)
	end)

	helpers.it("refuses a curl start in ShellRunner.spawn and TaskLifecycle.native (system-curl-sys)", function()
		with_gate(nil, function(SystemCurl, _, told)
			local created = 0
			local saved_new = hs.task.new
			hs.task.new = function(...) created = created + 1 return saved_new(...) end
			local ok, err = xpcall(function()
				local handle = require("core.process.adapters.shell_runner").spawn(SystemCurl.PATH, { "--version" }, function() end)
				helpers.assert_eq(handle.start(), false, "a refused curl handle never starts")
				helpers.assert_nil(require("core.process.adapters.task_lifecycle").native("probe", SystemCurl.PATH,
					function() end, { "--version" }))
				helpers.assert_eq(created, 0, "no native task exists for a refused curl")
			end, debug.traceback)
			hs.task.new = saved_new
			if not ok then error(err, 0) end
			helpers.assert_eq(#told, 1)
		end)
	end)
end)
