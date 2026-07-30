--- _shared/lua/shell/heredoc.lua

--- ==============================================================================
--- MODULE: Standard-Input Heredoc Framing (shared)
--- DESCRIPTION:
--- The one implementation of "hand this payload to a command on its standard
--- input", used by every driver that shells out with data the user typed.
---
--- WHY IT MATTERS:
--- The two other ways of passing data to a subprocess both leak it. A temporary
--- file puts it on disk, where a symlink can redirect the write and any local
--- account can read it. A command-line argument puts it in the process table,
--- which every local account can read with `ps`. Standard input does neither.
---
--- FEATURES & RATIONALE:
--- 1. Quoted heredoc (`<<'TOKEN'`). The shell performs NO expansion inside the
---    body, so `$( )` and backticks in the payload stay inert — and the payload
---    is, by construction, arbitrary text the user typed.
--- 2. Collision-proof terminator. A heredoc ends at the first line exactly equal
---    to its token, so a payload containing the token on a line of its own would
---    close the document early and hand the remainder to the shell as commands.
---    The token is extended until no line collides. This rule lives here, once:
---    a second copy is a second place for it to be subtly wrong.
--- 3. Exactness in both directions. `<<` (unlike `<<-`) strips nothing, so only a
---    byte-for-byte equal line terminates. "TOKEN " and " TOKEN" are inert and
---    must NOT extend the token — firing on safe input would bury real
---    collisions in noise.
--- ==============================================================================

local M = {}




-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

--- Default opening terminator. Callers with their own convention pass a base.
M.DEFAULT_TOKEN = "ERGOPTI_STDIN"

--- Appended to the terminator until it no longer matches any line of the body.
M.TOKEN_PADDING = "_X"

--- Filter that restores byte-exactness, used by with_exact_stdin().
--- A heredoc ALWAYS delivers its body followed by one newline — the shell has no
--- syntax for a heredoc that ends without one — so with_stdin() has to normalise
--- the payload's own trailing newlines away, and the command then reads a byte
--- string that is not what the caller passed. Truncating the stream back to the
--- payload's real byte length undoes both halves of that: nothing is added, and
--- nothing is removed.
M.TRUNCATE_COMMAND = "head -c"




-- ==========================
-- ==========================
-- ======= 2/ Framing =======
-- ==========================
-- ==========================

--- Reports whether any line of `text` is exactly `token`.
--- @param text  string
--- @param token string
--- @return boolean
local function has_line_equal(text, token)
	-- The trailing newline makes the last line match the pattern like any other;
	-- without it an unterminated final line is silently never scanned.
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		if line == token then return true end
	end
	return false
end

--- Returns a terminator that cannot appear as a line of `text`.
--- @param text string      Payload the terminator will delimit.
--- @param base string|nil  Starting token; defaults to DEFAULT_TOKEN.
--- @return string
function M.token(text, base)
	local token = (type(base) == "string" and base ~= "") and base or M.DEFAULT_TOKEN
	if type(text) ~= "string" then return token end
	while has_line_equal(text, token) do
		token = token .. M.TOKEN_PADDING
	end
	return token
end

--- Appends a quoted heredoc carrying `input` to an already-composed command.
--- @param cmd        string     Fully composed command.
--- @param input      string     Payload for the command's standard input.
--- @param token_base string|nil Starting terminator token.
--- @return string The command with its heredoc attached.
function M.with_stdin(cmd, input, token_base)
	local payload = (type(input) == "string") and input or ""
	local token   = M.token(payload, token_base)
	-- The terminator must sit on its own line, so the body is normalised to
	-- exactly one trailing newline rather than however many it arrived with.
	local body = (payload:gsub("\n+$", ""))
	return cmd .. " <<'" .. token .. "'\n" .. body .. "\n" .. token .. "\n"
end

--- Appends a heredoc carrying EXACTLY the bytes of `input`, trailing newlines
--- included.
--- Use this whenever the payload is DATA rather than a script. A SQL script does
--- not care how many newlines it ends with, but a value being encrypted does:
--- with_stdin() would hand openssl a plaintext the caller never wrote, and the
--- stored ciphertext would then decrypt to something different from the original
--- — silent corruption that only surfaces the day the value is read back.
--- @param cmd        string     Fully composed command; it reads standard input.
--- @param input      string     Payload for the command's standard input.
--- @param token_base string|nil Starting terminator token.
--- @return string The command, wrapped so it receives `input` byte for byte.
function M.with_exact_stdin(cmd, input, token_base)
	local payload = (type(input) == "string") and input or ""
	local token   = M.token(payload, token_base)
	-- The truncation READS the heredoc and pipes the result on, so it has to come
	-- first: a redirection binds to the command it follows, and the body of a
	-- heredoc starts on the line after the whole pipeline. The payload is written
	-- unchanged — the truncation, not a gsub, is what removes the framing newline.
	return M.TRUNCATE_COMMAND .. " " .. #payload .. " <<'" .. token .. "' | " .. cmd
		.. "\n" .. payload .. "\n" .. token .. "\n"
end

return M
