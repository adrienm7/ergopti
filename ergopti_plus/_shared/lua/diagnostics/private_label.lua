--- _shared/lua/diagnostics/private_label.lua

--- ==============================================================================
--- MODULE: Private Label
--- DESCRIPTION:
--- The text a log line prints in place of a name the user chose: a hotstring
--- category or mapping file such as a personal pack. The log redactor masks such
--- names only as path components under the configuration directory; a bare name
--- in a message needs the same placeholder at the point of emission, so that no
--- name reaches the log in clear text.
---
--- The placeholder is the one redaction.json declares as config_name_placeholder;
--- a contract test pins the two together.
--- ==============================================================================

local M = {}

--- What a masked name reads as in a log line.
M.PLACEHOLDER = "<name>"

--- Masks a user-chosen name for a log line.
--- @param name any The name; only its type is checked, never its content.
--- @return string placeholder Always M.PLACEHOLDER.
function M.mask(name)
	if type(name) ~= "string" then error("private_label: the name must be a string", 2) end
	return M.PLACEHOLDER
end

return M
