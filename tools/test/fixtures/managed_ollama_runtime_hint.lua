--- tools/test/fixtures/managed_ollama_runtime_hint.lua

--- ==============================================================================
--- MODULE: Optional Ollama Runtime Selection Hint
--- DESCRIPTION:
--- Matches installed receipt metadata to the exact bundled catalogue. This
--- hint selects a candidate only; Python must independently admit all source
--- bytes, signature, alias and native image before starting a managed daemon.
--- ==============================================================================

local M = {}

--- Compares metadata without conferring filesystem or process authority.
--- @param contract table Canonical source contract.
--- @param catalogue table Actual produced runtime catalogue.
--- @param receipt table Installed runtime receipt.
--- @param host string Native host key.
--- @param contract_digest string Hash of the exact source contract bytes.
--- @param catalogue_digest string Hash of the exact catalogue bytes.
--- @return boolean candidate Receipt may supply a provisional selection hint.
function M.matches(contract, catalogue, receipt, host, contract_digest, catalogue_digest)
	if type(contract) ~= "table" or type(catalogue) ~= "table" or type(receipt) ~= "table"
		or type(host) ~= "string" or type(catalogue.assets) ~= "table"
		or type(contract_digest) ~= "string" or #contract_digest ~= 64
		or not contract_digest:match("^[0-9a-f]+$")
		or type(catalogue_digest) ~= "string" or #catalogue_digest ~= 64
		or not catalogue_digest:match("^[0-9a-f]+$") then return false end
	local asset = catalogue.assets[host]
	if type(asset) ~= "table" or contract.schema_version ~= 1 or catalogue.schema_version ~= 1
		or catalogue.runtime_contract_sha256 ~= contract_digest then return false end
	for _, name in ipairs({ "version", "source_commit", "capability", "native_http_capability" }) do
		if contract[name] == nil or contract[name] ~= catalogue[name] or contract[name] ~= asset[name] then return false end
	end
	for _, name in ipairs({ "sha256", "binary_sha256" }) do
		if type(asset[name]) ~= "string" or #asset[name] ~= 64 or not asset[name]:match("^[0-9a-f]+$") then return false end
	end
	if type(asset.source_commit) ~= "string" or #asset.source_commit ~= 40
		or not asset.source_commit:match("^[0-9a-f]+$")
		or type(asset.native_http_capability) ~= "number" or asset.native_http_capability % 1 ~= 0
		or asset.native_http_capability < 1 or type(asset.capability) ~= "string" or asset.capability == "" then return false end
	local expected = {
		schema_version = contract.schema_version,
		host = host,
		runtime_contract_sha256 = contract_digest,
		catalogue_sha256 = catalogue_digest,
		asset_sha256 = asset.sha256,
		binary_sha256 = asset.binary_sha256,
		source_commit = asset.source_commit,
		capability = asset.capability,
		native_http_capability = asset.native_http_capability,
	}
	local count = 0
	for name, value in pairs(receipt) do
		if expected[name] == nil or expected[name] ~= value then return false end
		count = count + 1
	end
	local required = 0
	for name, value in pairs(expected) do
		if receipt[name] ~= value then return false end
		required = required + 1
	end
	-- Nil asset fields must not shorten the installed receipt schema.
	return count == 9 and required == 9
end

return M
