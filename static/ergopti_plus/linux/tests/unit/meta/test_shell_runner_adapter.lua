--- tests/unit/meta/test_shell_runner_adapter.lua
---
--- Contract tests for the shell_runner adapter — the Linux driver's single
--- source of truth for shell argument quoting and exit-code handling.
---
--- The guarantee under test is NOT "quote() spells the escape a certain way",
--- it is "whatever quote() returns, a POSIX shell reads back as the original
--- string and executes none of it". Pinning the spelling would pass for a
--- broken escape that happens to contain the right characters, so the corpus
--- is decoded twice: once by an independent single-quote parser written from
--- the sh grammar, and once by a real POSIX shell: /bin/sh on Linux, and
--- the sh shipping with Git for Windows on a Windows checkout, where the
--- suite's Windows test mode routes the printf line through it.
---
--- The exit-code cases run for real on purpose: os.execute() reports success
--- as 0 under Lua 5.1/LuaJIT and as `true` from 5.2 on, and CI runs LuaJIT
--- while developers run 5.4 — a seam-only test would never notice a
--- normalisation that is dead on one of the two.

local helpers = require("tests.helpers")
local sh      = helpers.load_module("adapters.shell_runner")

helpers.describe("linux-shell-command-nul", function()
	for _, method in ipairs({ "run", "exec", "exec_line", "exec_stdin", "exec_exact_stdin", "exec_checked" }) do
		for index, command in ipairs({ "printf literal\0private-suffix", "printf literal\0", "\0printf literal" }) do
			helpers.it("linux-shell-command-nul: " .. method .. " refuses byte position " .. index .. " before dispatch", function()
				local calls = 0
				local shell = helpers.load_module("adapters.shell_runner")
				shell._set_runner(function() calls = calls + 1; return "Shortened prefix stdout" end)
				local value, output, reason
				if method == "exec_stdin" or method == "exec_exact_stdin" then value = shell[method](command, "valid stdin")
				else value, output, reason = shell[method](command) end
				shell._reset_runner()
				helpers.assert_eq(calls, 0, "invalid native bytes must not reach even a simulated dispatcher")
				if method == "run" or method == "exec_checked" then helpers.assert_eq(value, false)
				elseif method == "exec_line" then helpers.assert_nil(value)
				else helpers.assert_eq(value, "") end
				if method == "exec_checked" then
					helpers.assert_eq(output, "")
					helpers.assert_true(type(reason) == "string" and #reason < 200)
					helpers.assert_contains(reason, "NUL")
					helpers.assert_nil(reason:find("private-suffix", 1, true))
				end
			end)
		end
	end
	for _, method in ipairs({ "exec_stdin", "exec_exact_stdin" }) do
		helpers.it("linux-shell-command-nul: " .. method .. " refuses a NUL-bearing textual stdin before dispatch", function()
			local calls = 0
			local shell = helpers.load_module("adapters.shell_runner")
			shell._set_runner(function() calls = calls + 1; return "Truncated prefix" end)
			local value = shell[method]("cat", "prefix\0private-suffix")
			shell._reset_runner()
			helpers.assert_eq(value, "")
			helpers.assert_eq(calls, 0)
		end)
	end
end)

helpers.describe("linux-shell-private-error-receipts", function()
	for _, failure in ipairs({ "errno7", "errno24", "no errno", "open raised", "read raised", "close raised" }) do
		helpers.it("linux-shell-private-error-receipts: " .. failure .. " cannot echo command arguments", function()
			local Logger = require("logger.shim")
			local shell = helpers.load_module("adapters.shell_runner")
			local previous_popen, previous_level = io.popen, Logger.get_level()
			local canary = "SYNTHETIC_PRIVATE_PIPE_ARGUMENT"
			Logger.set_level("debug")
			Logger.ring_buffer_clear()
			io.popen = function(command)
				local message = command .. ": " .. canary .. " native refusal"
				if failure == "open raised" then error(message) end
				if failure == "read raised" or failure == "close raised" then
					return {
						read = function()
							if failure == "read raised" then error(message) end
							return "0 3\nabc"
						end,
						close = function() error(message) end,
					}
				end
				local code = failure == "errno7" and 7 or (failure == "errno24" and 24 or nil)
				return nil, message, code
			end
			local ok, err = xpcall(function()
				local accepted, output, reason = shell.exec_checked("printf '%s' " .. shell.quote(canary))
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(output, "")
				for _, line in ipairs(Logger.ring_buffer_snapshot()) do
					helpers.assert_nil(line:find(canary, 1, true), "logger cannot copy private native errors")
				end
				helpers.assert_eq(type(reason), "string")
				helpers.assert_true(reason ~= "" and #reason < 200, "failure still needs a bounded diagnostic")
				helpers.assert_nil(reason:find(canary, 1, true), "returned failure cannot carry caller data")
				if failure == "errno7" then helpers.assert_contains(reason, "errno 7") end
				if failure == "errno24" then helpers.assert_contains(reason, "errno 24") end
			end, debug.traceback)
			io.popen = previous_popen
			Logger.set_level(previous_level)
			if not ok then error(err, 0) end
		end)
	end
end)

helpers.describe("linux-checked-output-receipts", function()
	helpers.it("linux-checked-output-receipts: quotes the owner's complete literal staging directory", function()
		local dir = "/owned/quote-é'漢\nparent"
		local previous_popen, command, calls = io.popen, nil, 0
		io.popen = function(value)
			command, calls = value, calls + 1
			return { read = function() return "0 3\nabc\nERGOPTI_CAPTURE_COMPLETE\n" end, close = function() return true end }
		end
		local protected, ok, output, reason = pcall(sh.exec_checked, "printf abc", { output_dir = dir })
		io.popen = previous_popen
		helpers.assert_true(protected, tostring(ok))
		helpers.assert_true(ok, tostring(reason))
		helpers.assert_eq(output, "abc")
		helpers.assert_eq(calls, 1)
		helpers.assert_contains(command, sh.quote(dir), "selected staging must cross native argv as one literal word")
	end)
	for _, row in ipairs({
		{ name = "invalid options", options = false },
		{ name = "numeric directory", options = { output_dir = 42 } },
		{ name = "empty directory", options = { output_dir = "" } },
		{ name = "NUL directory", options = { output_dir = "/owned/\0suffix" } },
	}) do
		helpers.it("linux-checked-output-receipts: refuses " .. row.name .. " before dispatch", function()
			local calls = 0
			sh._set_runner(function() calls = calls + 1; return "abc" end)
			local protected, ok, output, reason = pcall(sh.exec_checked, "printf abc", row.options)
			sh._reset_runner()
			helpers.assert_true(protected, tostring(ok))
			helpers.assert_eq(ok, false)
			helpers.assert_eq(output, "")
			helpers.assert_true(type(reason) == "string" and reason ~= "")
			helpers.assert_eq(calls, 0)
		end)
	end
end)

helpers.describe("linux-checked-pipe-completion", function()
	-- These are simulated libc receipts; the hardware capture test runs the
	-- complete-frame transmitter failure through native children and pipes.
	for _, failure in ipairs({ "read returned error", "read raised", "close returned error", "close raised", "missing trailer" }) do
		helpers.it("linux-checked-pipe-completion: rejects " .. failure .. " and closes once", function()
			local shell = helpers.load_module("adapters.shell_runner")
			local previous_popen, closes = io.popen, 0
			local canary = "SYNTHETIC_PRIVATE_RECEIPT_ERROR"
			io.popen = function()
				return {
					read = function()
						if failure == "read returned error" then return nil, canary, 5 end
						if failure == "read raised" then error(canary) end
						return "0 3\nabc" .. (failure == "missing trailer" and "" or "\nERGOPTI_CAPTURE_COMPLETE\n")
					end,
					close = function()
						closes = closes + 1
						if failure == "close returned error" then return nil, canary, 10 end
						if failure == "close raised" then error(canary) end
						return true
					end,
				}
			end
			local ok, err = xpcall(function()
				local accepted, output, reason = shell.exec_checked("printf abc")
				helpers.assert_eq(accepted, false, "an incomplete capture must not certify success")
				helpers.assert_eq(closes, 1, "even failed reads must retire the pipe and reap its child")
				helpers.assert_eq(output, (failure == "close returned error" or failure == "missing trailer") and "abc" or "")
				helpers.assert_true(type(reason) == "string" and reason ~= "" and #reason < 200)
				helpers.assert_nil(reason:find(canary, 1, true), "libc error text must stay private")
			end, debug.traceback)
			io.popen = previous_popen
			if not ok then error(err, 0) end
		end)
	end
end)

-- Strings whose characters the shell would otherwise act on. Each one is a
-- real payload this driver handles: SSIDs, window titles, clipboard content
-- and hotstring replacements are all user-authored.
local HOSTILE_CORPUS = {
	"",
	"plain",
	"it's",
	"aujourd'hui",
	"a'b'c",
	"$HOME",
	"`date`",
	"$(id)",
	"x; rm -rf /",
	"a && b || c",
	"pipe | grep",
	"tab\tand\nnewline",
	'double "quoted"',
	"back\\slash",
	"café résumé",
	"*",
	"~",
}

--- Decodes one POSIX shell word written with single quotes back to its literal
--- value. Written from the sh grammar, independently of quote(): a quote opens
--- and closes a literal span, and outside a span only a backslash escape is
--- tolerated. ANY other character outside a span would be interpreted by the
--- shell, so it is reported as a leak rather than decoded.
--- @param word string The shell word to decode.
--- @return string|nil The literal value, or nil plus a reason on a leak.
local function shell_unquote(word)
	local out, i, n = {}, 1, #word
	local in_span = false
	while i <= n do
		local c = word:sub(i, i)
		if in_span then
			if c == "'" then in_span = false else out[#out + 1] = c end
			i = i + 1
		elseif c == "'" then
			in_span = true
			i = i + 1
		elseif c == "\\" and i < n then
			out[#out + 1] = word:sub(i + 1, i + 1)
			i = i + 2
		else
			return nil, string.format("character %q at offset %d is outside every quoted span", c, i)
		end
	end
	if in_span then return nil, "unterminated single-quoted span" end
	return table.concat(out)
end

helpers.describe("shell_runner adapter", function()

	helpers.describe("module structure", function()
		for _, name in ipairs({ "quote", "run", "exec", "exec_checked", "exec_line", "has_command" }) do
			helpers.it("exports " .. name, function()
				helpers.assert_type(sh[name], "function", name .. " must be exported")
			end)
		end
	end)


	helpers.describe("quote() — inertness", function()
		helpers.it("round-trips every hostile string through an independent sh parser", function()
			for _, sample in ipairs(HOSTILE_CORPUS) do
				local word = sh.quote(sample)
				local decoded, why = shell_unquote(word)
				helpers.assert_true(decoded ~= nil, string.format(
					"quote(%q) = %s leaks to the shell: %s", sample, word, tostring(why)))
				helpers.assert_eq(decoded, sample, string.format(
					"quote(%q) must read back as the original string, not as %s", sample, tostring(decoded)))
			end
		end)

		helpers.it("uses the close-escape-reopen idiom for an embedded quote", function()
			local word = sh.quote("it's")
			helpers.assert_eq(word, "'it'\\''s'",
				"a raw quote would terminate the word and hand the remainder to the shell as syntax")
			local at = word:find("'\\''", 1, true)
			helpers.assert_true(at ~= nil and word:byte(at + 1) == 92,
				"the escape must be a real backslash (byte 92), not a lookalike character")
		end)

		helpers.it("escapes every quote, not just the first", function()
			-- One unescaped quote anywhere is enough to break out of the word.
			local word = sh.quote("a'b'c")
			local n, pos = 0, 1
			while true do
				local at = word:find("'\\''", pos, true)
				if not at then break end
				n, pos = n + 1, at + 4
			end
			helpers.assert_eq(n, 2, "both embedded quotes must be escaped")
		end)

		helpers.it("never returns an empty word", function()
			-- An empty replacement would silently shift every following argument
			-- one position to the left rather than passing an empty argument.
			helpers.assert_eq(sh.quote(""), "''", "the empty string must still occupy one argument")
			helpers.assert_eq(sh.quote(nil), "''", "nil must degrade to an empty argument, not to nothing")
		end)

		helpers.it("does not emit a Lua literal quoting like string.format('%q')", function()
			-- %q is a LUA quoter: it wraps in double quotes, where $, ` and $( )
			-- stay live. That is the exact mistake this adapter exists to retire.
			local word = sh.quote("$(id)")
			helpers.assert_eq(word:sub(1, 1), "'", "the word must be single-quoted")
			helpers.assert_true(word:find('"', 1, true) == nil,
				"a double-quoted word would still expand $( ) — it is not inert")
		end)
	end)


	helpers.describe("quote() — real shell round-trip", function()
		helpers.it("a real POSIX shell reads back exactly what was quoted", function()
			local checked = 0
			for _, sample in ipairs(HOSTILE_CORPUS) do
				-- printf '%s' is the only echo-like builtin that does not
				-- reinterpret backslashes, so the comparison stays exact.
				local got = sh.exec("printf '%s' " .. sh.quote(sample))
				helpers.assert_eq(got, sample, string.format(
					"the shell must receive %q as data, not as code", sample))
				checked = checked + 1
			end
			helpers.assert_eq(checked, #HOSTILE_CORPUS,
				"every corpus entry must be exercised — a silently emptied loop would prove nothing")
		end)
	end)


	helpers.describe("run() — exit status normalisation", function()
		helpers.it("reports a zero exit as success on this interpreter", function()
			-- Runs for real: this is the assertion that catches a normalisation
			-- written for only one of Lua 5.1/LuaJIT (0) and Lua 5.2+ (true).
			helpers.assert_eq(sh.run("exit 0"), true, "exit 0 must be success")
		end)

		helpers.it("reports a non-zero exit as failure on this interpreter", function()
			helpers.assert_eq(sh.run("exit 3"), false, "exit 3 must be failure")
		end)

		helpers.it("refuses an empty command instead of running the shell bare", function()
			helpers.assert_eq(sh.run(""), false, "an empty command is a caller bug, not a success")
			helpers.assert_eq(sh.run(nil), false, "nil is a caller bug, not a success")
		end)
	end)


	helpers.describe("exec() / exec_line()", function()
		helpers.it("captures stdout", function()
			helpers.assert_contains(sh.exec("echo ok"), "ok", "stdout must reach the caller")
		end)

		helpers.it("returns the empty string rather than nil on a refused command", function()
			helpers.assert_eq(sh.exec(""), "", "callers concatenate the result; nil would raise")
			helpers.assert_eq(sh.exec(nil), "", "callers concatenate the result; nil would raise")
		end)

		helpers.it("exec_line returns only the first line", function()
			sh._set_runner(function() return "first\nsecond\nthird\n" end)
			local line = sh.exec_line("irrelevant")
			sh._reset_runner()
			helpers.assert_eq(line, "first", "only the first line is the value callers parse")
		end)

		helpers.it("exec_line returns nil on empty output", function()
			sh._set_runner(function() return "" end)
			local line = sh.exec_line("irrelevant")
			sh._reset_runner()
			helpers.assert_nil(line, "no output means no value — tonumber(nil) is the caller's guard")
		end)

		helpers.it("exec_checked distinguishes empty output from command failure", function()
			local empty_ok, empty_output = sh.exec_checked("printf ''")
			local failed_ok, failed_output, failed_error = sh.exec_checked("exit 7")
			helpers.assert_eq(empty_ok, true, "successful empty stdout must remain success")
			helpers.assert_eq(empty_output, "", "successful empty stdout must remain empty")
			helpers.assert_eq(failed_ok, false, "a non-zero exit must remain failure")
			helpers.assert_eq(failed_output, "", "a failing silent command has no stdout")
			helpers.assert_true(type(failed_error) == "string" and failed_error ~= "",
				"failure must carry a diagnostic for its caller")
		end)
	end)


	helpers.describe("has_command()", function()
		helpers.it("quotes the binary name it probes", function()
			local seen
			sh._set_runner(function(cmd) seen = cmd end)
			sh.has_command("; rm -rf /")
			sh._reset_runner()
			helpers.assert_true(seen ~= nil, "a probe command must be composed")
			helpers.assert_contains(seen, sh.quote("; rm -rf /"),
				"a probe is still a shell command — an unquoted name executes")
		end)

		helpers.it("returns false for a binary that cannot exist", function()
			helpers.assert_eq(sh.has_command("ergopti-no-such-binary-9d3f"), false,
				"an absent binary must probe false, not truthy")
		end)

		helpers.it("returns false for an empty name", function()
			helpers.assert_eq(sh.has_command(""), false, "an empty name must not probe the shell at all")
			helpers.assert_eq(sh.has_command(nil), false, "nil must not probe the shell at all")
		end)
	end)


	helpers.describe("test seam", function()
		helpers.it("hands the composed command over instead of executing it", function()
			local seen
			sh._set_runner(function(cmd) seen = cmd end)
			sh.run("echo captured")
			sh._reset_runner()
			helpers.assert_eq(seen, "echo captured", "the seam must receive the exact command")
		end)

		helpers.it("a boolean from the runner simulates the exit status", function()
			-- Without this, every seamed run() succeeds and no test can drive a
			-- caller's failure branch — the branch that decides whether a tool
			-- is considered installed.
			sh._set_runner(function() return false end)
			local failed = sh.run("irrelevant")
			sh._set_runner(function() return true end)
			local succeeded = sh.run("irrelevant")
			sh._reset_runner()
			helpers.assert_eq(failed, false, "a runner returning false must surface as a failed command")
			helpers.assert_eq(succeeded, true, "a runner returning true must surface as a successful command")
		end)

		helpers.it("_reset_runner restores real execution", function()
			sh._set_runner(function() end)
			sh._reset_runner()
			helpers.assert_contains(sh.exec("echo restored"), "restored",
				"a seam left installed would silently neuter every later test")
		end)
	end)

end)
