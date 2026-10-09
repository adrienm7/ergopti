--- _shared/lua/diagnostics/redact.lua

--- ==============================================================================
--- MODULE: Diagnostics Redaction (Shared Lua)
--- DESCRIPTION:
--- Removes what must not leave the machine from diagnostic text before it is
--- copied, saved or sent to a GitHub issue: token-like secrets, the home
--- folder and the account name. The rules are data in
--- _shared/modules/diagnostics/redaction.json; the AHK port
--- (windows/infra/redact.ahk) replays the same vectors
--- (_shared/tests/corpus/diagnostics/redaction_vectors.json).
---
--- FEATURES & RATIONALE:
--- 1. Secrets first, so a token that happens to contain the account name is
---    removed whole rather than half-rewritten.
--- 2. The home folder in every spelling a log can hold (both slash styles),
---    case-insensitively where the file system is (Windows), and only as a
---    whole path: /Users/jdoe2 is not /Users/jdoe.
--- 3. The account name only as a whole word of a minimum length: a one-letter
---    account name replaced everywhere would shred the report.
--- 4. Case folding is ASCII-only in every port, so the three agree.
--- ==============================================================================

local M = {}





-- ====================================
-- ====================================
-- ======= 1/ Character Classes =======
-- ====================================
-- ====================================

-- The charsets redaction.json may name, as Lua pattern classes of one byte
local CHARSETS = {
	alnum     = "[A-Za-z0-9]",
	word      = "[A-Za-z0-9_]",
	word_dash = "[A-Za-z0-9_%-]",
}

-- A byte that continues an identifier: a match next to one is part of a longer
-- word and is left alone
local WORD_BYTE = "[A-Za-z0-9_]"

-- A byte that continues a path segment after the home folder
local PATH_BYTE = "[A-Za-z0-9_%.%-]"

-- The characters a bearer token is made of
local BEARER_BYTE = "[A-Za-z0-9%._~%+/=%-]"

-- The bytes that end an unquoted key=value secret
local VALUE_STOP = "[%s\"',;%)}&]"

--- True when the byte at `index` exists and matches the class.
--- @param text string
--- @param index number
--- @param class string Lua pattern class of one byte.
--- @return boolean
local function byte_is(text, index, class)
	if index < 1 or index > #text then return false end
	return text:sub(index, index):match(class) ~= nil
end

--- Counts the code points of a UTF-8 string (continuation bytes excluded).
--- @param text string
--- @return number
local function code_point_count(text)
	local count = 0
	for i = 1, #text do
		local b = text:byte(i)
		if b < 0x80 or b > 0xBF then count = count + 1 end
	end
	return count
end





-- ======================================
-- ======================================
-- ======= 2/ Generic Replacement =======
-- ======================================
-- ======================================

--- Replaces every accepted occurrence of `needle`, scanning left to right.
--- @param text string
--- @param needle string Non-empty literal.
--- @param case_insensitive boolean ASCII-only folding.
--- @param accept function(text, first, last) → replacement string or nil.
--- @return string
local function replace_occurrences(text, needle, case_insensitive, accept)
	local haystack = case_insensitive and text:lower() or text
	local target = case_insensitive and needle:lower() or needle
	local out = {}
	local pos = 1
	while true do
		local first, last = haystack:find(target, pos, true)
		if not first then break end
		local replacement, consumed_last = accept(text, first, last)
		if replacement then
			out[#out + 1] = text:sub(pos, first - 1)
			out[#out + 1] = replacement
			pos = (consumed_last or last) + 1
		else
			out[#out + 1] = text:sub(pos, first)
			pos = first + 1
		end
	end
	out[#out + 1] = text:sub(pos)
	return table.concat(out)
end

--- Returns the index of the last byte of the run of `class` starting at `from`.
--- @param text string
--- @param from number
--- @param class string
--- @return number The run's last index, from - 1 when the run is empty.
local function run_end(text, from, class)
	local i = from
	while byte_is(text, i, class) do i = i + 1 end
	return i - 1
end





-- ============================
-- ============================
-- ======= 3/ The Rules =======
-- ============================
-- ============================

--- Replaces token-like secrets (prefix + a long run of its charset).
--- @param text string
--- @param rules table Decoded redaction.json.
--- @return string
local function redact_tokens(text, rules)
	for _, token in ipairs(rules.token_prefixes) do
		local class = CHARSETS[token.charset]
		if not class then error("redact: unknown charset " .. tostring(token.charset), 3) end
		text = replace_occurrences(text, token.prefix, false, function(source, first, last)
			if byte_is(source, first - 1, WORD_BYTE) then return nil end
			local stop = run_end(source, last + 1, class)
			if stop - last < token.min_length then return nil end
			return rules.secret_placeholder, stop
		end)
	end
	return text
end

--- Replaces the credential of an "Authorization: Bearer <token>" value.
--- @param text string
--- @param rules table
--- @return string
local function redact_bearer(text, rules)
	return replace_occurrences(text, "bearer", true, function(source, first, last)
		if byte_is(source, first - 1, WORD_BYTE) then return nil end
		local spaces = run_end(source, last + 1, "[ \t]")
		if spaces == last then return nil end
		local stop = run_end(source, spaces + 1, BEARER_BYTE)
		if stop - spaces < rules.bearer_min_length then return nil end
		return source:sub(first, spaces) .. rules.secret_placeholder, stop
	end)
end

--- Replaces the value of a key=value or "key": "value" secret, keeping the key.
--- @param text string
--- @param rules table
--- @return string
local function redact_key_values(text, rules)
	for _, key in ipairs(rules.secret_keys) do
		text = replace_occurrences(text, key, true, function(source, first, last)
			if byte_is(source, first - 1, WORD_BYTE) or byte_is(source, last + 1, WORD_BYTE) then
				return nil
			end
			local i = last + 1
			if byte_is(source, i, "[\"']") then i = i + 1 end
			i = run_end(source, i, "[ \t]") + 1
			if not byte_is(source, i, "[=:]") then return nil end
			i = run_end(source, i + 1, "[ \t]") + 1
			if byte_is(source, i, "[\"']") then i = i + 1 end
			local stop = i
			while stop <= #source and not byte_is(source, stop, VALUE_STOP) do stop = stop + 1 end
			stop = stop - 1
			if code_point_count(source:sub(i, stop)) < rules.secret_value_min_length then return nil end
			return source:sub(first, i - 1) .. rules.secret_placeholder, stop
		end)
	end
	return text
end

--- Replaces the home folder, in both slash styles, by its placeholder.
--- @param text string
--- @param rules table
--- @param home string|nil
--- @param case_insensitive boolean
--- @return string
local function redact_home(text, rules, home, case_insensitive)
	if type(home) ~= "string" then return text end
	local trimmed = home:gsub("[/\\]+$", "")
	if trimmed == "" then return text end
	local spellings, seen = {}, {}
	for _, spelling in ipairs({ trimmed, (trimmed:gsub("\\", "/")), (trimmed:gsub("/", "\\")) }) do
		if not seen[spelling] then
			seen[spelling] = true
			spellings[#spellings + 1] = spelling
		end
	end
	for _, spelling in ipairs(spellings) do
		text = replace_occurrences(text, spelling, case_insensitive, function(source, _, last)
			if byte_is(source, last + 1, PATH_BYTE) then return nil end
			return rules.home_placeholder
		end)
	end
	return text
end

--- Replaces the account name, as a whole word, by its placeholder.
--- @param text string
--- @param rules table
--- @param user string|nil
--- @param case_insensitive boolean
--- @return string
local function redact_account(text, rules, user, case_insensitive)
	if type(user) ~= "string" or code_point_count(user) < rules.min_account_name_length then
		return text
	end
	return replace_occurrences(text, user, case_insensitive, function(source, first, last)
		if byte_is(source, first - 1, WORD_BYTE) or byte_is(source, last + 1, WORD_BYTE) then
			return nil
		end
		return rules.account_placeholder
	end)
end





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

--- Redacts diagnostic text before it leaves the machine.
--- @param text string
--- @param rules table Decoded _shared/modules/diagnostics/redaction.json.
--- @param context table { home = string|nil, user = string|nil,
---   case_insensitive = boolean } — the platform's home folder, account name,
---   and whether its paths compare case-insensitively.
--- @return string
function M.apply(text, rules, context)
	if type(text) ~= "string" then error("redact: text must be a string", 2) end
	if type(rules) ~= "table" then error("redact: rules must be the decoded redaction.json", 2) end
	context = type(context) == "table" and context or {}
	local folded = context.case_insensitive == true
	text = redact_tokens(text, rules)
	text = redact_bearer(text, rules)
	text = redact_key_values(text, rules)
	text = redact_home(text, rules, context.home, folded)
	text = redact_account(text, rules, context.user, folded)
	return text
end

return M
