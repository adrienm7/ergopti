--- modules/llm/provider_uses.lua

--- ==============================================================================
--- MODULE: Remote Provider Uses
--- DESCRIPTION:
--- Tells which uses each request format of _shared/modules/llm/api_providers.json
--- can serve, and lists the providers of the catalogue that serve one use, in the
--- catalogue's order.
---
--- FEATURES & RATIONALE:
--- 1. The uses follow the format, never a provider id: a provider added to the
---    catalogue appears in every list its format serves without a driver edit.
--- 2. "decisions" (TypeSafe's Jev) is not a chat model: it only triages, so it
---    serves the agent's System 1 alone. "backboard" answers text but carries no
---    image, so it serves every text use and no vision request.
--- 3. Pure and stateless: the lists read a catalogue passed in (api_remote's
---    PROVIDERS and PROVIDER_ORDER), so callers and tests share one rule.
--- ==============================================================================

local M = {}

-- The uses a provider can serve
M.PREDICTION = "prediction"   -- the AI menu's prediction backend (and its text actions)
M.SYSTEM1    = "system1"      -- the agent's triage
M.SYSTEM2    = "system2"      -- the agent's actions
M.VISION     = "vision"       -- a screenshot request

-- The uses of each format
local FORMAT_USES = {
	openai    = { prediction = true, system1 = true, system2 = true, vision = true },
	anthropic = { prediction = true, system1 = true, system2 = true, vision = true },
	gemini    = { prediction = true, system1 = true, system2 = true, vision = true },
	backboard = { prediction = true, system1 = true, system2 = true, vision = false },
	decisions = { prediction = false, system1 = true, system2 = false, vision = false },
}

--- Tells whether a request format serves a use.
--- @param format string|nil A format of api_providers.json.
--- @param use string M.PREDICTION, M.SYSTEM1, M.SYSTEM2 or M.VISION.
--- @return boolean serves
function M.format_serves(format, use)
	local uses = FORMAT_USES[format]
	return type(uses) == "table" and uses[use] == true
end

--- Tells whether a provider of a catalogue serves a use.
--- @param providers table Provider id -> descriptor with a `format`.
--- @param provider_id string
--- @param use string
--- @return boolean serves
function M.provider_serves(providers, provider_id, use)
	local provider = type(providers) == "table" and providers[provider_id] or nil
	return type(provider) == "table" and M.format_serves(provider.format, use)
end

--- Lists the providers that serve a use, in the catalogue's order.
--- @param order table Provider ids in menu order.
--- @param providers table Provider id -> descriptor with a `format`.
--- @param use string
--- @return table ids
function M.provider_ids(order, providers, use)
	local ids = {}
	for _, provider_id in ipairs(order or {}) do
		if M.provider_serves(providers, provider_id, use) then ids[#ids + 1] = provider_id end
	end
	return ids
end

return M
