--- shared/lua/toml_codec/codec.lua

--- ==============================================================================
--- MODULE: TOML Codec (shared)
--- DESCRIPTION:
--- Generic TOML encoder + decoder for arbitrarily nested Lua tables.
--- Canonical source shared by all Lua-based drivers (Hammerspoon, future Linux
--- driver). Previously lived at hammerspoon/lib/toml_codec.lua; moved here so
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
	     :gsub("\\u(%x%x%x%x)", function(h) return utf8.char(tonumber(h, 16)) end)
	     :gsub("\\U(%x%x%x%x%x%x%x%x)", function(h) return utf8.char(tonumber(h, 16)) end)
	     :gsub("\1", "\\"):gsub("\2", '"')
	return s
end

-- Sentinel returned by coerce_value on parse failure; propagated to M.decode.
local PARSE_ERROR = {}

--- Coerce a raw RHS into a Lua value (string / boolean / number / array / inline-table).
--- Returns PARSE_ERROR on malformed input so M.decode can return nil.
local function coerce_value(raw)
	raw = trim(raw)
	if raw == "" then return PARSE_ERROR end  -- Missing value (e.g., "key =")
	-- Booleans
	if raw == "true"  then return true  end
	if raw == "false" then return false end
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
		local in_str, escape = false, false
		local pairs_raw = {}
		local cur = {}
		for i = 1, #body do
			local c = body:sub(i, i)
			if escape then cur[#cur+1]=c; escape=false
			elseif c=="\\" and in_str then cur[#cur+1]=c; escape=true
			elseif c=='"' then cur[#cur+1]=c; in_str=not in_str
			elseif not in_str and c=="," then
				pairs_raw[#pairs_raw+1] = table.concat(cur); cur={}
			else
				cur[#cur+1]=c
			end
		end
		if #cur>0 then pairs_raw[#pairs_raw+1]=table.concat(cur) end
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
		-- Multi-line array: value does not close on the same line — skip gracefully
		if raw:sub(-1) ~= "]" then return {} end
		local body = trim(raw:sub(2, -2))
		local out = {}
		if body == "" then return out end
		local depth, in_str, escape, cur = 0, false, false, {}
		for i = 1, #body do
			local c = body:sub(i, i)
			if escape then
				cur[#cur + 1] = c
				escape = false
			elseif c == "\\" and in_str then
				cur[#cur + 1] = c
				escape = true
			elseif c == '"' then
				cur[#cur + 1] = c
				in_str = not in_str
			elseif not in_str and c == "[" then
				depth = depth + 1; cur[#cur + 1] = c
			elseif not in_str and c == "]" then
				depth = depth - 1; cur[#cur + 1] = c
			elseif not in_str and depth == 0 and c == "," then
				out[#out + 1] = coerce_value(table.concat(cur))
				cur = {}
			else
				cur[#cur + 1] = c
			end
		end
		if #cur > 0 then
			local final = trim(table.concat(cur))
			if final ~= "" then out[#out + 1] = coerce_value(final) end
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
	-- Numbers
	local int = raw:match("^%-?%d+$")
	if int then return tonumber(int) end
	local flt = raw:match("^%-?%d+%.%d+$")
	if flt then return tonumber(flt) end
	-- Bare key fallback — treat as string
	return raw
end

--- Parse a single key=value line, splitting on the FIRST '=' that is not
--- inside a quoted region. Returns key, raw_value (or nil on malformed input).
split_kv = function(line)
	local in_str, escape = false, false
	for i = 1, #line do
		local c = line:sub(i, i)
		if escape then
			escape = false
		elseif c == "\\" and in_str then
			escape = true
		elseif c == '"' then
			in_str = not in_str
		elseif not in_str and c == "=" then
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
	if type(content) ~= "string" or content == "" then return root end
	for line in (content .. "\n"):gmatch("([^\r\n]*)\r?\n") do
		local trimmed = trim(line)
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
				local parent = nav(root, { table.unpack(segments, 1, #segments - 1) })
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
			-- Detect duplicate regular section header (TOML forbids re-opening a table)
			if seen_sections[path] then return nil end
			seen_sections[path] = true
			local segments = split_section_path(path)
			current = nav(root, segments)
			if not seen_keys[current] then seen_keys[current] = {} end

		else
			-- Key-value line: strip inline comment before processing
			-- Strip trailing `# comment` when not inside a quoted region
			local trimmed_nc = trimmed
			do
				local in_str, escape = false, false
				for ci = 1, #trimmed do
					local c = trimmed:sub(ci, ci)
					if escape then escape = false
					elseif c == "\\" and in_str then escape = true
					elseif c == '"' then in_str = not in_str
					elseif not in_str and c == "#" then
						trimmed_nc = trim(trimmed:sub(1, ci - 1))
						break
					end
				end
			end
			local key, raw = split_kv(trimmed_nc)
			-- Line with no '=' (e.g., multi-line string continuation) — skip
			if not key then goto continue_decode end
			-- Value with no key: line starts with '=' (key is empty string)
			if trim(key) == "" then return nil end
			-- Key with no value (raw is nil or empty after trimming)
			local raw_trimmed = raw and trim(raw) or ""
			if raw_trimmed == "" then return nil end
			local v = coerce_value(raw_trimmed)
			-- Propagate parse errors from coerce_value
			if v == PARSE_ERROR then return nil end
			local parsed_key = parse_key(key)
			-- Duplicate key check within the current section
			local sk = seen_keys[current]
			if not sk then sk = {}; seen_keys[current] = sk end
			if sk[parsed_key] then return nil end
			sk[parsed_key] = true
			current[parsed_key] = v
		end
		::continue_decode::
	end
	return root
end


return M
