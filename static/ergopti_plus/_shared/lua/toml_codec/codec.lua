--- _shared/lua/toml_codec/codec.lua


--- ==============================================================================

-- Resolved here rather than assumed to be a global. LuaJIT has no utf8 table,
-- and a shared module cannot depend on its caller having installed the compat
-- shim — it does not know its callers. terminators.lua crashed from the E2E
-- runner for exactly that reason while working from the daemon and the unit
-- runner, both of which install one.
local RecordScanner = require("toml_codec.record_scanner")
local KeyPath = require("toml_codec.key_path")
local Bom = require("toml_codec.bom")
local BasicString = require("toml_codec.basic_string")
-- Integer subtype is an optional capability; LuaJIT leaves it absent.
local math_type = math.type
--- MODULE: TOML Codec (shared)
--- DESCRIPTION:
--- Generic TOML encoder + decoder for arbitrarily nested Lua tables.
--- Canonical source shared by all Lua-based drivers (Hammerspoon, future Linux
--- driver). Previously lived at hammerspoon/infra/toml_codec.lua; moved here so
--- both drivers share one implementation without duplication.
---
--- FEATURES & RATIONALE:
--- 1. Round-trip for the HS state shape: scalars (string, number,
---    boolean), arrays with independently typed values, maps (rendered as
---    ``[section]`` headers), and nested maps (rendered as
---    ``[parent.child]`` dotted-section headers). The state contains
---    section_states (depth 2), gesture_actions / shortcut_keys
---    (depth 1) and a handful of structured shortcut records — all
---    cleanly representable.
--- 2. Deterministic key ordering: keys within a section are sorted
---    alphabetically so a same-state save produces a stable diff. This
---    matters for git-tracked configs.
--- 3. Section-aware: sub-tables are emitted AFTER their parent's
---    scalars so the resulting TOML reads top-to-bottom in the way
---    a human expects.
--- 4. Lossless on common edge cases: empty maps render as a header
---    with no keys; arrays of strings preserve quoting; boolean false
---    stays distinct from nil (TOML simply omits absent keys, present
---    `false` is encoded as `false`).
---
--- LIMITATIONS:
--- - Ordinary sub-tables become their own [section]. Dictionary members
---   inside arrays use inline tables so their fields are not discarded.
--- - Default datetime decoding uses strings; optional source receipts retain
---   unchanged bare temporal tokens without adding date validation.
--- - Default float encoding uses Lua tostring; optional source receipts retain
---   unchanged numeric tokens and use a round-trip fallback for changed numbers.
--- ==============================================================================

local M = {}




-- =================================
-- =================================
-- ======= 1/ Encoder ==============
-- =================================
-- =================================

--- Returns true when `t` looks like a 1-based dense numeric array.
local function is_array_like(t)
	if type(t) ~= "table" then return false end
	local n = 0
	for k in pairs(t) do
		if type(k) ~= "number" then return false end
		n = n + 1
	end
	if n == 0 then return false end -- Empty table → treat as map
	for i = 1, n do
		if t[i] == nil then return false end
	end
	return true
end

--- Encode a string as a TOML basic string ("...") with escapes.
local function encode_string(s)
	return '"' .. BasicString.escape_body(s) .. '"'
end

--- Encode a key segment. Bare keys (alphanumeric + _ -) stay unquoted;
--- everything else (spaces, accents, punctuation) is quoted.
local function encode_key(k)
	local s = tostring(k)
	if s:match("^[A-Za-z0-9_%-]+$") then return s end
	return encode_string(s)
end

--- Forward decl so encode_value and encode_table can refer to each other.
local encode_value, encode_table

--- Ensures exactly `count` blank lines immediately before the next emitted line.
local function ensure_blank_lines(out, count)
	if count < 0 then count = 0 end
	local trailing = 0
	for i = #out, 1, -1 do
		if out[i] == "" then trailing = trailing + 1
		else break end
	end
	if trailing > count then
		for _ = 1, (trailing - count) do out[#out] = nil end
	elseif trailing < count then
		for _ = 1, (count - trailing) do out[#out + 1] = "" end
	end
end

encode_value = function(v, shapes, owner, key)
	local t = type(v)
	if t == "string" then
		local saved = shapes and shapes.strings and shapes.strings[owner]
		saved = saved and saved[key]
		if saved and saved.value == v then return saved.token end
		return encode_string(v)
	end
	if t == "boolean" then return tostring(v)      end
	if t == "number"  then
		local saved = shapes and shapes.numbers and shapes.numbers[owner]
		saved = saved and saved[key]
		if saved and ((saved.value == v and (v ~= 0 or 1 / saved.value == 1 / v))
			or (saved.value ~= saved.value and v ~= v))
			and (not math_type or math_type(saved.value) == math_type(v)) then
			return saved.token
		end
		if v ~= v then return "nan" end -- NaN
		if v ==  math.huge then return "+inf" end
		if v == -math.huge then return "-inf" end
		-- Zero equality hides its sign. Optional writes preserve floating zero
		-- before integer formatting; LuaJIT only has a decoded token or sign.
		if shapes and v == 0 and (1 / v == -math.huge
			or (math_type and math_type(v) == "float")
			or (not math_type and saved and saved.value == 0 and saved.token:find("[%.eE]"))) then
			return 1 / v == -math.huge and "-0.0" or "0.0"
		end
		-- Preserve integer-ness when possible; Lua 5.3+ has integer subtype
		if v == math.floor(v) and math.abs(v) < 1e15 then
			return string.format("%d", v)
		end
		if shapes then
			-- Optional source-shape writes must retain the decoded numeric value.
			-- LuaJIT tostring() can round a double; Lua 5.3+ integers stay exact.
			if math_type and math_type(v) == "integer" then return tostring(v) end
			local text = tostring(v)
			if tonumber(text) == v then return text end
			return string.format("%.17g", v)
		end
		return tostring(v)
	end
	if t == "table" then
		if (shapes and shapes.arrays[v]) or is_array_like(v) then
			if shapes and shapes.arrays[v] then
				local count = 0
				for key in pairs(v) do
					assert(type(key) == "number" and key >= 1 and key % 1 == 0,
						"TOML array receipt cannot discard named or invalid slots")
					count = count + 1
				end
				for index = 1, count do assert(v[index] ~= nil, "TOML array receipt requires dense slots") end
			end
			local parts = {}
			for index, item in ipairs(v) do
				parts[#parts + 1] = encode_value(item, shapes, v, index)
			end
			return "[" .. table.concat(parts, ", ") .. "]"
		end
		-- Array members cannot become sections: keep their dictionaries inline,
		-- including nested values, using the same escaping and ordering rules.
		local keys, parts = {}, {}
		for key in pairs(v) do keys[#keys + 1] = key end
		table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
		for _, key in ipairs(keys) do
			parts[#parts + 1] = encode_key(key) .. " = " .. encode_value(v[key], shapes, v, key)
		end
		return "{ " .. table.concat(parts, ", ") .. " }"
	end
	return '""'
end

--- Recursively walk a Lua table emitting TOML lines into `out`.
--- @param tbl   table  The table to encode at this level.
--- @param path  string The dotted-section path; "" for the root.
--- @param out   table  Mutable list of lines being built.
--- @param depth number Current nesting depth (0 = root).
encode_table = function(tbl, path, out, depth, shapes)
	-- Partition keys into scalars (and array values) vs sub-maps
	local scalars, submaps = {}, {}
	for k, v in pairs(tbl) do
		if type(v) == "table" and not (shapes and shapes.arrays[v]) and not is_array_like(v) then
			submaps[#submaps + 1] = k
		else
			scalars[#scalars + 1] = k
		end
	end
	-- Stable diff: sort by stringified key
	local function strkey(a, b) return tostring(a) < tostring(b) end
	table.sort(scalars, strkey)
	table.sort(submaps, strkey)

	-- Emit section header for non-root paths, even when there are no scalars:
	-- a present-but-empty section preserves the "this map exists, just empty"
	-- semantic of the source state
	if path ~= "" and (#scalars > 0 or #submaps == 0) then
		local header_spacing = (depth == 1) and 5 or 3
		ensure_blank_lines(out, header_spacing)
		out[#out + 1] = "[" .. path .. "]"
	end
	for _, k in ipairs(scalars) do
		out[#out + 1] = encode_key(k) .. " = " .. encode_value(tbl[k], shapes, tbl, k)
	end
	if #scalars > 0 then
		ensure_blank_lines(out, 1)
	end
	for _, k in ipairs(submaps) do
		local subpath = (path == "") and encode_key(k) or (path .. "." .. encode_key(k))
		encode_table(tbl[k], subpath, out, depth + 1, shapes)
	end
end

--- Encode a Lua table as a TOML string.
--- @param tbl table The root table.
--- @return string The serialised TOML body.
local function encode_document(tbl, shapes)
	if type(tbl) ~= "table" then return "" end
	local out = {
		"# Hammerspoon configuration — auto-generated. Hand-edits are",
		"# preserved across saves provided the file remains valid TOML.",
		"",
	}
	encode_table(tbl, "", out, 0, shapes)
	return table.concat(out, "\n")
end

--- Encodes with the unchanged default model and rendering rules.
--- @param tbl table Root table.
--- @return string document Default TOML body.
function M.encode(tbl)
	return encode_document(tbl)
end

--- Retains exact parsed array identities and unchanged scalar source tokens.
--- The root identity prevents a receipt from another source read from granting
--- publication authority. New and changed fields use the ordinary value model.
--- @param tbl table Exact root returned by decode_with_shapes().
--- @param shapes table Receipt belonging to that same document.
--- @return string document TOML body retaining source-owned value kinds.
function M.encode_with_shapes(tbl, shapes)
	assert(type(shapes) == "table" and type(shapes.arrays) == "table", "TOML encoding needs its shape receipt")
	assert(shapes.document == tbl, "TOML shape receipt belongs to another document")
	return encode_document(tbl, shapes)
end

--- Encode one value as the TOML literal a ``key = value`` line carries, with
--- the escaping and ordering rules of M.encode.
--- @param value any String, number, boolean, array or table.
--- @return string The TOML literal.
function M.encode_value(value)
	return encode_value(value)
end

--- Encodes a value retaining canonical array identities and unchanged scalar tokens.
--- Empty arrays have the same Lua model as empty maps; this explicit receipt
--- keeps them distinct without changing default encoding for existing callers.
--- @param value any Value from the document decoded with this receipt.
--- @param shapes table Canonical decode_with_shapes() receipt.
--- @param owner table|nil Exact parsed parent, for unchanged numeric source tokens.
--- @param key any|nil Field/index within owner.
--- @return string literal
function M.encode_value_with_shapes(value, shapes, owner, key)
	assert(type(shapes) == "table" and type(shapes.arrays) == "table", "TOML encoding needs its shape receipt")
	return encode_value(value, shapes, owner, key)
end




-- =================================
-- =================================
-- ======= 2/ Decoder ==============
-- =================================
-- =================================

local function trim(s) return (s:match("^%s*(.-)%s*$") or s) end

--- Split a dotted section path into its segments, honouring quoted segments
--- that may contain dots themselves. e.g.
---   `parent."with.dot".child` → { "parent", "with.dot", "child" }.
local function split_section_path(s)
	return KeyPath.parse(s)
end

-- Forward declarations — implementations follow in the section below.
-- coerce_value calls split_kv and parse_key for inline-table parsing.
local split_kv, parse_key

--- Resolve a dotted assignment relative to its current table. Values are closed;
--- only implicit table parents or this assignment owner's dotted parents extend.
--- @param target table Current semantic table.
--- @param segments table Decoded assignment identity.
--- @param dotted table Tables defined by dotted assignment prefixes.
--- @param sealed table Explicit value tables that cannot be extended.
--- @param declared table|nil Explicit document table definitions.
--- @param arrays table|nil Array-of-table containers.
--- @return table|nil owner, string|nil key Assignment cell, or refusal.
local function assignment_owner(target, segments, dotted, sealed, declared, arrays)
	for index = 1, #segments - 1 do
		local key = segments[index]
		local child = target[key]
		if child == nil then
			child = {}
			target[key] = child
		elseif type(child) ~= "table" or sealed[child]
			or (arrays and arrays[child])
			or (declared and declared[child] and not dotted[child]) then
			return nil
		end
		dotted[child] = true
		if declared then declared[child] = true end
		target = child
	end
	return target, segments[#segments]
end

-- Sentinel returned by coerce_value on parse failure; propagated to M.decode.
local PARSE_ERROR = {}

--- Removes comments only when they occur outside every TOML string form.
--- Newlines are preserved so multiline-string and array coercion retain their
--- record structure.
--- @param source string Complete value or physical line.
--- @return string uncommented
local function strip_comments(source)
	local out = {}
	local quote = nil
	local index = 1
	while index <= #source do
		local char = source:sub(index, index)
		local triple = source:sub(index, index + 2)
		if quote == '"""' or quote == "'''" then
			if quote == '"""' and char == "\\" then
				out[#out + 1] = source:sub(index, math.min(index + 1, #source))
				index = index + 2
			elseif triple == quote then
				local finish = RecordScanner.closing_quote_end(source, index)
				out[#out + 1] = source:sub(index, finish - 1)
				quote = nil
				index = finish
			else
				out[#out + 1] = char
				index = index + 1
			end
		elseif quote == '"' then
			out[#out + 1] = char
			if char == "\\" then
				if index < #source then out[#out + 1] = source:sub(index + 1, index + 1) end
				index = index + 2
			elseif char == '"' then
				quote = nil
				index = index + 1
			else
				index = index + 1
			end
		elseif quote == "'" then
			out[#out + 1] = char
			if char == "'" then quote = nil end
			index = index + 1
		elseif triple == '"""' or triple == "'''" then
			quote = triple
			out[#out + 1] = triple
			index = index + 3
		elseif char == '"' or char == "'" then
			quote = char
			out[#out + 1] = char
			index = index + 1
		elseif char == "#" then
			local newline = source:find("\n", index + 1, true)
			if not newline then break end
			out[#out + 1] = "\n"
			index = newline + 1
		else
			out[#out + 1] = char
			index = index + 1
		end
	end
	return table.concat(out)
end

--- Removes the comment of one physical line without treating quoted hashes as comments.
--- Continuation ownership stays with the caller's existing record scanner.
--- @param source string One physical TOML line.
--- @return string line The original non-comment bytes.
function M.strip_inline_comment(source)
	assert(type(source) == "string" and not source:find("\n", 1, true),
		"strip_inline_comment needs one physical TOML line")
	return strip_comments(source)
end

--- Splits a TOML array or inline-table body on top-level commas.
--- Both basic and literal strings, including their multiline forms, suppress
--- structural delimiters inside their content.
--- @param body string Container body without its outer brackets/braces.
--- @return table|nil fragments
local function split_top_level_commas(body)
	local fragments = {}
	local current = {}
	local quote = nil
	local depth = 0
	local index = 1
	while index <= #body do
		local char = body:sub(index, index)
		local triple = body:sub(index, index + 2)
		if quote == '"""' or quote == "'''" then
			if quote == '"""' and char == "\\" then
				current[#current + 1] = body:sub(index, math.min(index + 1, #body))
				index = index + 2
			elseif triple == quote then
				local finish = RecordScanner.closing_quote_end(body, index)
				current[#current + 1] = body:sub(index, finish - 1)
				quote = nil
				index = finish
			else
				current[#current + 1] = char
				index = index + 1
			end
		elseif quote == '"' then
			current[#current + 1] = char
			if char == "\\" then
				if index < #body then current[#current + 1] = body:sub(index + 1, index + 1) end
				index = index + 2
			elseif char == '"' then
				quote = nil
				index = index + 1
			else
				index = index + 1
			end
		elseif quote == "'" then
			current[#current + 1] = char
			if char == "'" then quote = nil end
			index = index + 1
		elseif triple == '"""' or triple == "'''" then
			quote = triple
			current[#current + 1] = triple
			index = index + 3
		elseif char == '"' or char == "'" then
			quote = char
			current[#current + 1] = char
			index = index + 1
		elseif char == "[" or char == "{" then
			depth = depth + 1
			current[#current + 1] = char
			index = index + 1
		elseif char == "]" or char == "}" then
			depth = depth - 1
			if depth < 0 then return nil end
			current[#current + 1] = char
			index = index + 1
		elseif char == "," and depth == 0 then
			fragments[#fragments + 1] = table.concat(current)
			current = {}
			index = index + 1
		else
			current[#current + 1] = char
			index = index + 1
		end
	end
	if quote ~= nil or depth ~= 0 then return nil end
	if #current > 0 then fragments[#fragments + 1] = table.concat(current) end
	return fragments
end

--- Extracts a multiline body only when its first lexical closure ends the token.
--- Validate source quotes before continuation removal can join content quotes.
local function multiline_body(raw)
	local delimiter = raw:sub(1, 3)
	local index = 4
	while index <= #raw do
		if delimiter == '"""' and raw:sub(index, index) == "\\" then
			index = index + 2
		elseif raw:sub(index, index + 2) == delimiter then
			local finish = RecordScanner.closing_quote_end(raw, index)
			if finish - index > 5 or finish ~= #raw + 1 then return nil end
			return raw:sub(4, finish - 4)
		else
			index = index + 1
		end
	end
	return nil
end

local function collapse_multiline_continuations(body)
	local out = {}
	local index = 1
	while index <= #body do
		if body:sub(index, index) == "\\" then
			local next_index = index + 1
			while body:sub(next_index, next_index):match("[ \t]") do
				next_index = next_index + 1
			end
			if body:sub(next_index, next_index) == "\n" then
				index = next_index + 1
				while index <= #body and body:sub(index, index):match("[ \t\n]") do
					index = index + 1
				end
			else
				-- Preserve each escape pair for the decoder; its second byte cannot
				-- independently introduce a continuation or a manufactured escape
				out[#out + 1] = body:sub(index, index + 1)
				index = index + 2
			end
		else
			out[#out + 1] = body:sub(index, index)
			index = index + 1
		end
	end
	return table.concat(out)
end

--- Return true only when every underscore separates two digits from the
--- supplied TOML digit alphabet. Validation precedes underscore removal so
--- malformed lookalikes cannot become valid merely by deleting separators.
local function valid_digit_run(raw, digit_pattern)
	if type(raw) ~= "string" or raw == "" then return false end
	local previous_was_digit = false
	for index = 1, #raw do
		local char = raw:sub(index, index)
		if char == "_" then
			if not previous_was_digit then return false end
			local next_char = raw:sub(index + 1, index + 1)
			if next_char == "" or not next_char:match(digit_pattern) then return false end
			previous_was_digit = false
		elseif char:match(digit_pattern) then
			previous_was_digit = true
		else
			return false
		end
	end
	return previous_was_digit
end

local function compact_number(raw)
	return (raw:gsub("_", ""))
end

local function valid_decimal_integer(raw)
	if not valid_digit_run(raw, "^[0-9]$") then return false end
	local compact = compact_number(raw)
	return #compact == 1 or compact:sub(1, 1) ~= "0"
end

--- Parse the TOML 1.0 numeric grammar implemented by this codec.
--- Returns value, true for a recognized numeric form and nil, false otherwise.
--- A recognized but unrepresentable value returns PARSE_ERROR, true so it can
--- never fall through and masquerade as a user string.
local function parse_number(raw)
	if raw == "inf" or raw == "+inf" then return math.huge, true end
	if raw == "-inf" then return -math.huge, true end
	if raw == "nan" or raw == "+nan" or raw == "-nan" then return 0 / 0, true end

	local prefix = raw:sub(1, 2)
	local base, digit_pattern
	if prefix == "0x" then
		base, digit_pattern = 16, "^[0-9A-Fa-f]$"
	elseif prefix == "0o" then
		base, digit_pattern = 8, "^[0-7]$"
	elseif prefix == "0b" then
		base, digit_pattern = 2, "^[01]$"
	end
	if base then
		local digits = raw:sub(3)
		if not valid_digit_run(digits, digit_pattern) then return nil, false end
		local value = tonumber(compact_number(digits), base)
		return value or PARSE_ERROR, true
	end

	local unsigned = raw
	local first = unsigned:sub(1, 1)
	if first == "+" or first == "-" then unsigned = unsigned:sub(2) end
	if unsigned == "" then return nil, false end

	local exponent_at = unsigned:find("[eE]")
	local mantissa = unsigned
	if exponent_at then
		if unsigned:find("[eE]", exponent_at + 1) then return nil, false end
		mantissa = unsigned:sub(1, exponent_at - 1)
		local exponent = unsigned:sub(exponent_at + 1)
		local exponent_sign = exponent:sub(1, 1)
		if exponent_sign == "+" or exponent_sign == "-" then exponent = exponent:sub(2) end
		if not valid_digit_run(exponent, "^[0-9]$") then return nil, false end
	end

	local dot_at = mantissa:find(".", 1, true)
	if dot_at then
		if mantissa:find(".", dot_at + 1, true) then return nil, false end
		local integer_part = mantissa:sub(1, dot_at - 1)
		local fractional_part = mantissa:sub(dot_at + 1)
		if not valid_decimal_integer(integer_part)
			or not valid_digit_run(fractional_part, "^[0-9]$") then
			return nil, false
		end
	elseif not valid_decimal_integer(mantissa) then
		return nil, false
	end

	local value = tonumber(compact_number(raw))
	return value or PARSE_ERROR, true
end

--- Coerce a raw RHS into a Lua value (string / boolean / number / array / inline-table).
--- Returns PARSE_ERROR on malformed input so M.decode can return nil.
local function coerce_value(raw, shapes, owner, key)
	raw = trim(strip_comments(raw))
	if raw == "" then return PARSE_ERROR end  -- Missing value (e.g., "key =")
	-- Booleans
	if raw == "true"  then return true  end
	if raw == "false" then return false end
	if raw:sub(1, 3) == "'''" then
		local body = multiline_body(raw)
		if body == nil then return PARSE_ERROR end
		if body:sub(1, 1) == "\n" then body = body:sub(2) end
		return body
	end
	if raw:sub(1, 3) == '"""' then
		local body = multiline_body(raw)
		if body == nil then return PARSE_ERROR end
		if body:sub(1, 1) == "\n" then body = body:sub(2) end
		body = collapse_multiline_continuations(body)
		local unescaped = BasicString.unescape_body(body, true)
		if unescaped == nil then return PARSE_ERROR end
		return unescaped
	end
	-- Single-quoted string — TOML literal strings are valid, but single-quoted
	-- strings that are unclosed (no matching closing apostrophe) are an error.
	if raw:sub(1, 1) == "'" then
		if raw:sub(-1) ~= "'" or #raw < 2 then return PARSE_ERROR end
		-- Literal string — no escape processing, just return the body
		local body = raw:sub(2, -2)
		if body:find("'", 1, true) then return PARSE_ERROR end
		return body
	end
	-- Double-quoted string — require both opening and closing quote on the same value
	if raw:sub(1, 1) == '"' then
		if raw:sub(-1) ~= '"' or #raw < 2 then return PARSE_ERROR end  -- Unclosed string
		local body = raw:sub(2, -2)
		local unescaped = BasicString.unescape_body(body)
		if unescaped == nil then return PARSE_ERROR end
		return unescaped
	end
	-- Inline table: { key = val, … } — reject trailing comma before closing brace
	if raw:sub(1, 1) == "{" then
		if raw:sub(-1) ~= "}" then return PARSE_ERROR end
		-- Reject trailing comma: `,` followed only by optional whitespace then `}`
		if raw:match(",%s*}$") then return PARSE_ERROR end
		-- Parse the inline table's key-value pairs
		local body = trim(raw:sub(2, -2))
		local tbl = {}
		local dotted, sealed = {}, {}
		if body == "" then return tbl end
		-- `depth` tracks nested [ ] and { } so a comma INSIDE a nested value does
		-- not split the pair list. Without it, { key = "Left", mods = ["ctrl",
		-- "super"] } split into three fragments — `key = "Left"`, `mods = ["ctrl"`
		-- and `"super"]` — the last two of which have no `=`, so split_kv failed
		-- and decode returned nil for the WHOLE document with no error message.
		-- A single-element nested array worked, which is what made it look fine.
		--
		-- Same shape as the logger sub-files bug: a scanner that tracks quotes but
		-- not nesting. Quotes alone are not enough whenever the delimiter being
		-- searched for can also appear one level down.
		local pairs_raw = split_top_level_commas(body)
		if not pairs_raw then return PARSE_ERROR end
		for _, pair in ipairs(pairs_raw) do
			local k, v_raw = split_kv(trim(pair))
			if not k or k=="" then return PARSE_ERROR end
			local segments = parse_key(k)
			if segments == nil then return PARSE_ERROR end
			local owner, key = assignment_owner(tbl, segments, dotted, sealed)
			if not owner or owner[key] ~= nil then return PARSE_ERROR end
			local v = coerce_value(v_raw or "", shapes, owner, key)
			if v == PARSE_ERROR then return PARSE_ERROR end
			owner[key] = v
			if type(v) == "table" then sealed[v] = true end
		end
		return tbl
	end
	-- Array — split on commas at depth 0, ignoring quoted regions
	if raw:sub(1, 1) == "[" then
		if raw:sub(-1) ~= "]" then return PARSE_ERROR end
		local body = trim(raw:sub(2, -2))
		local out = {}
		if shapes then shapes.arrays[out] = true end
		if body == "" then return out end
		local elements = split_top_level_commas(body)
		if not elements then return PARSE_ERROR end
		for _, element in ipairs(elements) do
			local final = trim(element)
			if final == "" then return PARSE_ERROR end
			out[#out + 1] = coerce_value(final, shapes, out, #out + 1)
		end
		-- Propagate any element-level parse errors
		for _, v in ipairs(out) do
			if v == PARSE_ERROR then return PARSE_ERROR end
		end
		return out
	end
	-- Numbers — including TOML 1.0 special float literals
	local number, is_number = parse_number(raw)
	if is_number then
		if shapes and number ~= PARSE_ERROR and owner then
			local fields = shapes.numbers[owner] or {}
			shapes.numbers[owner] = fields
			fields[key] = { value = number, token = raw }
		end
		return number
	end
	-- The existing bare fallback also carries TOML temporal literals as strings.
	-- Optional source evidence preserves their unchanged spelling without adding
	-- a second parser or changing this decoder's existing admission semantics.
	if shapes and owner then
		local fields = shapes.strings[owner] or {}
		shapes.strings[owner] = fields
		fields[key] = { value = raw, token = raw }
	end
	-- Bare key fallback — treat as string
	return raw
end

--- Parse a single key=value line, splitting on the FIRST '=' that is not
--- inside a quoted region. Returns the trimmed key/value and original RHS,
--- preserving string-owned whitespace for a pending multiline value.
split_kv = RecordScanner.split_assignment

--- Parse assignment segments with the same quoted identity as table headers.
parse_key = function(raw)
	return KeyPath.parse(raw)
end

--- Advance the array-bracket nesting depth across a line fragment, honouring
--- double-quoted strings so a '[' or ']' inside a string does not count. The
--- state is threaded across the lines of a multi-line array so decode() knows
--- when the array finally closes.
--- @param s string The fragment to scan.
--- @param depth number Bracket depth on entry.
--- @param in_str boolean Whether we start inside a double-quoted string.
--- @param escape boolean Whether the previous char was a backslash escape.
--- @return number, boolean, boolean The depth, in_str and escape state on exit.
local function scan_bracket_depth(s, depth, multiline_quote)
	return RecordScanner.advance(s, depth, multiline_quote)
end

--- Decode a TOML body into a nested Lua table.
--- Returns nil on any spec violation (duplicate keys, invalid syntax, etc.).
--- @param content string The TOML source.
--- @return table|nil The decoded root table, or nil on error.
local function decode_document(content, shapes)
	local root = {}
	local current = root
	-- Track which keys have been set in each table to detect duplicates
	local seen_keys = { [root] = {} }
	-- TOML definition ownership belongs to the actual table object, not its text
	-- path. An array-of-tables creates a fresh owner generation on every header,
	-- so a child path may be declared once in each generation.
	local declared_tables = {}
	local dotted_tables = {}
	local aot_arrays = {}
	local sealed_values = {}

	local function mark_sealed_value(value)
		if type(value) ~= "table" or sealed_values[value] then return end
		sealed_values[value] = true
		for _, child in pairs(value) do
			mark_sealed_value(child)
		end
	end

	-- Resolve an intermediate table path. When an intermediate segment names an
	-- array of tables, TOML attaches descendants to its latest element.
	local function resolve_container(segments, limit)
		local target = root
		for index = 1, limit do
			if type(target) ~= "table"
				or aot_arrays[target]
				or sealed_values[target] then
				return nil
			end

			local next_value = target[segments[index]]
			if next_value == nil then
				next_value = {}
				target[segments[index]] = next_value
			elseif type(next_value) ~= "table" or sealed_values[next_value] then
				return nil
			end

			if aot_arrays[next_value] then
				next_value = next_value[#next_value]
				if type(next_value) ~= "table" then return nil end
			end
			target = next_value
		end
		return target
	end

	local function claim_value(target, key, value)
		if key == nil or target[key] ~= nil then return false end
		local sk = seen_keys[target]
		if not sk then
			sk = {}
			seen_keys[target] = sk
		end
		if sk[key] then return false end
		sk[key] = true
		target[key] = value
		mark_sealed_value(value)
		return true
	end
	-- Active multi-line array accumulator (nil when not inside one). TOML permits
	-- an array value to span several lines; the decoder collects the fragments
	-- until the brackets balance, then coerces the joined text as one array.
	local pending = nil
	if type(content) ~= "string" or content == "" then return root end
	content = Bom.strip_prefix(content)
	for line in (content .. "\n"):gmatch("([^\r\n]*)\r?\n") do
		local trimmed = trim(strip_comments(line))

		if pending then
			-- Preserve physical newlines until the complete value settles. A line
			-- resembling `[section]` is data while either a container or triple
			-- quoted string remains open.
			pending.parts[#pending.parts + 1] = line
			pending.depth, pending.multiline_quote =
				scan_bracket_depth(line, pending.depth, pending.multiline_quote)
			if pending.depth == 0 and pending.multiline_quote == nil then
				local v = coerce_value(table.concat(pending.parts, "\n"), shapes, pending.target, pending.key)
				if v == PARSE_ERROR then return nil end
				if not claim_value(pending.target, pending.key, v) then return nil end
				pending = nil
			end
			goto continue_decode
		end

		if trimmed == "" or trimmed:sub(1, 1) == "#" then
			-- Comment / blank — skip

		elseif trimmed:sub(1, 1) == "[" and trimmed:sub(-1) ~= "]" then
			-- Line starts with '[' but does not close with ']' — malformed header
			return nil

		elseif trimmed:sub(1, 1) == "[" and trimmed:sub(-1) == "]" then
			-- Section header — validate it
			-- Detect array-of-tables header: [[name]]
			local aot_path = trimmed:match("^%[%[(.-)%]%]$")
			if aot_path ~= nil then
				-- [[]] with empty name is invalid per the TOML spec
				aot_path = trim(aot_path)
				if aot_path == "" then return nil end
				-- Array-of-tables: append a new owner under the latest parent element.
				local segments = split_section_path(aot_path)
				if not segments or #segments == 0 then return nil end
				local parent = resolve_container(segments, #segments - 1)
				if not parent then return nil end
				local last = segments[#segments]
				local arr = parent[last]
				if arr == nil then
					arr = {}
					parent[last] = arr
					aot_arrays[arr] = true
					if shapes then shapes.arrays[arr] = true end
				elseif type(arr) ~= "table" or not aot_arrays[arr] then
					return nil
				end
				local new_tbl = {}
				arr[#arr + 1] = new_tbl
				current = new_tbl
				seen_keys[current] = {}
				goto continue_decode
			end
			local path = trim(trimmed:sub(2, -2))
			-- Empty section name → error
			if path == "" then return nil end
			local segments = split_section_path(path)
			if not segments or #segments == 0 then return nil end
			local parent = resolve_container(segments, #segments - 1)
			if not parent then return nil end
			local last = segments[#segments]
			current = parent[last]
			if current == nil then
				current = {}
				parent[last] = current
			elseif type(current) ~= "table"
				or aot_arrays[current]
				or sealed_values[current] then
				return nil
			end
			if declared_tables[current] then return nil end
			declared_tables[current] = true
			if not seen_keys[current] then seen_keys[current] = {} end

		else
			-- Key-value line: strip any inline comment first, honouring both
			-- double- and single-quoted regions so a literal string like
			-- key = 'hello # world' is not truncated at the '#'.
			local key, raw, original_rhs = split_kv(strip_comments(line))
			-- Line with no '=' (e.g., multi-line string continuation) — skip
			if not key then goto continue_decode end
			-- Value with no key: line starts with '=' (key is empty string)
			if trim(key) == "" then return nil end
			-- Key with no value (raw is nil or empty after trimming)
			local raw_trimmed = raw and trim(raw) or ""
			if raw_trimmed == "" then return nil end
			local segments = parse_key(key)
			if segments == nil then return nil end
			local target, parsed_key = assignment_owner(current, segments, dotted_tables,
				sealed_values, declared_tables, aot_arrays)
			if not target then return nil end
			-- Arrays and multiline strings share one exact record boundary. Defer
			-- coercion until neither a container nor a triple quote remains open.
			local depth, multiline_quote = scan_bracket_depth(raw_trimmed, 0, nil)
			if multiline_quote ~= nil or (raw_trimmed:sub(1, 1) == "[" and depth > 0) then
				pending = {
					key = parsed_key,
					target = target,
					parts = { multiline_quote ~= nil and original_rhs or raw_trimmed },
					depth = depth,
					multiline_quote = multiline_quote,
				}
				goto continue_decode
			end
			local v = coerce_value(raw_trimmed, shapes, target, parsed_key)
			-- Propagate parse errors from coerce_value
			if v == PARSE_ERROR then return nil end
			if not claim_value(target, parsed_key, v) then return nil end
		end
		::continue_decode::
	end
	-- A multi-line array that never closes is malformed TOML.
	if pending then return nil end
	return root
end


--- Decodes a document with the established untagged Lua value model.
--- @param content string TOML source.
--- @return table|nil document
function M.decode(content)
	return decode_document(content)
end

--- Decodes exact source and retains parsed array identities and numeric tokens.
--- The receipt refers to this returned document only, including empty/nested
--- arrays and arrays of tables. Failed decoding exposes neither document nor
--- partial evidence; no metatable or model mutation reaches existing callers.
--- @param content string TOML source.
--- @return table|nil document
--- @return table|nil shapes Source-bound arrays and unchanged scalar tokens.
function M.decode_with_shapes(content)
	local shapes = { arrays = {}, numbers = {}, strings = {} }
	local document = decode_document(content, shapes)
	if not document then return nil, nil end
	shapes.document = document
	return document, shapes
end

return M
