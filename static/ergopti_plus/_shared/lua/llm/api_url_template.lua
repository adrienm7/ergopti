--- _shared/lua/llm/api_url_template.lua

--- ==============================================================================
--- MODULE: API URL Template
--- DESCRIPTION:
--- The address of a provider whose host or path depends on the user's account
--- (Azure resource, AWS region, Cloudflare account id, Databricks workspace,
--- Snowflake account): api_providers.json writes its base_url as a template
--- such as "https://{resource}.openai.azure.com/openai/v1", the add-entry form
--- asks one value per placeholder, and the filled address becomes the entry's
--- own base_url, which every driver already prefers to the catalogue's.
---
--- FEATURES & RATIONALE:
--- 1. One rule for the three drivers: macOS and Linux call this module, and
---    Windows ports it (_shared/modules/llm/api_url_template.ahk). All three
---    replay _shared/tests/corpus/llm/api_url_template_vectors.json.
--- 2. A placeholder is {name}, name lowercase letters, digits and _, so the
---    form can label it with menu.llm.api_prompt_field.<name>.
--- 3. A value fills a host label or a path segment only: letters, digits,
---    dot, hyphen and underscore, starting with a letter or a digit, so a
---    value cannot add a scheme, a user, a port, a path or a query.
--- 4. A template never reaches the network: a request whose address still
---    holds a placeholder is refused (M.has_placeholder).
--- ==============================================================================

local M = {}

-- Longest value one placeholder takes: a DNS name.
M.MAX_VALUE_LENGTH = 253

local PLACEHOLDER = "{([%l%d_]+)}"




-- ================================
-- ================================
-- ======= 1/ Public API ==========
-- ================================
-- ================================

--- Whether an address still holds a placeholder.
--- @param url any
--- @return boolean
function M.has_placeholder(url)
	return type(url) == "string" and url:find("{", 1, true) ~= nil
end

--- The placeholders of a template, in order, each once.
--- @param template any A catalogue base_url.
--- @return table fields Array of names; empty when the address is not a template.
--- @return string|nil reason Why the template is malformed (a brace outside {name}).
function M.fields(template)
	if type(template) ~= "string" then return {}, nil end
	local fields, seen = {}, {}
	for name in template:gmatch(PLACEHOLDER) do
		if not seen[name] then
			seen[name] = true
			fields[#fields + 1] = name
		end
	end
	local rest = template:gsub(PLACEHOLDER, "")
	if rest:find("[{}]") then return {}, "a brace outside a {name} placeholder" end
	return fields, nil
end

--- Whether one value may fill a placeholder.
--- @param value any
--- @return boolean
function M.valid_value(value)
	return type(value) == "string" and #value > 0 and #value <= M.MAX_VALUE_LENGTH
		and value:match("^[%w][%w._-]*$") ~= nil
end

--- Fills a template.
--- @param template string A catalogue base_url.
--- @param values table name -> value, one per placeholder.
--- @return string|nil url The address, nil when a value is missing or invalid.
--- @return string|nil field The placeholder whose value is missing or invalid.
function M.expand(template, values)
	if type(template) ~= "string" then error("api_url_template.expand requires a template", 2) end
	if type(values) ~= "table" then error("api_url_template.expand requires values", 2) end
	local fields, reason = M.fields(template)
	if reason then error("api_url_template.expand: " .. reason, 2) end
	for _, name in ipairs(fields) do
		if not M.valid_value(values[name]) then return nil, name end
	end
	return (template:gsub(PLACEHOLDER, function(name) return values[name] end)), nil
end

return M
