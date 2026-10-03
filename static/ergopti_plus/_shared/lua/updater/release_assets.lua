--- _shared/lua/updater/release_assets.lua

--- ==============================================================================
--- MODULE: Declared Release Archive Selection (Shared)
--- DESCRIPTION:
--- Resolves the macOS manual-install archive order from shared updater data.
--- Each candidate is bound to an exact GitHub repository URL and SHA-256.
--- A present candidate that is malformed or ambiguous refuses the release;
--- only absence permits the next declared historical format. Pure Lua owns
--- selection policy while the native driver owns extraction and installation.
--- ==============================================================================

local M = {}
local NAME_PATTERN = "^[A-Za-z0-9._%-]+$"
local FORMATS = { zip = ".zip", ["tar.xz"] = ".tar.xz" }

--- Whether a declared archive format has an admitted native implementation.
--- @param format any
--- @return boolean
function M.supports(format)
	return type(format) == "string" and FORMATS[format] ~= nil
end

--- Whether a table is a dense array, retaining malformed-item refusals.
--- @param value any
--- @return boolean
local function dense(value)
	if type(value) ~= "table" then return false end
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
		count = count + 1
	end
	return count == #value
end

--- Resolve asset-key bindings without duplicating artifact names in a driver.
--- @param defaults table Decoded shared updater defaults.
--- @return table|nil identity { owner, repo, archives = { { name, format } } }
--- @return string|nil reason Closed declaration refusal.
function M.resolve(defaults)
	if type(defaults) ~= "table" then return nil, "missing-defaults" end
	local github, assets, install = defaults.github, defaults.release_assets, defaults.release_install
	local bindings = type(install) == "table" and install.macos_archives or nil
	if type(github) ~= "table" or type(github.owner) ~= "string" or not github.owner:match(NAME_PATTERN)
		or type(github.repo) ~= "string" or not github.repo:match(NAME_PATTERN)
		or type(assets) ~= "table" or not dense(bindings) or #bindings == 0 then
		return nil, "invalid-archive-declaration"
	end
	local archives, names = {}, {}
	for _, binding in ipairs(bindings) do
		local key = type(binding) == "table" and binding.asset_key or nil
		local format = type(binding) == "table" and binding.format or nil
		local name = type(key) == "string" and assets[key] or nil
		if not M.supports(format) or type(name) ~= "string" or not name:match(NAME_PATTERN)
			or name:sub(-#FORMATS[format]) ~= FORMATS[format] or names[name] then
			return nil, "invalid-archive-binding"
		end
		names[name] = true
		archives[#archives + 1] = { name = name, format = format }
	end
	return { owner = github.owner, repo = github.repo, archives = archives }
end

--- Select the first present archive; corruption never means absence.
--- @param release table GitHub release object.
--- @param identity table Result of resolve().
--- @return table|nil asset { tag, version, url, digest, format }
--- @return string|nil reason Closed selection refusal.
function M.select(release, identity)
	if type(release) ~= "table" or type(identity) ~= "table" then return nil, "invalid-release" end
	local tag = release.tag_name
	if type(tag) ~= "string" or not tag:match("^v?[%w%.%-]+$") or not dense(release.assets)
		or not dense(identity.archives) or #identity.archives == 0
		or type(identity.owner) ~= "string" or not identity.owner:match(NAME_PATTERN)
		or type(identity.repo) ~= "string" or not identity.repo:match(NAME_PATTERN) then
		return nil, "invalid-release"
	end
	for _, asset in ipairs(release.assets) do
		if type(asset) ~= "table" or type(asset.name) ~= "string" then return nil, "invalid-release-assets" end
	end
	for _, candidate in ipairs(identity.archives) do
		if type(candidate) ~= "table" or not M.supports(candidate.format)
			or type(candidate.name) ~= "string" or not candidate.name:match(NAME_PATTERN)
			or candidate.name:sub(-#FORMATS[candidate.format]) ~= FORMATS[candidate.format] then
			return nil, "invalid-archive-binding"
		end
		local found
		for _, asset in ipairs(release.assets) do
			if asset.name == candidate.name then
				if found then return nil, "ambiguous-archive" end
				found = asset
			end
		end
		if found then
			local expected = string.format("https://github.com/%s/%s/releases/download/%s/%s",
				identity.owner, identity.repo, tag, candidate.name)
			local digest = type(found.digest) == "string" and found.digest:match("^sha256:(%x+)$") or nil
			if found.browser_download_url ~= expected or not digest or #digest ~= 64 then
				return nil, "invalid-archive-integrity"
			end
			return { tag = tag, version = tag:gsub("^v", ""), url = expected,
				digest = digest:lower(), format = candidate.format }
		end
	end
	return nil, "absent-archive"
end

return M
