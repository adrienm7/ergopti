--- _shared/lua/llm/api_model_listing.lua

--- ==============================================================================
--- MODULE: API Model Listing Plan
--- DESCRIPTION:
--- Which rows the model selector page shows for one API entry: one per model
--- the provider's model listing returned, or, while that listing is pending,
--- refused or unavailable, the models the catalogue knows for the provider and
--- a row to type another model id, with the reason as its hint.
---
--- FEATURES & RATIONALE:
--- 1. One rule, three drivers: this module (macOS, Linux) and its Windows port
---    in windows/modules/llm/api_remote.ahk replay
---    _shared/tests/corpus/llm/api_model_listing_vectors.json, so a provider
---    reads the same on every OS.
--- 2. Bounded: a page lists at most MAX_ENTRIES entries, one at a time; a
---    listing keeps at most MAX_MODELS ids, each at most
---    MAX_ID_LENGTH bytes, without whitespace or control characters, because
---    a chosen id is written to the configuration and sent in requests.
--- 3. Pure: the drivers fetch the listing with their own HTTP client and hand
---    the decoded answer here; no key or address ever reaches this module.
--- ==============================================================================

local M = {}

-- Most models one provider listing shows; OpenRouter lists a few hundred.
M.MAX_MODELS = 200
-- Longest model id kept from a listing.
M.MAX_ID_LENGTH = 200
-- Most entries one page open lists, one request at a time, each with the
-- request timeout: a page open costs at most this many listings.
M.MAX_ENTRIES = 16

-- The row hint of each fallback reason.
M.HINTS = {
	pending = "model_browser.hint_api_listing_pending",
	refused = "model_browser.hint_api_listing_refused",
	unavailable = "model_browser.hint_api_listing_unavailable",
}

-- The wire formats whose providers list their models at <base>/models.
local LISTING_FORMATS = { openai = true, anthropic = true, gemini = true }

--- Whether providers of one wire format answer a model listing.
--- @param format string Provider wire format (api_providers.json).
--- @return boolean
function M.supported(format)
	return LISTING_FORMATS[format] == true
end

--- Whether one model id may become a row.
--- @param id any
--- @return boolean
function M.valid_id(id)
	return type(id) == "string" and id ~= "" and #id <= M.MAX_ID_LENGTH
		and not id:find("[%s%c]")
end

--- Extracts the model ids of a decoded listing answer.
--- @param format string Provider wire format.
--- @param decoded any The decoded JSON body.
--- @return table|nil ids Sorted, unique, at most MAX_MODELS.
--- @return string|nil reason "unsupported" or "unreadable".
function M.model_ids(format, decoded)
	if not M.supported(format) then return nil, "unsupported" end
	local list = type(decoded) == "table" and decoded[format == "gemini" and "models" or "data"] or nil
	if type(list) ~= "table" then return nil, "unreadable" end
	local ids, seen = {}, {}
	for _, item in ipairs(list) do
		local id = type(item) == "table" and (item.id or item.name) or nil
		if format == "gemini" and type(id) == "string" and id:sub(1, 7) == "models/" then id = id:sub(8) end
		if M.valid_id(id) and not seen[id] then
			seen[id] = true
			ids[#ids + 1] = id
		end
	end
	table.sort(ids)
	for index = #ids, M.MAX_MODELS + 1, -1 do ids[index] = nil end
	return ids, nil
end

--- Splits an entry's automatic name (_shared/lua/llm/api_entry_names.lua:
--- "<provider>/<model>", then " (<host>[, <order>])" when two entries share
--- it) around its model, so every row of the entry reads
--- "<provider>/<row model><suffix>" and the typed-id row "<provider><suffix>":
--- rows of two entries of one provider stay apart.
--- @param name string The entry's automatic name.
--- @param model string The model its requests use.
--- @return string base, string suffix
function M.name_parts(name, model)
	if type(name) ~= "string" then error("api_model_listing.name_parts requires a name", 2) end
	if type(model) == "string" and model ~= "" then
		local at = name:find("/" .. model, 1, true)
		if at then
			local rest = name:sub(at + #model + 1)
			if rest == "" or rest:sub(1, 2) == " (" then return name:sub(1, at - 1), rest end
		end
	end
	return name, ""
end

--- The rows of one entry.
--- @param view table { model = configured id, default_model = provider default, extras = { model ids },
---   format = provider wire format }.
--- @param listing table|nil nil when never asked; { state = "pending" }, { state = "listed", ids = {...} }
---   or { state = "failed", reason = "refused"|"unreadable"|"unavailable"|"unsupported" }.
--- @return table plan { models = { { model, listed } }, typed = nil|{ hint_key } }.
function M.plan(view, listing)
	if type(view) ~= "table" then error("api_model_listing.plan requires an entry view", 2) end
	local models, seen = {}, {}
	local function add(id, listed)
		if M.valid_id(id) and not seen[id] then
			seen[id] = true
			models[#models + 1] = { model = id, listed = listed }
		end
	end
	-- A decisions provider (Jev) answers typed questions, never a chat model:
	-- its entry keeps its one model and nothing to type.
	if view.format == "decisions" then
		add(view.model, false)
		return { models = models }
	end
	local state = type(listing) == "table" and listing.state or nil
	if state == "listed" and type(listing.ids) == "table" and #listing.ids > 0 then
		-- The configured model stays visible even when the listing omits it.
		local listed = {}
		for _, id in ipairs(listing.ids) do listed[id] = true end
		if not listed[view.model] then add(view.model, false) end
		for _, id in ipairs(listing.ids) do add(id, true) end
		return { models = models }
	end
	add(view.model, false)
	add(view.default_model, false)
	local extras = {}
	for _, id in ipairs(type(view.extras) == "table" and view.extras or {}) do extras[#extras + 1] = id end
	table.sort(extras)
	for _, id in ipairs(extras) do add(id, false) end
	local reason = "unavailable"
	if state == "pending" then
		reason = "pending"
	elseif state == "failed" and listing.reason == "refused" then
		reason = "refused"
	end
	return { models = models, typed = { hint_key = M.HINTS[reason] } }
end

return M
