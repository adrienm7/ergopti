--- _shared/lua/toml_codec/codec.lua


--- ==============================================================================

-- Resolved here rather than assumed to be a global. LuaJIT has no utf8 table,
-- and a shared module cannot depend on its caller having installed the compat
-- shim — it does not know its callers. terminators.lua crashed from the E2E
-- runner for exactly that reason while working from the daemon and the unit
-- runner, both of which install one.
local utf8_lib = (type(utf8) == "table" and utf8.offset and utf8.len) and utf8 or require("compat.utf8")


-- LuaJIT is 5.1-based: `unpack` is a global there and `table.unpack` is absent
-- unless the build enabled 5.2 compatibility, which the one CI and the Linux
-- daemon run does not. Resolved once here rather than at each call site, and
-- table-first so a 5.4 interpreter keeps using the modern spelling.
local table_unpack = table.unpack or unpack
local RecordScanner = require("toml_codec.record_scanner")
--- MODULE: TOML Codec (shared)
--- DESCRIPTION:
--- Generic TOML encoder + decoder for arbitrarily nested Lua tables.
--- Canonical source shared by all Lua-based drivers (Hammerspoon, future Linux
--- driver). Previously lived at hammerspoon/infra/toml_codec.lua; moved here so
--- both drivers share one implementation without duplication.
---
--- FEATURES & RATIONALE:
--- 1. Round-trip for the HS state shape: scalars (string, number,
---    boolean), homogeneous arrays of scalars, maps (rendered as
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
--- - Inline tables (`{a=1, b=2}`) are NOT emitted; sub-tables always
---   become their own [section]. This keeps the writer simple and the
---   output line-diff-friendly.
--- - TOML datetime types are not supported; HS state has none.
--- - Float precision uses Lua's default tostring (16-digit max).
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
	s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
	     :gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
	return '"' .. s .. '"'
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

encode_value = function(v)
	local t = type(v)
	if t == "string"  then return encode_string(v) end
	if t == "boolean" then return tostring(v)      end
	if t == "number"  then
		if v ~= v then return "nan" end -- NaN
		if v ==  math.huge then return "+inf" end
		if v == -math.huge then return "-inf" end
		-- Preserve integer-ness when possible; Lua 5.3+ has integer subtype
		if v == math.floor(v) and math.abs(v) < 1e15 then
			return string.format("%d", v)
		end
		return tostring(v)
	end
	if t == "table" then
		if is_array_like(v) then
			local parts = {}
			for _, item in ipairs(v) do
				parts[#parts + 1] = encode_value(item)
			end
			return "[" .. table.concat(parts, ", ") .. "]"
		end
		-- Inline tables would land here; we never emit them — the walker
		-- in encode_table consumes sub-maps before calling encode_value
		return "{ }"
	end
	return '""'
end

--- Recursively walk a Lua table emitting TOML lines into `out`.
--- @param tbl   table  The table to encode at this level.
--- @param path  string The dotted-section path; "" for the root.
--- @param out   table  Mutable list of lines being built.
--- @param depth number Current nesting depth (0 = root).
encode_table = function(tbl, path, out, depth)
	-- Partition keys into scalars (and array values) vs sub-maps
	local scalars, submaps = {}, {}
	for k, v in pairs(tbl) do
		if type(v) == "table" and not is_array_like(v) then
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
		out[#out + 1] = encode_key(k) .. " = " .. encode_value(tbl[k])
	end
	if #scalars > 0 then
		ensure_blank_lines(out, 1)
	end
	for _, k in ipairs(submaps) do
		local subpath = (path == "") and encode_key(k) or (path .. "." .. encode_key(k))
		encode_table(tbl[k], subpath, out, depth + 1)
	end
end

--- Encode a Lua table as a TOML string.
--- @param tbl table The root table.
--- @return string The serialised TOML body.
function M.encode(tbl)
	if type(tbl) ~= "table" then return "" end
	local out = {
		"# Hammerspoon configuration — auto-generated. Hand-edits are",
		"# preserved across saves provided the file remains valid TOML.",
		"",
	}
	encode_table(tbl, "", out, 0)
	return table.concat(out, "\n")
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
	local parts = {}
	local i, n = 1, #s
	while i <= n do
		local c = s:sub(i, i)
		if c == '"' then
			local j = i + 1
			local buf = {}
			while j <= n do
				local cj = s:sub(j, j)
				if cj == "\\" and j < n then
					buf[#buf + 1] = s:sub(j + 1, j + 1)
					j = j + 2
				elseif cj == '"' then
					break
				else
					buf[#buf + 1] = cj
					j = j + 1
				end
			end
			parts[#parts + 1] = table.concat(buf)
			i = j + 1
			-- Swallow trailing dot
			if i <= n and s:sub(i, i) == "." then i = i + 1 end
		else
			local dot = s:find("%.", i)
			if dot then
				parts[#parts + 1] = trim(s:sub(i, dot - 1))
				i = dot + 1
			else
				parts[#parts + 1] = trim(s:sub(i))
				i = n + 1
			end
		end
	end
	return parts
end

--- Walk into nested maps creating intermediate tables as needed; return
--- the final leaf table.
local function nav(root, segments)
	local cur = root
	for _, seg in ipairs(segments) do
		if cur[seg] == nil then cur[seg] = {} end
		cur = cur[seg]
	end
	return cur
end

-- Forward declarations — implementations follow in the section below.
-- coerce_value calls split_kv and parse_key for inline-table parsing.
local split_kv, parse_key

--- Validates and unescapes a TOML basic-string body (without surrounding quotes).
--- Returns the unescaped string, or nil if it contains an invalid escape sequence
--- or a null byte.
local function unescape_string(s)
	-- Reject null bytes anywhere in the value
	if s:find("\0") then return nil end
	-- Validate escape sequences before performing substitution
	local i = 1
	while i <= #s do
		local c = s:sub(i, i)
		if c == "\\" then
			local e = s:sub(i + 1, i + 1)
			if e == "" then return nil end -- Trailing backslash
			if e == "u" then
				-- \uXXXX — must be exactly 4 hex digits
				local hex = s:sub(i + 2, i + 5)
				if not hex:match("^%x%x%x%x$") then return nil end
				i = i + 6
			elseif e == "U" then
				-- \UXXXXXXXX — must be exactly 8 hex digits
				local hex = s:sub(i + 2, i + 9)
				if not hex:match("^%x%x%x%x%x%x%x%x$") then return nil end
				i = i + 10
			elseif e == '"' or e == "\\" or e == "n" or e == "t" or e == "r"
				or e == "b" or e == "f" then
				i = i + 2
			else
				-- Any other escape sequence is invalid per the TOML spec
				return nil
			end
		else
			i = i + 1
		end
	end
	s = s:gsub("\\\\", "\1"):gsub('\\"', '\2')
	     :gsub("\\n", "\n"):gsub("\\t", "\t"):gsub("\\r", "\r")
	     :gsub("\\b", "\8"):gsub("\\f", "\12")
	     :gsub("\\u(%x%x%x%x)", function(h) return utf8_lib.char(tonumber(h, 16)) end)
	     :gsub("\\U(%x%x%x%x%x%x%x%x)", function(h)
	         local cp = tonumber(h, 16)
	         -- Codepoints above U+10FFFF are not valid Unicode; utf8_lib.char would throw.
	         if cp > 0x10FFFF then return "\xEF\xBF\xBD" end  -- replacement char U+FFFD
	         return utf8_lib.char(cp)
	     end)
	     :gsub("\1", "\\"):gsub("\2", '"')
	return s
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
				out[#out + 1] = triple
				quote = nil
				index = index + 3
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
				current[#current + 1] = triple
				quote = nil
				index = index + 3
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

local function collapse_multiline_continuations(body)
	local out = {}
	local index = 1
	while index <= #body do
		if body:sub(index, index) == "\\" and body:sub(index + 1, index + 1) == "\n" then
			index = index + 2
			while index <= #body and body:sub(index, index):match("[ \t\n]") do
				index = index + 1
			end
		else
			out[#out + 1] = body:sub(index, index)
			index = index + 1
		end
	end
	return table.concat(out)
end

--- Coerce a raw RHS into a Lua value (string / boolean / number / array / inline-table).
--- Returns PARSE_ERROR on malformed input so M.decode can return nil.
local function coerce_value(raw)
	raw = trim(strip_comments(raw))
	if raw == "" then return PARSE_ERROR end  -- Missing value (e.g., "key =")
	-- Booleans
	if raw == "true"  then return true  end
	if raw == "false" then return false end
	if raw:sub(1, 3) == "'''" then
		if raw:sub(-3) ~= "'''" or #raw < 6 then return PARSE_ERROR end
		local body = raw:sub(4, -4)
		if body:sub(1, 1) == "\n" then body = body:sub(2) end
		return body
	end
	if raw:sub(1, 3) == '"""' then
		if raw:sub(-3) ~= '"""' or #raw < 6 then return PARSE_ERROR end
		local body = raw:sub(4, -4)
		if body:sub(1, 1) == "\n" then body = body:sub(2) end
		body = collapse_multiline_continuations(body)
		local unescaped = unescape_string(body)
		if unescaped == nil then return PARSE_ERROR end
		return unescaped
	end
	-- Single-quoted string — TOML literal strings are valid, but single-quoted
	-- strings that are unclosed (no matching closing apostrophe) are an error.
	if raw:sub(1, 1) == "'" then
		if raw:sub(-1) ~= "'" or #raw < 2 then return PARSE_ERROR end
		-- Literal string — no escape processing, just return the body
		return raw:sub(2, -2)
	end
	-- Double-quoted string — require both opening and closing quote on the same value
	if raw:sub(1, 1) == '"' then
		if raw:sub(-1) ~= '"' or #raw < 2 then return PARSE_ERROR end  -- Unclosed string
		local body = raw:sub(2, -2)
		local unescaped = unescape_string(body)
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
			local v = coerce_value(v_raw or "")
			if v == PARSE_ERROR then return PARSE_ERROR end
			tbl[parse_key(k)] = v
		end
		return tbl
	end
	-- Array — split on commas at depth 0, ignoring quoted regions
	if raw:sub(1, 1) == "[" then
		if raw:sub(-1) ~= "]" then return PARSE_ERROR end
		local body = trim(raw:sub(2, -2))
		local out = {}
		if body == "" then return out end
		local elements = split_top_level_commas(body)
		if not elements then return PARSE_ERROR end
		for _, element in ipairs(elements) do
			local final = trim(element)
			if final == "" then return PARSE_ERROR end
			out[#out + 1] = coerce_value(final)
		end
		-- Propagate any element-level parse errors
		for _, v in ipairs(out) do
			if v == PARSE_ERROR then return PARSE_ERROR end
		end
		-- TOML forbids mixed-type arrays
		if #out > 1 then
			local first_type = type(out[1])
			for i = 2, #out do
				if type(out[i]) ~= first_type then return PARSE_ERROR end
			end
		end
		return out
	end
	-- Numbers — including TOML 1.0 special float literals
	if raw == "inf"  or raw == "+inf"  then return  math.huge end
	if raw == "-inf"                   then return -math.huge end
	if raw == "nan"  or raw == "+nan" or raw == "-nan" then return 0/0 end
	local int = raw:match("^[%+%-]?%d+$")
	if int then return tonumber(int) end
	local flt = raw:match("^[%+%-]?%d+%.%d+$") or raw:match("^[%+%-]?%d+[eE][%+%-]?%d+$")
	if flt then return tonumber(flt) end
	-- Bare key fallback — treat as string
	return raw
end

--- Parse a single key=value line, splitting on the FIRST '=' that is not
--- inside a quoted region. Returns key, raw_value (or nil on malformed input).
split_kv = function(line)
	local in_dbl, in_sgl, escape = false, false, false
	for i = 1, #line do
		local c = line:sub(i, i)
		if escape then
			escape = false
		elseif c == "\\" and in_dbl then
			escape = true
		elseif c == '"' and not in_sgl then
			in_dbl = not in_dbl
		elseif c == "'" and not in_dbl then
			in_sgl = not in_sgl
		elseif not in_dbl and not in_sgl and c == "=" then
			return trim(line:sub(1, i - 1)), trim(line:sub(i + 1))
		end
	end
	return nil, nil
end

--- Parse a key — either a bare identifier or a quoted string.
parse_key = function(raw)
	if raw:sub(1, 1) == '"' and raw:sub(-1) == '"' then
		return unescape_string(raw:sub(2, -2))
	end
	return raw
end

--- Strip a trailing inline comment from a TOML line, honouring both
--- double- and single-quoted regions so a '#' inside a string is kept.
--- @param s string The raw line.
--- @return string The line with any inline comment removed.
local function strip_inline_comment(s)
	return trim(strip_comments(s))
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
function M.decode(content)
	local root = {}
	local current = root
	-- Track which keys have been set in each table to detect duplicates
	local seen_keys = { [root] = {} }
	-- Track which regular section paths have been declared (not array-of-tables)
	local seen_sections = {}
	-- Active multi-line array accumulator (nil when not inside one). TOML permits
	-- an array value to span several lines; the decoder collects the fragments
	-- until the brackets balance, then coerces the joined text as one array.
	local pending = nil
	if type(content) ~= "string" or content == "" then return root end
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
				local v = coerce_value(table.concat(pending.parts, "\n"))
				if v == PARSE_ERROR then return nil end
				local sk = seen_keys[pending.target]
				if not sk then sk = {}; seen_keys[pending.target] = sk end
				if sk[pending.key] then return nil end
				sk[pending.key] = true
				pending.target[pending.key] = v
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
				-- Array-of-tables: append a new table to the array; no duplicate check
				local segments = split_section_path(aot_path)
				local parent = nav(root, { table_unpack(segments, 1, #segments - 1) })
				local last = segments[#segments]
				if type(parent[last]) ~= "table" then parent[last] = {} end
				local arr = parent[last]
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
			-- Detect duplicate regular section header (TOML forbids re-opening a table).
			-- Dedup on the RESOLVED segments (quotes stripped), not the raw header text —
			-- otherwise [a] and ["a"] hash to different seen_sections keys even though
			-- split_section_path()/nav() resolve them to the exact same table, silently
			-- allowing a table to be re-opened through its quoted-key spelling (F-LOW-3).
			local dedup_key = table.concat(segments, "\1")
			if seen_sections[dedup_key] then return nil end
			seen_sections[dedup_key] = true
			current = nav(root, segments)
			if not seen_keys[current] then seen_keys[current] = {} end

		else
			-- Key-value line: strip any inline comment first, honouring both
			-- double- and single-quoted regions so a literal string like
			-- key = 'hello # world' is not truncated at the '#'.
			local trimmed_nc = strip_inline_comment(trimmed)
			local key, raw = split_kv(trimmed_nc)
			-- Line with no '=' (e.g., multi-line string continuation) — skip
			if not key then goto continue_decode end
			-- Value with no key: line starts with '=' (key is empty string)
			if trim(key) == "" then return nil end
			-- Key with no value (raw is nil or empty after trimming)
			local raw_trimmed = raw and trim(raw) or ""
			if raw_trimmed == "" then return nil end
			local parsed_key = parse_key(key)
			-- Arrays and multiline strings share one exact record boundary. Defer
			-- coercion until neither a container nor a triple quote remains open.
			local depth, multiline_quote = scan_bracket_depth(raw_trimmed, 0, nil)
			if multiline_quote ~= nil or (raw_trimmed:sub(1, 1) == "[" and depth > 0) then
				pending = {
					key = parsed_key,
					target = current,
					parts = { raw_trimmed },
					depth = depth,
					multiline_quote = multiline_quote,
				}
				goto continue_decode
			end
			local v = coerce_value(raw_trimmed)
			-- Propagate parse errors from coerce_value
			if v == PARSE_ERROR then return nil end
			-- Duplicate key check within the current section
			local sk = seen_keys[current]
			if not sk then sk = {}; seen_keys[current] = sk end
			if sk[parsed_key] then return nil end
			sk[parsed_key] = true
			current[parsed_key] = v
		end
		::continue_decode::
	end
	-- A multi-line array that never closes is malformed TOML.
	if pending then return nil end
	return root
end


return M
