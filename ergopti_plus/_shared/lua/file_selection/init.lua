--- _shared/lua/file_selection/init.lua

--- ==============================================================================
--- MODULE: File Manager Selection Parsers
--- DESCRIPTION:
--- Turns what a file manager reports about its selection into absolute paths,
--- for the file-selection actions (remove_quarantine_selection,
--- make_executable_selection) of the macOS and Linux drivers. Windows reads
--- Explorer's SelectedItems through COM (modules/gestures/system_actions.ahk).
---
--- FEATURES & RATIONALE:
--- 1. Pure: the caller runs the native query and passes its text, so both
---    parsers are replayed by the two Lua suites against one shared corpus,
---    _shared/tests/corpus/file_selection/vectors.json.
--- 2. Finder is read as a recompilable AppleScript list (`osascript -ss`), not
---    as one path per line: a file name may contain a line break, and a
---    line-based reader would then act on a truncated path that exists.
--- 3. The Linux file managers publish a copied selection as text/uri-list
---    (RFC 2483). Only local file: URIs name a path; anything else refuses the
---    whole selection rather than acting on part of it.
--- 4. Every parser fails closed: a malformed report returns nil and a reason,
---    never a best-effort subset of paths an action would then modify.
--- ==============================================================================

local M = {}

-- The two characters an AppleScript string literal escapes with a backslash,
-- spelled by code so no quote character sits inside a quoted Lua string.
local QUOTE = string.char(34)
local BACKSLASH = string.char(92)

--- The escapes AppleScript writes inside a recompilable string literal, keyed
--- by the character that follows the backslash.
local APPLESCRIPT_ESCAPES = { [QUOTE] = QUOTE, [BACKSLASH] = BACKSLASH, n = "\n", r = "\r", t = "\t" }

--- Whether a parsed path is absolute and free of the NUL byte no path holds.
--- @param path string
--- @return boolean
local function is_absolute_path(path)
	return path:sub(1, 1) == "/" and not path:find("\0", 1, true)
end

--- Parses the recompilable form of an AppleScript list of POSIX paths, as
--- `osascript -ss` prints it: `{}` or `{"/a", "/b/"}`.
--- @param text any The osascript output, trailing newline included or not.
--- @return table|nil paths Absolute paths in selection order.
--- @return string|nil reason Why the output was refused.
function M.parse_applescript_paths(text)
	if type(text) ~= "string" then return nil, "not_text" end
	local body = text:gsub("^%s+", ""):gsub("%s+$", "")
	if body:sub(1, 1) ~= "{" or body:sub(-1) ~= "}" then return nil, "not_a_list" end
	local paths, at, last = {}, 2, #body - 1
	while true do
		while at <= last and body:sub(at, at):match("%s") do at = at + 1 end
		if at > last then break end
		if body:sub(at, at) ~= QUOTE then return nil, "not_a_string_item" end
		local chars = {}
		at = at + 1
		while true do
			if at > last then return nil, "unterminated_string" end
			local char = body:sub(at, at)
			if char == QUOTE then break end
			if char == BACKSLASH then
				local escaped = APPLESCRIPT_ESCAPES[body:sub(at + 1, at + 1)]
				if not escaped then return nil, "unknown_escape" end
				chars[#chars + 1] = escaped
				at = at + 2
			else
				chars[#chars + 1] = char
				at = at + 1
			end
		end
		local path = table.concat(chars)
		if not is_absolute_path(path) then return nil, "relative_path" end
		paths[#paths + 1] = path
		at = at + 1
		while at <= last and body:sub(at, at):match("%s") do at = at + 1 end
		if at > last then break end
		if body:sub(at, at) ~= "," then return nil, "missing_separator" end
		at = at + 1
	end
	return paths, nil
end

--- Decodes the %XX escapes of a URI path.
--- @param encoded string
--- @return string|nil decoded Nil when an escape is malformed.
local function percent_decode(encoded)
	if encoded:find("%%[^%x]") or encoded:find("%%%x[^%x]") or encoded:find("%%%x?$") then
		return nil
	end
	return (encoded:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

--- Parses a text/uri-list selection (RFC 2483): one URI per line, CRLF or LF,
--- `#` comments and blank lines ignored.
--- @param text any The clipboard content published as text/uri-list.
--- @return table|nil paths Absolute local paths in selection order.
--- @return string|nil reason Why the list was refused.
function M.parse_uri_list(text)
	if type(text) ~= "string" then return nil, "not_text" end
	local paths = {}
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		line = line:gsub("\r$", "")
		if line ~= "" and line:sub(1, 1) ~= "#" then
			local authority, encoded = line:match("^[Ff][Ii][Ll][Ee]://([^/]*)(/.*)$")
			if not encoded then return nil, "not_a_local_file_uri" end
			if authority ~= "" and authority:lower() ~= "localhost" then return nil, "remote_host" end
			if encoded:find("[?#]") then return nil, "query_or_fragment" end
			local path = percent_decode(encoded)
			if not path then return nil, "malformed_escape" end
			if not is_absolute_path(path) then return nil, "relative_path" end
			paths[#paths + 1] = path
		end
	end
	return paths, nil
end

return M
