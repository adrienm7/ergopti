--- _shared/lua/llm/api_entry_names.lua

--- ==============================================================================
--- MODULE: API Entry Names
--- DESCRIPTION:
--- The name every tray gives a remote API entry: its provider id and its model,
--- such as "cerebras/qwen-3.8-27b". The maintainer retired the name the user
--- typed on 2026-09-30: it asked for one more field while adding an entry and
--- could describe another endpoint than the one the entry sends to.
---
--- FEATURES & RATIONALE:
--- 1. One rule for the three drivers: macOS and Linux call this module, and
---    Windows ports it (ui/menu/menu_llm/menu_api_entries.ahk). All three
---    replay _shared/tests/corpus/llm/api_entry_names_vectors.json.
--- 2. The caller resolves each entry first: the model and the base URL the
---    requests use, the provider's defaults standing in for empty fields.
--- 3. Entries of one provider and model (another key or address) are told
---    apart by the host they send to, then by their order, so no two rows of
---    the entry picker read the same.
--- 4. A name an earlier build stored with an entry is never read.
--- ==============================================================================

local M = {}





-- ================================
-- ================================
-- ======= 1/ Public API ==========
-- ================================
-- ================================

--- The host an entry sends to, with its port: "https://api.x.ai/v1" gives
--- "api.x.ai" and "http://localhost:1234/v1" gives "localhost:1234".
--- @param url string|nil The resolved base URL.
--- @return string host Lowercase, "" when the URL names none.
function M.host(url)
	if type(url) ~= "string" then return "" end
	local rest = url:match("^%s*(.-)%s*$")
	rest = rest:gsub("^%a[%w+.-]*://", "")
	rest = rest:gsub("^[^/?#@]*@", "")
	return (rest:match("^[^/?#]*") or ""):lower()
end

--- The name of every entry, in the order given.
--- @param entries table Array of { provider = string, model = string, base_url = string },
---   each resolved as its requests are sent.
--- @return table names Array of strings, one per entry.
function M.names(entries)
	local bases, uses = {}, {}
	for index, entry in ipairs(entries) do
		local base = tostring(entry.provider) .. "/" .. tostring(entry.model)
		bases[index] = base
		uses[base] = (uses[base] or 0) + 1
	end
	local names, seen = {}, {}
	for index, entry in ipairs(entries) do
		local name = bases[index]
		if uses[name] > 1 then
			local host = M.host(entry.base_url)
			local key = name .. "\n" .. host
			seen[key] = (seen[key] or 0) + 1
			local parts = {}
			if host ~= "" then parts[#parts + 1] = host end
			if seen[key] > 1 then parts[#parts + 1] = tostring(seen[key]) end
			if #parts > 0 then name = name .. " (" .. table.concat(parts, ", ") .. ")" end
		end
		names[index] = name
	end
	return names
end

return M
