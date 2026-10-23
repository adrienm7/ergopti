--- tests/support/sha256_vector_doubles.lua

--- ==============================================================================
--- MODULE: SHA-256 Vector Doubles
--- DESCRIPTION:
--- Loads the shared independent SHA-256 byte vectors and models the two native
--- boundaries a macOS digest can cross: hs.execute (popen(3) of /bin/sh) and
--- hs.hash (a length-carrying byte API).
---
--- FEATURES & RATIONALE:
--- 1. The vectors come from _shared/data/crypto/sha256_vectors.json, the corpus
---    the Linux suites also replay, so no digest is computed by the code under
---    test or by a second Lua implementation.
--- 2. The shell double keeps the C-string boundary: popen(3) receives a char *
---    and stops at the first NUL, and /bin/sh then parses only that prefix. An
---    unterminated single quote is a syntax error with empty stdout and status 2.
--- 3. The hash double receives the exact Lua string, as hs.hash does through
---    LuaSkin's length-aware conversion, and refuses bytes outside the corpus.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local M = {}

local file = assert(io.open(helpers.shared("data/crypto/sha256_vectors.json"), "rb"))
local rows = assert(json.decode(file:read("a")))
assert(file:close())
assert(#rows == 18, "the shared SHA-256 corpus must be complete")

local digest_by_input = {}
for _, row in ipairs(rows) do
	local bytes = row.input_hex:gsub("..", function(pair)
		return string.char(tonumber(pair, 16))
	end)
	row.input = string.rep(bytes, row["repeat"])
	digest_by_input[row.input] = row.sha256
end

--- Shared vectors with their decoded `input` bytes.
M.VECTORS = rows

--- Parses one POSIX shell word made of single-quoted runs and \' escapes.
--- @param word string Shell source of the word.
--- @return string|nil value Literal bytes, or nil on an unterminated quote.
local function parse_single_quoted_word(word)
	local value, index = {}, 1
	while index <= #word do
		local char = word:sub(index, index)
		if char == "'" then
			local closing = word:find("'", index + 1, true)
			if not closing then return nil end
			value[#value + 1] = word:sub(index + 1, closing - 1)
			index = closing + 1
		elseif char == "\\" then
			value[#value + 1] = word:sub(index + 1, index + 1)
			index = index + 2
		else
			return nil
		end
	end
	return table.concat(value)
end

--- Models hs.execute for the text digest pipeline `printf '%s' <word> | openssl dgst`.
--- @param observed table Receives every native command in `commands`.
--- @return function execute Same return shape as hs.execute.
function M.shell_execute(observed)
	observed.commands = observed.commands or {}
	return function(command)
		observed.commands[#observed.commands + 1] = command
		local c_string = command:match("^[^%z]*")
		local word = c_string:match("^printf '%%s' (.-) | openssl dgst %-sha256 %-hex 2>/dev/null$")
		if not word then return "", nil, "exit", 2 end
		local data = parse_single_quoted_word(word)
		if not data then return "", nil, "exit", 2 end
		local digest = digest_by_input[data]
		if not digest then error("digest double has no vector for the delivered bytes") end
		return "SHA2-256(stdin)= " .. digest .. "\n", true, "exit", 0
	end
end

--- Models hs.hash.new("SHA256") over the exact appended bytes.
--- @param observed table Receives the algorithms and appended payloads.
--- @return table hash Replacement for hs.hash.
function M.native_hash(observed)
	observed.algorithms = observed.algorithms or {}
	observed.payloads = observed.payloads or {}
	return {
		new = function(algorithm)
			observed.algorithms[#observed.algorithms + 1] = algorithm
			local parts = {}
			local context = {}
			function context:append(data)
				parts[#parts + 1] = data
				return self
			end
			function context:finish() return self end
			function context:value()
				local data = table.concat(parts)
				observed.payloads[#observed.payloads + 1] = data
				local digest = digest_by_input[data]
				if not digest then error("hash double has no vector for the appended bytes") end
				return digest
			end
			return context
		end,
	}
end

return M
