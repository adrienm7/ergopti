--- _shared/lua/diagnostics/redact.lua

--- ==============================================================================
--- MODULE: Diagnostics Redaction (Shared Lua)
--- DESCRIPTION:
--- Removes what must not leave the machine from diagnostic text before it is
--- copied, saved or sent to a GitHub issue: token-like secrets (URL credentials
--- included), the home folder, the account name, other accounts' profile folders,
--- the folder and file names under the configuration directory and e-mail
--- addresses. The rules are data in
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
--- 5. Folder and file names chosen by the user (a hotstring pack, a profile
---    folder such as "John Smith" or "José") are masked whole: a name may hold
---    spaces when that makes it end at a separator, a quote or the line end.
---    Under the configuration directory only the names the product ships stay.
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

-- A byte of a folder or file name chosen by a person: the path bytes plus every
-- byte of a non-ASCII character, so "José" is one name, not "Jos" and a leak
local NAME_BYTE = "[A-Za-z0-9_%.%-\128-\255]"

-- The ellipsis a log appends to a shortened path ("config.toml…"): it ends a name
local ELLIPSIS = "\226\128\166"

-- What can follow a complete name: a path separator, a quote, a line break
local NAME_END_BYTE = "[\\/\"'\r\n]"

-- The bytes of an e-mail local part and of a domain
local EMAIL_LOCAL = "[A-Za-z0-9%._%%%+%-]"
local EMAIL_DOMAIN = "[A-Za-z0-9%.%-]"

-- The bytes of the credential in front of the @ of a URL
local URL_USERINFO = "[A-Za-z0-9%._~%%%+:=!%*%-]"

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
--- @param accept function(text, first, last) → replacement string or nil, then
---   optionally the last index it consumes and the earlier index it starts at
---   (never before the end of the previous replacement).
--- @return string
local function replace_occurrences(text, needle, case_insensitive, accept)
	local haystack = case_insensitive and text:lower() or text
	local target = case_insensitive and needle:lower() or needle
	local out = {}
	local pos = 1
	while true do
		local first, last = haystack:find(target, pos, true)
		if not first then break end
		local replacement, consumed_last, start = accept(text, first, last)
		if replacement then
			out[#out + 1] = text:sub(pos, math.max(pos, start or first) - 1)
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

--- Returns the index of the first byte of the run of `class` that ends at `from`.
--- @param text string
--- @param from number The run's last index.
--- @param class string
--- @return number The run's first index, from + 1 when the run is empty.
local function run_start(text, from, class)
	local i = from
	while byte_is(text, i, class) do i = i - 1 end
	return i + 1
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

--- Replaces the credential of a URL ("scheme://user:password@host"), keeping
--- the scheme and the host.
--- @param text string
--- @param rules table
--- @return string
local function redact_url_credentials(text, rules)
	return replace_occurrences(text, "://", false, function(source, _, last)
		local stop = run_end(source, last + 1, URL_USERINFO)
		if stop <= last or not byte_is(source, stop + 1, "@") then return nil end
		return "://" .. rules.secret_placeholder, stop
	end)
end

--- Replaces e-mail addresses: a local part, an @, and a dotted domain ending in
--- a top-level label of at least two letters.
--- @param text string
--- @param rules table
--- @return string
local function redact_emails(text, rules)
	return replace_occurrences(text, "@", false, function(source, first, last)
		local start = run_start(source, first - 1, EMAIL_LOCAL)
		if start == first then return nil end
		local stop = run_end(source, last + 1, EMAIL_DOMAIN)
		-- A trailing dot or dash is the sentence's, not the domain's
		while stop > last and byte_is(source, stop, "[%.%-]") do stop = stop - 1 end
		local domain = source:sub(last + 1, stop)
		local dot = domain:match("^.*()%.")
		if not dot or dot < 2 then return nil end
		if not domain:sub(dot + 1):match("^[A-Za-z][A-Za-z]+$") then return nil end
		return rules.email_placeholder, stop, start
	end)
end

--- Returns the index of the last byte of the name that starts at `from`: a run
--- of name bytes, extended over single spaces (at most max_words words) when
--- that makes the name end at a separator, a quote or the end of the line, so
--- "John Smith" is one folder but "jdoe and more" is the folder "jdoe".
--- @param source string
--- @param from number
--- @param max_words number The most words one name may hold.
--- @return number The name's last index, from - 1 when there is none.
local function name_end(source, from, max_words)
	local function word_end(start)
		local i = start
		while i <= #source and source:sub(i, i + 2) ~= ELLIPSIS and byte_is(source, i, NAME_BYTE) do
			i = i + 1
		end
		return i - 1
	end
	local first_end = word_end(from)
	if first_end < from then return first_end end
	local stop = first_end
	for _ = 1, max_words - 1 do
		if stop + 1 > #source or byte_is(source, stop + 1, NAME_END_BYTE) then return stop end
		if source:sub(stop + 1, stop + 1) ~= " " then break end
		local next_end = word_end(stop + 2)
		if next_end < stop + 2 then break end
		stop = next_end
	end
	if stop + 1 > #source or byte_is(source, stop + 1, NAME_END_BYTE) then return stop end
	return first_end
end

--- Replaces the profile folder of any other account (a Users folder on Windows,
--- /home/other, /Users/other) by the account placeholder, except the shared
--- profiles every machine has.
--- @param text string
--- @param rules table
--- @return string
local function redact_foreign_homes(text, rules)
	for _, marker in ipairs(rules.foreign_home_markers) do
		text = replace_occurrences(text, marker, true, function(source, first, last)
			local stop = name_end(source, last + 1, rules.path_name_max_words)
			if stop <= last then return nil end
			local name = source:sub(last + 1, stop):lower()
			for _, shared in ipairs(rules.shared_profile_names) do
				if shared == name then return nil end
			end
			return source:sub(first, last) .. rules.account_placeholder, stop
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

--- Masks the folder and file names under the configuration directory: the
--- directory becomes its placeholder, each name below it becomes the name
--- placeholder unless it is a name the product itself ships. Those names are
--- chosen by the user (a hotstring pack, a backup), so they identify a person.
--- @param text string
--- @param rules table
--- @param dir string|nil The configuration directory as the text spells it.
--- @param case_insensitive boolean
--- @return string
local function mask_config_dir(text, rules, dir, case_insensitive)
	if type(dir) ~= "string" then return text end
	local trimmed = dir:gsub("[/\\]+$", "")
	if trimmed == "" then return text end
	local known = {}
	for _, name in ipairs(rules.config_known_names) do known[name:lower()] = true end
	local spellings, seen = {}, {}
	for _, spelling in ipairs({ trimmed, (trimmed:gsub("\\", "/")), (trimmed:gsub("/", "\\")) }) do
		if not seen[spelling] then
			seen[spelling] = true
			spellings[#spellings + 1] = spelling
		end
	end
	for _, spelling in ipairs(spellings) do
		text = replace_occurrences(text, spelling, case_insensitive, function(source, first, last)
			if byte_is(source, last + 1, NAME_BYTE) then return nil end
			-- A path right after a quote ends at the closing quote, spaces included
			local quote = source:sub(first - 1, first - 1)
			if first == 1 or (quote ~= "'" and quote ~= "\"") then quote = nil end
			local out, i = { rules.config_placeholder }, last + 1
			while byte_is(source, i, "[\\/]") do
				local start = i + 1
				local stop
				if quote then
					stop = start - 1
					while stop + 1 <= #source and not byte_is(source, stop + 1, "[\\/\r\n]")
						and source:sub(stop + 1, stop + 1) ~= quote do
						stop = stop + 1
					end
				else
					stop = name_end(source, start, rules.path_name_max_words)
				end
				local name = source:sub(start, stop)
				if name == "" then
					out[#out + 1] = source:sub(i, i)
					i = start
				else
					local kept = known[name:lower()] and name or rules.config_name_placeholder
					out[#out + 1] = source:sub(i, i) .. kept
					i = stop + 1
				end
			end
			return table.concat(out), i - 1
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
--- @param context table { home = string|nil, user = string|nil, config_dir = string|nil,
---   case_insensitive = boolean } — the platform's home folder, account name,
---   configuration directory, and whether its paths compare case-insensitively.
--- @return string
function M.apply(text, rules, context)
	if type(text) ~= "string" then error("redact: text must be a string", 2) end
	if type(rules) ~= "table" then error("redact: rules must be the decoded redaction.json", 2) end
	if type(rules.path_name_max_words) ~= "number" or rules.path_name_max_words < 1
		or type(rules.config_placeholder) ~= "string" or type(rules.config_name_placeholder) ~= "string"
		or type(rules.config_known_names) ~= "table" then
		error("redact: the rules lack the path name and configuration directory settings", 2)
	end
	context = type(context) == "table" and context or {}
	local folded = context.case_insensitive == true
	text = redact_tokens(text, rules)
	text = redact_url_credentials(text, rules)
	text = redact_bearer(text, rules)
	text = redact_key_values(text, rules)
	-- The directory is searched as it is spelled, then as the home pass leaves it
	-- (a log written earlier already holds "~" for the home folder)
	text = mask_config_dir(text, rules, context.config_dir, folded)
	text = redact_home(text, rules, context.home, folded)
	if type(context.config_dir) == "string" then
		text = mask_config_dir(text, rules, redact_home(context.config_dir, rules, context.home, folded), folded)
	end
	text = redact_foreign_homes(text, rules)
	text = redact_emails(text, rules)
	text = redact_account(text, rules, context.user, folded)
	return text
end

return M
