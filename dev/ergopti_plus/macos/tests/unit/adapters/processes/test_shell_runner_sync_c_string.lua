--- tests/unit/adapters/processes/test_shell_runner_sync_c_string.lua

--- ==============================================================================
--- MODULE: ShellRunner synchronous C-string boundary regression tests
--- DESCRIPTION:
--- hs.execute hands its command to popen(3) as a char *, so /bin/sh runs only
--- the prefix before an embedded NUL. exec() forwarded such a command and the
--- shell executed a different, shorter one (shell-sync-nul-2026-10-21). The
--- checked form must also refuse stdout whose shell did not exit 0, and the
--- exact-stdin transport must carry every byte, NUL included, through a
--- NUL-free command.
--- ==============================================================================

local helpers = require("tests.helpers")
local PrintfModel = require("tests.support.posix_printf_model")

--- Loads ShellRunner over an hs.execute double that records C-string commands.
--- @param answer function|nil Returns hs.execute's (output, status, type, code).
--- @return table ShellRunner, table executed, table logs
local function load_runner(answer)
	local executed, logs = {}, {}
	package.loaded["infra.logger"] = nil
	local ShellRunner = helpers.load_with_stubs("adapters.shell_runner", {
		execute = function(command)
			executed[#executed + 1] = command:match("^[^%z]*")
			if answer then return answer(command) end
			return "out\n", true, "exit", 0
		end,
	})
	local logger = helpers.make_logger_stub()
	logger.error = function(_, template, ...) logs[#logs + 1] = string.format(template, ...) end
	package.loaded["infra.logger"] = logger
	package.loaded["adapters.shell_runner"] = nil
	ShellRunner = require("adapters.shell_runner")
	return ShellRunner, executed, logs
end


helpers.describe("ShellRunner.exec: a command with NUL never reaches the shell (shell-sync-nul-2026-10-21)", function()
	helpers.it("refuses instead of running the prefix before the NUL", function()
		local ShellRunner, executed, logs = load_runner()
		helpers.assert_eq(ShellRunner.exec("/bin/mkdir -p '/tmp/a\0b' && /bin/chmod 700 '/tmp/a\0b'"), "")
		helpers.assert_eq(#executed, 0, "the shell would run '/bin/mkdir -p '/tmp/a' instead: "
			.. tostring(executed[1]))
		helpers.assert_eq(#logs, 1, "the refusal must be visible")
		helpers.assert_true(logs[1]:find("/tmp/a", 1, true) == nil, "the log must not quote the command")
	end)

	helpers.it("still runs an ordinary command and returns its stdout", function()
		local ShellRunner, executed = load_runner()
		helpers.assert_eq(ShellRunner.exec("/bin/echo out"), "out\n")
		helpers.assert_eq(executed, { "/bin/echo out" })
	end)
end)


helpers.describe("ShellRunner.exec_checked: stdout requires a zero exit", function()
	helpers.it("returns the exact stdout of a successful command", function()
		local ShellRunner = load_runner(function() return "a\0b\n", true, "exit", 0 end)
		helpers.assert_eq(ShellRunner.exec_checked("/bin/cat"), "a\0b\n")
	end)

	for _, receipt in ipairs({
		{ "a non-zero exit", { "partial", nil, "exit", 1 } },
		{ "a signal", { "partial", nil, "signal", 15 } },
		{ "a missing status", { "partial" } },
	}) do
		helpers.it("refuses the stdout of " .. receipt[1], function()
			local ShellRunner = load_runner(function() return table.unpack(receipt[2], 1, 4) end)
			local output, reason = ShellRunner.exec_checked("/usr/bin/openssl enc -d")
			helpers.assert_eq(output, nil)
			helpers.assert_type(reason, "string")
			helpers.assert_true(reason:find("openssl", 1, true) == nil, "the reason must not quote the command")
		end)
	end

	helpers.it("refuses a NUL-bearing command before the shell", function()
		local ShellRunner, executed = load_runner()
		helpers.assert_eq(ShellRunner.exec_checked("/bin/echo a\0b"), nil)
		helpers.assert_eq(#executed, 0)
	end)
end)


helpers.describe("ShellRunner.exact_stdin_pipeline: every byte reaches the consumer", function()
	local all_bytes = {}
	for byte = 0, 255 do all_bytes[#all_bytes + 1] = string.char(byte) end
	for _, case in ipairs({
		{ "empty", "" },
		{ "NUL before octal digits", "\0" .. "0777\0" },
		{ "literal escapes", "\\0 \\\\ \\c \\n \\x41 %s %b" },
		{ "option-looking operand", "-n" },
		{ "quotes and expansions", "it's \"$HOME\" `id` | openssl" },
		{ "trailing newlines", "line\n\n" },
		{ "every byte value", table.concat(all_bytes) },
	}) do
		helpers.it("delivers " .. case[1] .. " exactly", function()
			local ShellRunner = load_runner()
			local command = ShellRunner.exact_stdin_pipeline("/usr/bin/openssl dgst", case[2])
			helpers.assert_type(command, "string")
			helpers.assert_true(command:find("\0", 1, true) == nil, "the command must be a valid C string")
			local stdin, consumer = PrintfModel.parse_pipeline(command)
			helpers.assert_eq(stdin, case[2], "the consumer must read the exact bytes")
			helpers.assert_eq(consumer, "/usr/bin/openssl dgst")
		end)
	end

	helpers.it("refuses a consumer command containing NUL", function()
		local ShellRunner = load_runner()
		helpers.assert_eq(ShellRunner.exact_stdin_pipeline("/bin/cat\0x", "data"), nil)
	end)
end)
