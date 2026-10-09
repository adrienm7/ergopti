--- _shared/lua/llm/provider_config_policy.lua

--- ==============================================================================
--- MODULE: Stored Provider Identity Policy
--- DESCRIPTION:
--- Only published cloud and local catalogues prove that a stored provider is
--- retired. Unavailable catalogues retain choices until their actual owner can
--- publish an admitted inventory; no stored row grants provider capability.
--- ==============================================================================

local M = {}

--- Detaches the registered identities from a native catalogue owner.
--- @param cloud_published boolean Exact cloud publication acknowledgement.
--- @param local_published boolean Exact local publication acknowledgement.
--- @param providers table Native registered provider descriptors.
--- @return table receipt Read-only identity snapshot for configuration readers.
function M.snapshot(cloud_published, local_published, providers)
	local ids = {}
	for id in pairs(providers) do ids[id] = true end
	return { published = cloud_published == true and local_published == true and next(ids) ~= nil, ids = ids }
end

--- Classifies an identity only against an explicitly admitted inventory.
--- Registered neighbors remain usable even if another catalogue is unavailable.
--- @param provider string Stored provider identity.
--- @param receipt table|nil Native owner's detached publication receipt.
--- @return string status known, retired or unpublished.
function M.classify(provider, receipt)
	if type(receipt) ~= "table" or type(receipt.ids) ~= "table" then return "unpublished" end
	if next(receipt.ids) == nil then return "unpublished" end
	if receipt.ids[provider] == true then return "known" end
	return receipt.published == true and "retired" or "unpublished"
end

return M
