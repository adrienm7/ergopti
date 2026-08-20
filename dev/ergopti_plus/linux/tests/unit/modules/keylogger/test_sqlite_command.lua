--- tests/unit/modules/keylogger/test_sqlite_command.lua

--- ==============================================================================
--- MODULE: SQLite Command Builder Regression Test (Linux driver)
--- DESCRIPTION:
--- Regression guard for the blocker where the Linux keylogger wrote every typed
--- character, in plaintext, into a world-writable directory on every flush.
---
--- THE ORIGINAL DEFECT (modules/keylogger/sqlite_writer.lua, and its twin in
--- sqlite_reader.lua):
---     local tmp = os.tmpname()      -- reserves /tmp/lua_XXXXXX
---     os.remove(tmp)                -- … then throws the reservation away
---     local tmp_sql = tmp .. ".sql" -- … and opens a DIFFERENT, predictable path
---     io.open(tmp_sql, "w"):write(sql)
--- Three distinct leaks in four lines: the exclusive-create guarantee covered a
--- name that was never opened (so a symlink at the derived name redirects the
--- write), io.open creates 0666 & ~umask (world-readable on a default umask),
--- and the file lived for as long as sqlite3 took to run.
---
--- FEATURES & RATIONALE:
--- 1. Behavioural, not source-scanning, for the part that can be: the builder is
---    pure, so the composed command is asserted directly. io.popen never RAISES
---    on a malformed command — it EXECUTES it — so a test that only checked
---    "nothing crashed" would pass with no quoting whatsoever.
--- 2. The heredoc terminator is attacked, not assumed. Typed text is arbitrary,
---    so a user typing the token on a line of its own would close the script
---    early and hand the rest to the shell. Every boundary position is covered:
---    first line, middle, last line without a trailing newline, and a token that
---    collides twice.
--- 3. Exactness is asserted in BOTH directions. `<<` strips nothing, so only a
---    byte-for-byte equal line terminates. Extending the token for "TOKEN " or
---    " TOKEN" would be a bug in the opposite direction — it would mean the
---    guard fires on input that is already safe, hiding real collisions behind
---    noise.
--- 4. The source guard strips comment lines before searching. Without that step
---    every assertion here is a false green: the fix's own comments explain what
---    /tmp and os.tmpname used to do, so an un-stripped scan matches the prose
---    and reports the vulnerability as still present — or, worse, a re-introduced
---    call hides behind a comment that mentions it. The stripper is itself
---    tested, because a stripper that silently returned "" would make every
---    absence assertion below vacuously true.
--- ==============================================================================

local helpers = require("tests.helpers")

local DRIVER_ROOT = helpers.driver_root()

local Cmd = require("modules.keylogger.sqlite_command")

--- The token the builder starts from. Pinned here on purpose: if the production
--- constant is renamed, these collision tests must be re-read rather than
--- silently re-targeted at a token the builder no longer uses.
local BASE_TOKEN = "ERGOPTI_SQL"

--- Asserts a substring is absent. helpers has no negative form, and `find` with
--- plain=true is required so regex metacharacters in SQL are not interpreted.
local function assert_absent(haystack, needle, msg)
	helpers.assert_true(
		haystack:find(needle, 1, true) == nil,
		string.format("%s — unexpectedly found %q", msg or "assert_absent", needle)
	)
end

--- Reads a file relative to the driver root.
local function read_source(rel_path)
	local fh = io.open(DRIVER_ROOT .. "/" .. rel_path, "r")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- Drops lines whose first non-blank characters are a Lua comment marker.
--- Line-leading only: that is how code actually gets disabled, and it cannot
--- mangle a `--` that appears inside a string literal.
local function strip_comment_lines(src)
	local kept = {}
	for line in (src .. "\n"):gmatch("([^\n]*)\n") do
		if not line:match("^%s*%-%-") then kept[#kept + 1] = line end
	end
	return table.concat(kept, "\n")
end

--- Returns the comment-free source of a driver file, failing loudly when the
--- file is missing so a rename cannot make the guards below vacuous.
local function code_of(rel_path)
	local src = read_source(rel_path)
	helpers.assert_not_nil(src, "missing source file: " .. rel_path)
	return strip_comment_lines(src)
end




-- =========================================
-- =========================================
-- ======= 1/ The Stripper Itself ==========
-- =========================================
-- =========================================

helpers.describe("sqlite_command — the comment stripper is trustworthy", function()
	helpers.it("removes commented-out code", function()
		local stripped = strip_comment_lines("local a = 1\n-- local b = os.tmpname()\nlocal c = 3")
		assert_absent(stripped, "os.tmpname", "a commented call must not survive")
	end)

	helpers.it("removes indented comments and doc comments", function()
		local stripped = strip_comment_lines("\t-- os.tmpname()\n--- os.tmpname()\nlocal a = 1")
		assert_absent(stripped, "os.tmpname", "indented and --- comments must not survive")
	end)

	helpers.it("keeps real code", function()
		local stripped = strip_comment_lines("-- a comment\nlocal keep = os.tmpname()\n")
		helpers.assert_contains(stripped, "os.tmpname",
			"the stripper must not swallow live code — otherwise every absence test below is vacuous")
	end)

	helpers.it("keeps a trailing comment's line of code", function()
		local stripped = strip_comment_lines("local keep = 1 -- os.tmpname\n")
		helpers.assert_contains(stripped, "local keep = 1", "only line-leading comments are dropped")
	end)
end)




-- =========================================
-- =========================================
-- ======= 2/ Heredoc Framing ==============
-- =========================================
-- =========================================

helpers.describe("sqlite_command — the SQL travels on stdin, quoted", function()
	helpers.it("feeds the script through a heredoc, not a file", function()
		local cmd = Cmd.build("/db/metrics.sqlite", "SELECT 1;")
		helpers.assert_contains(cmd, "<<'" .. BASE_TOKEN .. "'",
			"the script must arrive on stdin through a heredoc")
		-- The old form was `sqlite3 'db' < '/tmp/….sql'`. A single `<` is the
		-- file redirection; `<<` is the heredoc, so only the spaced form is banned.
		assert_absent(cmd, " < ", "no input redirection from a file")
		assert_absent(cmd, ".sql'", "no temp script path in the command")
	end)

	helpers.it("quotes the heredoc token so the shell expands nothing", function()
		-- An UNQUOTED heredoc runs $( ) and backticks out of the body — and the
		-- body is, by construction, text the user typed.
		local sql = "INSERT INTO t VALUES ('$(touch /tmp/pwned)`id`');"
		local cmd = Cmd.build("/db/metrics.sqlite", sql)
		helpers.assert_contains(cmd, "<<'", "the token must be single-quoted")
		assert_absent(cmd, "<<" .. BASE_TOKEN, "an unquoted heredoc would expand the body")
		helpers.assert_contains(cmd, "$(touch /tmp/pwned)",
			"the payload must reach sqlite3 verbatim, inert rather than mangled")
	end)

	helpers.it("terminates the heredoc on its own final line", function()
		local cmd = Cmd.build("/db/metrics.sqlite", "SELECT 1;")
		helpers.assert_contains(cmd, "\nSELECT 1;\n" .. BASE_TOKEN .. "\n",
			"the terminator must sit alone on the line after the body")
	end)

	helpers.it("normalises however many trailing newlines the caller passed", function()
		local cmd = Cmd.build("/db/metrics.sqlite", "SELECT 1;\n\n\n")
		helpers.assert_contains(cmd, "\nSELECT 1;\n" .. BASE_TOKEN .. "\n",
			"extra blank lines must not push the terminator away from the body")
	end)
end)


helpers.describe("sqlite_command — a typed token cannot close the script", function()
	--- Extracts the token the builder actually chose for this script.
	local function token_of(cmd)
		return cmd:match("<<'([^']+)'")
	end

	helpers.it("extends the token when the body contains it mid-script", function()
		local cmd = Cmd.build("/db", "SELECT 1;\n" .. BASE_TOKEN .. "\nSELECT 2;")
		local token = token_of(cmd)
		helpers.assert_true(token ~= BASE_TOKEN,
			"a body line equal to the token would end the heredoc early")
		helpers.assert_contains(cmd, "\n" .. token .. "\n", "the extended token must terminate the body")
	end)

	helpers.it("extends the token when the body STARTS with it", function()
		local cmd = Cmd.build("/db", BASE_TOKEN .. "\nSELECT 1;")
		helpers.assert_true(token_of(cmd) ~= BASE_TOKEN, "the first line counts too")
	end)

	helpers.it("extends the token when the body ENDS with it and has no trailing newline", function()
		-- The scan must treat the unterminated last line as a line; an
		-- implementation splitting on "\n" alone silently misses this one.
		local cmd = Cmd.build("/db", "SELECT 1;\n" .. BASE_TOKEN)
		helpers.assert_true(token_of(cmd) ~= BASE_TOKEN, "the final unterminated line counts too")
	end)

	helpers.it("keeps extending while the extended token also collides", function()
		local sql = BASE_TOKEN .. "\n" .. BASE_TOKEN .. "_X\nSELECT 1;"
		local token = token_of(Cmd.build("/db", sql))
		helpers.assert_true(token ~= BASE_TOKEN and token ~= BASE_TOKEN .. "_X",
			"one round of extension is not enough when the extension collides too")
	end)

	helpers.it("chooses a token that is genuinely absent from the body", function()
		local sql = BASE_TOKEN .. "\n" .. BASE_TOKEN .. "_X\n" .. BASE_TOKEN .. "_X_X\nSELECT 1;"
		local cmd = Cmd.build("/db", sql)
		local token = token_of(cmd)
		local body = cmd:match("<<'[^']+'\n(.*)\n" .. token .. "\n$")
		helpers.assert_not_nil(body, "the command must end with the terminator on its own line")
		for line in (body .. "\n"):gmatch("([^\n]*)\n") do
			helpers.assert_true(line ~= token, "no body line may equal the chosen terminator")
		end
	end)

	helpers.it("does NOT extend for a near-miss that cannot terminate anything", function()
		-- `<<` strips nothing, so "TOKEN " and " TOKEN" are inert. Extending for
		-- them would mean the collision check fires on safe input, which hides
		-- real collisions in noise.
		for _, near_miss in ipairs({ BASE_TOKEN .. " ", " " .. BASE_TOKEN, BASE_TOKEN .. "X" }) do
			local cmd = Cmd.build("/db", "SELECT 1;\n" .. near_miss .. "\nSELECT 2;")
			helpers.assert_eq(cmd:match("<<'([^']+)'"), BASE_TOKEN,
				"a line that cannot terminate the heredoc must not extend the token")
		end
	end)
end)




-- =========================================
-- =========================================
-- ======= 3/ Arguments and Guards =========
-- =========================================
-- =========================================

helpers.describe("sqlite_command — arguments", function()
	helpers.it("quotes the database path", function()
		local cmd = Cmd.build("/db/it's here.sqlite", "SELECT 1;")
		helpers.assert_contains(cmd, "'/db/it'\\''s here.sqlite'",
			"the path must go through the shell_runner quoter")
	end)

	helpers.it("places flags before the database path", function()
		local cmd = Cmd.build("/db", "SELECT 1;", { flags = { "-json" } })
		helpers.assert_contains(cmd, "sqlite3 '-json' '/db'", "flags precede the positional argument")
	end)

	helpers.it("discards diagnostics by default and captures them on request", function()
		helpers.assert_contains(Cmd.build("/db", "SELECT 1;"), "2>/dev/null",
			"read paths signal failure with no rows")
		helpers.assert_contains(Cmd.build("/db", "SELECT 1;", { capture_stderr = true }), "2>&1",
			"write paths must be able to read the error back")
	end)

	helpers.it("refuses unusable arguments instead of composing a broken command", function()
		local cmd, reason = Cmd.build("", "SELECT 1;")
		helpers.assert_nil(cmd, "an empty db_path must not compose")
		helpers.assert_type(reason, "string", "the refusal must say why")
		helpers.assert_nil((Cmd.build("/db", "")), "an empty script must not compose")
		helpers.assert_nil((Cmd.build(nil, "SELECT 1;")), "a nil db_path must not compose")
	end)
end)


helpers.describe("sqlite_command — diagnostics carry no typed text", function()
	helpers.it("redacts the SQL fragment sqlite3 echoes back", function()
		local msg = Cmd.sanitise_error('Error: near line 1: near "my secret password": syntax error')
		assert_absent(msg, "my secret password", "the echoed token is user-typed text")
		helpers.assert_contains(msg, "syntax error", "the diagnostic itself must survive")
	end)

	helpers.it("collapses newlines and bounds the length", function()
		local msg = Cmd.sanitise_error("a\nb\nc" .. string.rep("x", 500))
		assert_absent(msg, "\n", "a log line stays one line")
		helpers.assert_true(#msg <= 200, "a runaway message must not flood the log")
	end)

	helpers.it("tolerates nil and empty input", function()
		helpers.assert_eq(Cmd.sanitise_error(nil), "", "nil must not raise")
		helpers.assert_eq(Cmd.sanitise_error(""), "", "empty must not raise")
	end)
end)




-- =========================================
-- =========================================
-- ======= 4/ No SQL Staged On Disk ========
-- =========================================
-- =========================================

helpers.describe("keylogger SQLite paths stage nothing on disk", function()
	local CALLERS = {
		"modules/keylogger/sqlite_writer.lua",
		"modules/keylogger/sqlite_reader.lua",
	}

	helpers.it("never reserves a temp name", function()
		for _, rel in ipairs(CALLERS) do
			assert_absent(code_of(rel), "os.tmpname",
				rel .. " must not reserve a temp name — the reservation never covered the file it opened")
		end
	end)

	helpers.it("never opens a file for writing", function()
		for _, rel in ipairs(CALLERS) do
			local code = code_of(rel)
			helpers.assert_true(
				code:match('io%.open%s*%([^)]*"w"') == nil,
				rel .. " must not open any file for writing — io.open creates 0666 & ~umask"
			)
		end
	end)

	helpers.it("names no world-writable directory", function()
		for _, rel in ipairs(CALLERS) do
			assert_absent(code_of(rel), "/tmp", rel .. " must not name a world-writable directory")
		end
	end)

	helpers.it("composes its commands through the shared builder", function()
		for _, rel in ipairs(CALLERS) do
			helpers.assert_contains(code_of(rel), "SqliteCommand.build",
				rel .. " must compose its sqlite3 invocation through the audited builder")
		end
	end)
end)
