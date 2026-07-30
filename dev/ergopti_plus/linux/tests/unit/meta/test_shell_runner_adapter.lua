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
--- the sh grammar (runs on every interpreter, including Windows dev boxes),
--- and once by a real /bin/sh on POSIX hosts.
---
--- The exit-code cases run for real on purpose: os.execute() reports success
--- as 0 under Lua 5.1/LuaJIT and as `true` from 5.2 on, and CI runs LuaJIT
--- while developers run 5.4 — a seam-only test would never notice a
--- normalisation that is dead on one of the two.

local helpers = require("tests.helpers")
local sh      = helpers.load_module("adapters.shell_runner")

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
		for _, name in ipairs({ "quote", "run", "exec", "exec_line", "has_command" }) do
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
		local is_posix = package.config:sub(1, 1) == "/"

		helpers.it("a real POSIX shell reads back exactly what was quoted", function()
			if not is_posix then
				print("  WARN: skipped — no POSIX shell on this host (Windows dev box); CI runs Linux")
				return
			end
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
