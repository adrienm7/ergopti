--- modules/keylogger/sqlite_command.lua

--- ==============================================================================
--- MODULE: SQLite Command Builder (Linux)
--- DESCRIPTION:
--- Composes the shell command that hands a SQL script to the `sqlite3` CLI, with
--- the script travelling on the child process's standard input instead of
--- through a file on disk.
---
--- WHY THIS MODULE EXISTS:
--- The keylogger's SQL embeds the literal characters the user typed. Both the
--- writer and the reader used to serialise that SQL to `os.tmpname() .. ".sql"`
--- inside the world-writable /tmp, which leaked it three separate ways:
---   1. `os.tmpname()` RESERVES a name, and the caller then opened a DIFFERENT
---      path (the reserved name with ".sql" appended). The kernel's
---      exclusive-create guarantee covered the reserved name, not the file
---      actually written — so a symlink planted at the predictable derived name
---      redirects the write to anywhere the daemon can write.
---   2. `io.open(path, "w")` creates with 0666 & ~umask. On a default umask that
---      is world-readable, so every local account could read the keystrokes.
---   3. The write-to-unlink window stays open for as long as sqlite3 runs, which
---      is ample time for any local process to copy the file.
--- Feeding the script on stdin removes the file, and with it all three.
---
--- FEATURES & RATIONALE:
--- 1. Quoted heredoc: `<<'TOKEN'` disables EVERY shell expansion inside the body,
---    so typed text reaches sqlite3 byte for byte. With an unquoted heredoc the
---    shell would expand `$(…)` and backticks out of the user's own keystrokes.
--- 2. Collision-proof token: a heredoc ends at the first line exactly equal to
---    its token. Typed text is arbitrary, so the token is extended until no line
---    of the script matches it — otherwise typing the token on a line of its own
---    would end the script early and hand the remainder to the shell as commands.
--- 3. Pure and inspectable: composing the command is kept separate from running
---    it because `io.popen` never RAISES on a malformed command, it EXECUTES it.
---    A test that only checked "nothing crashed" would pass with no quoting at
---    all; asserting on the composed string is the only way to test this at all.
--- 4. sanitise_error(): sqlite3 echoes the offending SQL token back in its
---    diagnostics, and for this caller that token can be a fragment of what the
---    user typed. The message is kept — silent failures are worse — but the
---    echoed payload is dropped before it reaches the log file.
--- ==============================================================================

local M = {}

local Shell = require("adapters.shell_runner")




-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

-- Opening token of the heredoc that carries the SQL. Extended on demand by
-- heredoc_token(); the base value is only the starting point.
local HEREDOC_BASE_TOKEN = "ERGOPTI_SQL"

-- Appended to the token until it no longer matches any line of the script. Any
-- non-empty string works; this one cannot occur in generated SQL by accident.
local HEREDOC_TOKEN_PADDING = "_X"

-- The single quote that makes the heredoc token literal. Without it the shell
-- expands the body, which is attacker-controlled text by construction.
local HEREDOC_QUOTE = "'"

-- Merge the CLI's diagnostics into stdout so the caller can read them back.
local STDERR_TO_STDOUT = "2>&1"

-- Drop diagnostics entirely; used by the read paths, which signal failure by
-- returning no rows.
local STDERR_DISCARDED = "2>/dev/null"

-- Replaces the SQL fragment sqlite3 quotes back at us in an error message.
local REDACTED_SQL_TOKEN = '"[redacted]"'

-- Upper bound on a logged diagnostic. Long enough to identify the failure,
-- short enough that a runaway message cannot flood the log.
local ERROR_LOG_MAX_CHARS = 200




-- ==================================
-- ==================================
-- ======= 2/ Heredoc Framing =======
-- ==================================
-- ==================================

--- Reports whether any line of `text` is exactly `token`.
--- Exactness matters: `<<` (unlike `<<-`) strips nothing, so only a line equal
--- to the token byte for byte terminates the heredoc. A line of "TOKEN " or
--- "TOKEN\r" does not, and must not be treated as a collision.
--- @param text  string Script body to scan.
--- @param token string Candidate terminator.
--- @return boolean True when the token would terminate the body early.
local function has_line_equal(text, token)
	-- The trailing newline makes the last line match the pattern like any other.
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		if line == token then return true end
	end
	return false
end

--- Returns a heredoc terminator that cannot appear as a line of `sql`.
--- @param sql string The script the terminator will delimit.
--- @return string A token guaranteed absent from `sql` on a line of its own.
function M.heredoc_token(sql)
	if type(sql) ~= "string" then return HEREDOC_BASE_TOKEN end
	local token = HEREDOC_BASE_TOKEN
	while has_line_equal(sql, token) do
		token = token .. HEREDOC_TOKEN_PADDING
	end
	return token
end




-- ======================================
-- ======================================
-- ======= 3/ Command Composition =======
-- ======================================
-- ======================================

--- Composes the `sqlite3` invocation that reads `sql` from standard input.
--- @param db_path string Absolute path to the database file.
--- @param sql     string Complete SQL script; may contain arbitrary user text.
--- @param opts    table|nil { flags = string[]?, capture_stderr = boolean? }.
--- @return string|nil The command, or nil when the arguments are unusable.
--- @return string|nil The reason, when the command could not be composed.
function M.build(db_path, sql, opts)
	if type(db_path) ~= "string" or db_path == "" then
		return nil, "db_path must be a non-empty string"
	end
	if type(sql) ~= "string" or sql == "" then
		return nil, "sql must be a non-empty string"
	end
	opts = opts or {}

	local words = { "sqlite3" }
	-- Flags are literals chosen inside this repository, never caller data, but
	-- they go through the same quoter so no call site can smuggle one in later.
	for _, flag in ipairs(opts.flags or {}) do
		words[#words + 1] = Shell.quote(flag)
	end
	words[#words + 1] = Shell.quote(db_path)
	words[#words + 1] = opts.capture_stderr and STDERR_TO_STDOUT or STDERR_DISCARDED

	local token = M.heredoc_token(sql)
	-- The terminator must sit on its own line, so the body is normalised to
	-- exactly one trailing newline rather than however many it arrived with.
	local body = (sql:gsub("\n+$", ""))

	return table.concat(words, " ")
		.. " <<" .. HEREDOC_QUOTE .. token .. HEREDOC_QUOTE .. "\n"
		.. body .. "\n"
		.. token .. "\n"
end




-- ==============================
-- ==============================
-- ======= 4/ Diagnostics =======
-- ==============================
-- ==============================

--- Makes a sqlite3 diagnostic safe to log.
--- sqlite3 reports syntax problems as `near "<token>": syntax error`, and for
--- the keylogger that token is a slice of what the user typed. Dropping the
--- quoted span keeps the diagnostic useful while keeping typed text out of the
--- log file.
--- @param text string|nil Raw CLI output.
--- @return string A single-line, bounded, payload-free message.
function M.sanitise_error(text)
	if type(text) ~= "string" or text == "" then return "" end
	local redacted = (text:gsub('"[^"]*"', REDACTED_SQL_TOKEN))
	return (redacted:gsub("%s+", " "):sub(1, ERROR_LOG_MAX_CHARS))
end

return M
