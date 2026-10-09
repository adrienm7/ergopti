--- _shared/lua/sqlite/literal.lua
--- ==============================================================================
--- MODULE: SQLite Literal Encoding (shared)
--- DESCRIPTION:
--- Preserves scalar text bytes inside caller-owned single-quoted SQL values.
--- Native C-string and CLI line boundaries cannot carry literal NUL/CRLF safely;
--- SQLite char expressions retain those bytes without changing stored content.
--- ==============================================================================

local M = {}

--- Encodes content embedded inside a single-quoted SQLite value.
--- @param value string Content between the caller's literal quotes.
--- @return string Escaped content with control bytes represented in SQL.
function M.escape(value)
	assert(type(value) == "string", "SQLite literal content must be a string")
	return (value:gsub("'", "''"):gsub("\r", "'||char(13)||'"):gsub("%z", "'||char(0)||'"))
end

return M
