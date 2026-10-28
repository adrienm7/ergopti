--- tests/unit/modules/updater/lifecycle/test_release_arming_receipt.lua

--- ==============================================================================
--- MODULE: Detached Release Arming Receipts
--- DESCRIPTION:
--- Native task admission is not the detached installer's arming receipt. Exercise
--- the public installer with faithful asynchronous ShellRunner completion ports.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_installer(options, check)
	options = options or {}
	helpers.with_stub_scope({ "modules.updater.release_installer", "infra.logger", "infra.paths",
		"adapters.file_system", "adapters.json_codec", "adapters.shell_runner" }, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.paths"] = { shared = function(path)
			helpers.assert_eq(path, "../macos/adapters/release_stage.sh")
			return helpers.driver_root() .. "adapters/release_stage.sh"
		end }
		package.loaded["adapters.file_system"] = { read = function(path)
			local file = assert(io.open(path, "rb"))
			local content = assert(file:read("a")); assert(file:close()); return content
		end }
		package.loaded["adapters.json_codec"] = require("json")
		package.loaded["adapters.shell_runner"] = {}
		local installer = require("modules.updater.release_installer")
		installer._getenv = function(name)
			if name == "ERGOPTI_LAUNCHER_EXECUTABLE" and not options.source then
				return "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"
			end
			if name == "ERGOPTI_LAUNCHER_PID" then return "4242" end
		end
		local observed = { calls = 0, results = {} }
		installer._run = function(executable, args, completed)
			observed.calls = observed.calls + 1
			observed.executable, observed.args, observed.completed = executable, args, completed
			if options.early then completed(table.unpack(options.early)) end
			if options.throws then error("controlled dispatch refusal") end
			if options.dispatch ~= nil then return options.dispatch end
			return true
		end
		observed.done = function(...)
			observed.results[#observed.results + 1] = table.pack(...)
		end
		check(installer, observed)
	end)
end

helpers.describe("detached installer waits for its arming receipt", function()
	helpers.it("does not settle from dispatch alone (release-arming-receipt)", function()
		with_installer(nil, function(installer, seen)
			helpers.assert_eq(installer.arm_swap("/tmp/stage/app/ErgoptiPlus.app", seen.done), true)
			helpers.assert_eq(#seen.results, 0, "dispatch must not authorize quitting")
			seen.completed(true, "ARMED", "")
			helpers.assert_eq(#seen.results, 1)
			helpers.assert_eq(seen.results[1][1], true)
		end)
	end)

	for _, terminal in ipairs({ { false, "ARMED", "native refusal" }, { true, "", "" },
		{ true, "FOREIGN", "" }, { "true", "ARMED", "" }, { true, "ARMED\nextra", "" } }) do
		helpers.it("refuses completion " .. tostring(terminal[1]) .. "/" .. terminal[2]
			.. " (release-arming-refusal)", function()
			with_installer(nil, function(installer, seen)
				helpers.assert_eq(installer.arm_swap("/tmp/stage/app/ErgoptiPlus.app", seen.done), true)
				seen.completed(table.unpack(terminal))
				helpers.assert_eq(#seen.results, 1)
				helpers.assert_eq(seen.results[1][1], false, "an unarmed installer cannot authorize quitting")
				helpers.assert_eq(type(seen.results[1][2]), "string")
			end)
		end)
	end

	helpers.it("admits an early receipt only after literal dispatch true (release-arming-early)", function()
		with_installer({ early = { true, "ARMED", "" } }, function(installer, seen)
			helpers.assert_eq(installer.arm_swap("/tmp/stage/app/ErgoptiPlus.app", seen.done), true)
			helpers.assert_eq(#seen.results, 1)
			helpers.assert_eq(seen.results[1][1], true)
		end)
	end)

	for _, options in ipairs({ { dispatch = false }, { dispatch = "accepted" }, { throws = true } }) do
		options.early = { true, "ARMED", "" }
		helpers.it("revokes early and late receipts after dispatch " .. tostring(options.dispatch or options.throws)
			.. " (release-arming-dispatch)", function()
			with_installer(options, function(installer, seen)
				helpers.assert_eq(installer.arm_swap("/tmp/stage/app/ErgoptiPlus.app", seen.done), false)
				seen.completed(true, "ARMED", "")
				helpers.assert_eq(#seen.results, 0, "a refused acquisition has no accepted observer")
			end)
		end)
	end

	helpers.it("settles the exact request once (release-arming-one-shot)", function()
		with_installer(nil, function(installer, seen)
			helpers.assert_true(installer.arm_swap("/tmp/stage/app/ErgoptiPlus.app", seen.done))
			seen.completed(false, "", "refused")
			seen.completed(true, "ARMED", "")
			helpers.assert_eq(#seen.results, 1)
			helpers.assert_eq(seen.results[1][1], false)
		end)
	end)

	helpers.it("requires its asynchronous observer before dispatch (release-arming-callback)", function()
		with_installer(nil, function(installer, seen)
			helpers.assert_eq(installer.arm_swap("/tmp/stage/app/ErgoptiPlus.app"), false)
			helpers.assert_eq(seen.calls, 0)
		end)
	end)

	helpers.it("refuses invalid targets without native acquisition (release-arming-target)", function()
		with_installer(nil, function(installer, seen)
			helpers.assert_eq(installer.arm_swap("/etc/passwd", seen.done), false)
			helpers.assert_eq(seen.calls, 0)
		end)
		with_installer({ source = true }, function(installer, seen)
			helpers.assert_eq(installer.arm_swap("/tmp/stage/app/ErgoptiPlus.app", seen.done), false)
			helpers.assert_eq(seen.calls, 0)
		end)
	end)
end)

helpers.describe("physical detached arming handshake", function()
	local cases
	local function observed()
		if cases then return cases end
		local quote = require("infra.text_utils").shell_quote
		local output = require("tests.support.command_lines").read("python3 -B "
			.. quote(helpers.driver_root() .. "tests/support/modules/updater/release_arming_fixture.py")
			.. " " .. quote(helpers.driver_root()) .. " " .. quote(helpers.temp_dir())
			.. " --hostile-interpreter 2>&1")
		cases = assert(require("json").decode_lossless(table.concat(output, "\n")))
		helpers.assert_eq(#cases, 8, "every native refusal and healthy control must execute")
		return cases
	end
	for index, mode in ipairs({ "healthy", "log_refused", "early_exit", "missing", "foreign",
		"duplicate", "no_lf", "trailing_fragment" }) do
		helpers.it(mode .. " (release-arming-physical)", function()
			local result = observed()[index]
			helpers.assert_eq(result.mode, mode)
			helpers.assert_eq(result.hostile_bare_used, false, "the configured runtime must win over hostile bare lua")
			helpers.assert_eq(type(result.configured_lua), "string")
			helpers.assert_eq(result.interpreter_version, "Lua 5.4")
			helpers.assert_eq(result.retired, true, "all owned worker lifetime descriptors must retire")
			helpers.assert_eq(result.before_parent_exit, "installed")
			if mode == "healthy" then
				helpers.assert_eq(result.status, 0)
				helpers.assert_eq(result.stdout, "ARMED\n", "the foreground transport must preserve the exact receipt")
				helpers.assert_eq(result.installed, "chosen")
				helpers.assert_eq(result.previous, "installed")
				helpers.assert_eq(type(result.opened), "string")
			else
				helpers.assert_true(result.status ~= 0, "a failed detached worker must fail the foreground receipt")
				helpers.assert_eq(result.installed, "installed")
				helpers.assert_eq(require("json").is_null(result.previous), true)
				helpers.assert_eq(require("json").is_null(result.opened), true)
			end
		end)
	end
end)
