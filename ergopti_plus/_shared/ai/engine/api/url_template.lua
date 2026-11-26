--- _shared/ai/engine/api/url_template.lua

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
---    Windows ports it (_shared/ai/data/api_url_template.ahk). All three
---    replay _shared/tests/corpus/llm/api_url_template_vectors.json.
--- 2. A placeholder is {name}, name lowercase letters, digits and _, so the
---    form can label it with menu.llm.api_prompt_field.<name>.
--- 3. A value fills a host label or a path segment only: letters, digits,
---    dot, hyphen and underscore, starting with a letter or a digit, so a
---    value cannot add a scheme, a user, a port, a path or a query.
--- 4. A template never reaches the network: a request whose address still
---    holds a placeholder is refused (M.has_placeholder).
--- 5. An optional_address block is the opposite case: the catalogue's address
---    works as it is, and the form offers one optional field that replaces it
---    (DashScope's workspace-dedicated domains). An empty value keeps the
---    catalogue's address; a filled one must end with the block's host_suffix,
---    so the field can only name a host of that provider.
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

--- Why an optional_address block cannot be used.
--- @param optional any The block, nil when the provider declares none.
--- @return string|nil reason Nil for a usable or absent block.
function M.optional_problem(optional)
	if optional == nil then return nil end
	if type(optional) ~= "table" then return "not an object" end
	local field, template, suffix = optional.field, optional.template, optional.host_suffix
	if type(field) ~= "string" or field:match("^[%l%d_]+$") == nil then return "no field name" end
	if type(template) ~= "string" or template:match("^https://%S+$") == nil then return "no https template" end
	local fields, reason = M.fields(template)
	if reason or #fields ~= 1 or fields[1] ~= field then return "the template must hold its field once" end
	if type(suffix) ~= "string" or suffix:match("^%.[%w.-]+$") == nil or suffix:find("..", 1, true) then
		return "no host suffix"
	end
	return nil
end

--- The address one value of an optional field gives.
--- @param optional table A block optional_problem() accepted.
--- @param value string The trimmed value.
--- @return string|nil url The address, "" to keep the catalogue's, nil when refused.
function M.optional_url(optional, value)
	if value == "" then return "" end
	if not M.valid_value(value) or value:find("..", 1, true) then return nil end
	local suffix = optional.host_suffix
	if #value <= #suffix or value:sub(-#suffix):lower() ~= suffix:lower() then return nil end
	return (M.expand(optional.template, { [optional.field] = value }))
end

return M
