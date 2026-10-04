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

-- stdout is otherwise empty on the write path. The shell emits this terminal
-- receipt after sqlite3; LuaJIT's pclose result can conceal a nonzero exit.
local EXIT_STATUS_PREFIX = "ERGOPTI_SQL_EXIT_STATUS="





-- ==================================
-- ==================================
-- ======= 2/ Heredoc Framing =======
-- ==================================
-- ==================================

--- Returns a heredoc terminator that cannot appear as a line of `sql`.
--- The framing itself lives in adapters/shell_runner: feeding data on stdin is
--- not a SQLite concern, and a second copy of the collision rule is a second
--- place for it to be wrong.
--- @param sql string The script the terminator will delimit.
--- @return string A token guaranteed absent from `sql` on a line of its own.
function M.heredoc_token(sql)
	return Shell.heredoc_token(sql, HEREDOC_BASE_TOKEN)
end





-- ======================================
-- ======================================
-- ======= 3/ Command Composition =======
-- ======================================
-- ======================================

--- Composes the `sqlite3` invocation that reads `sql` from standard input.
--- @param db_path string Absolute path to the database file.
--- @param sql     string Complete SQL script; may contain arbitrary user text.
--- @param opts    table|nil { flags = string[]?, capture_stderr?, capture_exit? }.
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

	-- A personal .sqliterc is executable CLI setup: it can replace JSON mode,
	-- prepend output or run .shell before the owned script/receipt even starts.
	-- Select an empty init explicitly without changing the user's login home.
	local words = { "sqlite3", Shell.quote("-init"), Shell.quote("/dev/null") }
	-- Flags are literals chosen inside this repository, never caller data, but
	-- they go through the same quoter so no call site can smuggle one in later.
	for _, flag in ipairs(opts.flags or {}) do
		words[#words + 1] = Shell.quote(flag)
	end
	words[#words + 1] = Shell.quote(db_path)
	words[#words + 1] = opts.capture_stderr and STDERR_TO_STDOUT or STDERR_DISCARDED

	local command = Shell.with_stdin(table.concat(words, " "), sql, HEREDOC_BASE_TOKEN)
	if opts.capture_exit then
		-- Append to the existing command, without quoting the SQL a second time.
		-- Reusing exec_checked here amplified quote-heavy SQL beyond ARG_MAX and
		-- required a temporary output file on a path that stages no typed text.
		command = command .. "printf '\\n" .. EXIT_STATUS_PREFIX .. "%s\\n' \"$?\"\n"
	end
	-- Direct popen callers bypass Shell.exec's admission. libc shortens a NUL
	-- script before the shell sees it and can execute a durable SQL prefix even
	-- though the terminal receipt is lost. Reuse the native argv boundary before
	-- returning any executable command, without staging or re-quoting typed SQL.
	local refusal = Shell.validate_spawn_args("sh", { "-c", command })
	if refusal ~= "" then return nil, refusal end
	return command
end

--- Encodes content embedded inside a single-quoted SQLite value.
--- The CLI strips CRLF while reading script lines and libc cannot receive raw
--- NUL. SQL expressions preserve these bytes without a temporary data file or
--- changing the caller's value; ordinary quotes retain SQLite's doubled form.
--- @param value string Content between the caller's literal quotes.
--- @return string Escaped content with native control bytes expressed in SQL.
function M.escape_literal(value)
	return (value:gsub("'", "''"):gsub("\r", "'||char(13)||'"):gsub("%z", "'||char(0)||'"))
end

--- Decodes the terminal receipt of a capture_exit invocation.
--- @param output string|nil Complete captured stdout.
--- @return boolean accepted Whether sqlite3 exited successfully.
--- @return string diagnostics Output preceding the shell's terminal receipt.
--- @return string|nil error_message Missing or refused terminal status.
function M.read_exit_receipt(output)
	if type(output) ~= "string" then return false, "", "missing SQLite exit receipt" end
	local diagnostics, status = output:match("^(.*)\n" .. EXIT_STATUS_PREFIX .. "(%d+)\n$")
	status = tonumber(status)
	if not status or status > 255 then return false, "", "invalid SQLite exit receipt" end
	if status ~= 0 then return false, diagnostics, "SQLite CLI exited with status " .. status end
	return true, diagnostics, nil
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
